//! A minimal, correct L2CAP connection-oriented channel client over raw NimBLE.
//!
//! Replaces esp32-nimble's `L2capClient`, which (v0.13.0) frees its buffer pool while NimBLE can
//! still hold buffers from it (heap corruption on reconnect: `tlsf.c block_trim_free` assert),
//! returns only the first mbuf of a chained SDU (lost bytes → "Unsupported band transport marker"),
//! and drops SDUs when its 1-slot queue is full.
//!
//! Here the pool is allocated once and never freed, received SDUs are copied out in full (the whole
//! mbuf chain) into a queue, and the chain is freed immediately. The queue is bounded: a band
//! sending faster than the dongle reads ends the channel (and the session, which reconnects)
//! instead of the heap. NimBLE can't hold the band back: an SDU it has credits for and no buffer
//! armed for drops the link anyway.

use std::collections::VecDeque;
use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use esp_idf_svc::sys;

pub const MTU: u16 = 1024;
/// One SDU fits a block. In use at once: the receive buffer armed, the one being copied out, and
/// what's being sent (one at a time): 2 at most, with motion (0.15.1); the log's `np_coc` min
/// free shows the slack.
const BLOCKS: u16 = 4;
/// Received bytes waiting for the session: a few hundred normally; motion streams ~9 KB/s and
/// starts with a burst, so this is seconds of the loop being held up.
const RX_LIMIT: usize = 32 * 1024;
/// Payload plus room for the mbuf and packet headers.
const BLOCK_SIZE: usize = MTU as usize + 64;

struct Pool {
    mempool: sys::os_mempool,
    mbuf_pool: sys::os_mbuf_pool,
}

struct PoolPtr(*mut Pool);
unsafe impl Send for PoolPtr {}
unsafe impl Sync for PoolPtr {}

static POOL: OnceLock<PoolPtr> = OnceLock::new();

#[derive(Default)]
struct State {
    chan: usize,
    connect_status: Option<i32>,
    stalled: bool,
    rx: VecDeque<Vec<u8>>,
    /// Bytes in `rx`, and the most there were since `take_peak`.
    rx_queued: usize,
    rx_peak: usize,
    /// `rx` outgrew `RX_LIMIT` and the channel was closed.
    overflowed: bool,
    rx_bytes: usize,
    rx_sdus: usize,
}

static STATE: Mutex<State> = Mutex::new(State {
    chan: 0,
    connect_status: None,
    stalled: false,
    rx: VecDeque::new(),
    rx_queued: 0,
    rx_peak: 0,
    overflowed: false,
    rx_bytes: 0,
    rx_sdus: 0,
});

fn pool() -> *mut Pool {
    POOL.get_or_init(|| {
        let words = BLOCK_SIZE.div_ceil(std::mem::size_of::<sys::os_membuf_t>()) * BLOCKS as usize;
        let bytes = words * std::mem::size_of::<sys::os_membuf_t>();
        // In RTC RAM (7 KB the allocator otherwise only falls back to), out of the main region's
        // way: it's allocated at the first connect, in the middle of everything else.
        // SAFETY: a heap_caps allocation never freed; os_mempool_init only needs `bytes` of
        // word-aligned memory, which heap_caps_malloc gives.
        let mut memory = unsafe { sys::heap_caps_malloc(bytes, sys::MALLOC_CAP_RTCRAM | sys::MALLOC_CAP_8BIT) };
        if memory.is_null() { memory = vec![0 as sys::os_membuf_t; words].leak().as_mut_ptr() as *mut c_void; }
        let pool = Box::leak(Box::new(Pool { mempool: Default::default(), mbuf_pool: Default::default() }));
        unsafe {
            let rc = sys::os_mempool_init(&mut pool.mempool, BLOCKS, BLOCK_SIZE as u32, memory, c"np_coc".as_ptr());
            assert_eq!(rc, 0, "os_mempool_init");
            let rc = sys::os_mbuf_pool_init(&mut pool.mbuf_pool, &mut pool.mempool, BLOCK_SIZE as u16, BLOCKS);
            assert_eq!(rc, 0, "os_mbuf_pool_init");
        }
        PoolPtr(pool)
    }).0
}

/// A fresh packet-header mbuf from our pool, waiting briefly if the pool is momentarily empty.
fn get_mbuf() -> *mut sys::os_mbuf {
    let started = Instant::now();
    loop {
        let om = unsafe { sys::os_mbuf_get_pkthdr(&mut (*pool()).mbuf_pool, 0) };
        if !om.is_null() || started.elapsed() > Duration::from_millis(500) {
            return om;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn chain_len(mut om: *mut sys::os_mbuf) -> usize {
    let mut length = 0;
    while !om.is_null() {
        unsafe {
            length += (*om).om_len as usize;
            om = (*om).om_next.sle_next;
        }
    }
    length
}

extern "C" fn on_event(event: *mut sys::ble_l2cap_event, _arg: *mut c_void) -> i32 {
    let event = unsafe { &*event };
    let mut state = STATE.lock().unwrap();
    match event.type_ as u32 {
        sys::BLE_L2CAP_EVENT_COC_CONNECTED => {
            let connect = unsafe { event.__bindgen_anon_1.connect };
            if connect.status == 0 {
                state.chan = connect.chan as usize;
            }
            state.connect_status = Some(connect.status);
        }
        sys::BLE_L2CAP_EVENT_COC_DISCONNECTED => state.chan = 0,
        sys::BLE_L2CAP_EVENT_COC_DATA_RECEIVED => {
            let receive = unsafe { event.__bindgen_anon_1.receive };
            if !receive.sdu_rx.is_null() {
                let length = chain_len(receive.sdu_rx);
                if state.overflowed || state.rx_queued + length > RX_LIMIT {
                    unsafe { sys::os_mbuf_free_chain(receive.sdu_rx) };
                    // The session sees it and ends, dropping the link (no L2CAP disconnect: `Channel`).
                    state.overflowed = true;
                    return 0;
                }
                let mut data = vec![0u8; length];
                unsafe {
                    sys::os_mbuf_copydata(receive.sdu_rx, 0, length as i32, data.as_mut_ptr() as *mut c_void);
                    sys::os_mbuf_free_chain(receive.sdu_rx);
                }
                state.rx_bytes += length;
                state.rx_sdus += 1;
                state.rx_queued += length;
                state.rx_peak = state.rx_peak.max(state.rx_queued);
                state.rx.push_back(data);
            }
            drop(state);
            let next = get_mbuf();
            if !next.is_null() {
                unsafe { sys::ble_l2cap_recv_ready(receive.chan, next) };
            }
            return 0;
        }
        sys::BLE_L2CAP_EVENT_COC_TX_UNSTALLED => state.stalled = false,
        _ => {}
    }
    0
}

/// The channel ends with the link: the caller drops the link, and NimBLE frees the channel with
/// it. Never `ble_l2cap_disconnect`: the band closes its end as the session ends, and if its
/// request crosses ours, NimBLE (ESP-IDF 5.3) frees the channel for the band's and then, when the
/// link drops, deletes it again for ours, reading through a null list (LoadProhibited in
/// `ble_hs_conn_delete_chan`): a crash, a reboot, the same again on the next session (0.16.0).
pub struct Channel;

impl Channel {
    /// Opens the channel on `conn_handle` and waits up to `timeout` for the peer to accept.
    pub fn connect(conn_handle: u16, psm: u16, timeout: Duration) -> anyhow::Result<Channel> {
        {
            let mut state = STATE.lock().unwrap();
            *state = State::default();
        }
        let sdu_rx = get_mbuf();
        anyhow::ensure!(!sdu_rx.is_null(), "no receive buffer available");
        let rc = unsafe { sys::ble_l2cap_connect(conn_handle, psm, MTU, sdu_rx, Some(on_event), std::ptr::null_mut()) };
        anyhow::ensure!(rc == 0, "ble_l2cap_connect failed: {rc}");
        let started = Instant::now();
        loop {
            if let Some(status) = STATE.lock().unwrap().connect_status {
                anyhow::ensure!(status == 0, "the band refused the L2CAP channel: {status}");
                return Ok(Channel);
            }
            anyhow::ensure!(started.elapsed() < timeout, "L2CAP connect timed out");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn chan(&self) -> *mut sys::ble_l2cap_chan { STATE.lock().unwrap().chan as *mut sys::ble_l2cap_chan }

    pub fn is_open(&self) -> bool { STATE.lock().unwrap().chan != 0 }

    /// Everything received since the last call, in order.
    pub fn take(&self) -> VecDeque<Vec<u8>> {
        let mut state = STATE.lock().unwrap();
        state.rx_queued = 0;
        std::mem::take(&mut state.rx)
    }

    /// The most bytes that waited to be read since the last call.
    pub fn take_peak(&self) -> usize { std::mem::take(&mut STATE.lock().unwrap().rx_peak) }

    /// The band sent more than `RX_LIMIT` before the session read it, so the channel was closed.
    pub fn overflowed(&self) -> bool { STATE.lock().unwrap().overflowed }

    pub fn stats(&self) -> (usize, usize) {
        let state = STATE.lock().unwrap();
        (state.rx_sdus, state.rx_bytes)
    }

    pub fn send(&self, data: &[u8]) -> anyhow::Result<()> {
        let chan = self.chan();
        anyhow::ensure!(!chan.is_null(), "L2CAP channel is closed");
        let mut info = sys::ble_l2cap_chan_info::default();
        unsafe { sys::ble_l2cap_get_chan_info(chan, &mut info) };
        let limit = (info.peer_l2cap_mtu as usize).clamp(23, 512);
        for chunk in data.chunks(limit) {
            // Wait out a stall from the previous SDU.
            let started = Instant::now();
            while STATE.lock().unwrap().stalled {
                anyhow::ensure!(started.elapsed() < Duration::from_secs(2), "L2CAP transmit stalled");
                std::thread::sleep(Duration::from_millis(2));
            }
            let om = get_mbuf();
            anyhow::ensure!(!om.is_null(), "no transmit buffer available");
            let rc = unsafe { sys::os_mbuf_append(om, chunk.as_ptr() as *const c_void, chunk.len() as u16) };
            if rc != 0 {
                unsafe { sys::os_mbuf_free_chain(om) };
                anyhow::bail!("os_mbuf_append failed: {rc}");
            }
            let started = Instant::now();
            loop {
                let rc = unsafe { sys::ble_l2cap_send(chan, om) } as u32;
                match rc {
                    0 => break,
                    sys::BLE_HS_ESTALLED => {
                        STATE.lock().unwrap().stalled = true;
                        break;
                    }
                    sys::BLE_HS_EBUSY if started.elapsed() < Duration::from_secs(2) => std::thread::sleep(Duration::from_millis(2)),
                    rc => {
                        unsafe { sys::os_mbuf_free_chain(om) };
                        anyhow::bail!("ble_l2cap_send failed: {rc}");
                    }
                }
            }
        }
        Ok(())
    }
}
