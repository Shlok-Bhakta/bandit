//! Over-the-air updates (CONTROL.md): a signed package streamed over Bluetooth into the spare app
//! slot. The header's ECDSA P-256 signature is checked before anything is written; the image's
//! SHA-256 and ESP-IDF's own image check run before the boot slot changes. A fresh image runs on
//! probation: it confirms itself after `PROBATION` of healthy running, and if it crashes or
//! reboots before then, the bootloader goes back to the previous slot.

use std::sync::mpsc::{sync_channel, Receiver, RecvTimeoutError, SyncSender};
use std::sync::Arc;
use std::time::{Duration, Instant};

use esp32_nimble::utilities::mutex::Mutex;
use esp32_nimble::BLECharacteristic;
use esp_idf_svc::sys;
use log::{error, info, warn};
use sha2::{Digest, Sha256};

/// The public half of the key `dongle-pack keygen` made (its private half never leaves the build Mac).
const UPDATE_KEY: [u8; 65] = [
    0x04, 0x57, 0xf7, 0x17, 0x86, 0x73, 0xa2, 0x45, 0x4d, 0xa4, 0xbd, 0x0e, 0xe4, 0x4e, 0xe8, 0xa7,
    0xfd, 0x45, 0x5e, 0x7d, 0xe9, 0xc4, 0x17, 0xe9, 0x80, 0xf3, 0x88, 0xac, 0x7e, 0xaf, 0x97, 0xd5,
    0x76, 0xbd, 0x75, 0x78, 0xfc, 0x4c, 0xf8, 0x9b, 0x4e, 0x1c, 0xbc, 0x73, 0xd3, 0x82, 0x97, 0x30,
    0x2a, 0xdd, 0xcd, 0x63, 0x33, 0xc4, 0x55, 0x63, 0x8b, 0xac, 0x4c, 0xbd, 0xd7, 0x22, 0x7a, 0x85,
    0x65,
];
const MAGIC: &[u8; 8] = b"NPDFW\x01\x00\x00";
const HEADER_LEN: usize = 256;
const ACK_EVERY: u32 = 4096;
const PROBATION: Duration = Duration::from_secs(60);
const IDLE_ABORT: Duration = Duration::from_secs(30);

const READY: u8 = 0x80;
const ACK: u8 = 0x81;
const RESEND: u8 = 0x82;
const DONE: u8 = 0x83;
const FAIL: u8 = 0x84;

enum Message {
    Begin { total: u32, handle: u16 },
    Data { offset: u32, bytes: Vec<u8> },
    Abort,
}

#[derive(Clone, Default)]
pub struct Progress {
    pub state: &'static str,
    pub got: u32,
    pub of: u32,
    pub error: String,
}

static PROGRESS: std::sync::Mutex<Progress> = std::sync::Mutex::new(Progress { state: "idle", got: 0, of: 0, error: String::new() });

pub fn progress() -> Progress { PROGRESS.lock().unwrap().clone() }

fn set_progress(state: &'static str, got: u32, of: u32, error: &str) {
    *PROGRESS.lock().unwrap() = Progress { state, got, of, error: error.to_string() };
}

#[derive(Clone)]
pub struct Updater {
    sender: SyncSender<Message>,
    queued: Arc<std::sync::atomic::AtomicUsize>,
}

/// At most this much update data waits in memory for the flash writer.
const QUEUE_BYTES: usize = 24 * 1024;

/// The connection handle the serial console's updates use: replies are logged, not notified.
pub const SERIAL: u16 = u16::MAX;

impl Updater {
    /// `characteristic` is the Update characteristic, for replies.
    pub fn start(characteristic: Arc<Mutex<BLECharacteristic>>) -> Self {
        // Room for the app's 8 KB flow-control window of ~240-byte chunks; `QUEUE_BYTES` caps the
        // memory whatever the chunk size.
        let (sender, receiver) = sync_channel(96);
        let queued = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        std::thread::Builder::new()
            .name("ota".into())
            .stack_size(8192)
            .spawn({ let queued = queued.clone(); move || worker(receiver, characteristic, queued) })
            .expect("ota thread");
        Self { sender, queued }
    }

    /// A write to the Update characteristic (runs on the Bluetooth host task: never blocks).
    pub fn write(&self, data: &[u8], handle: u16) { self.submit(data, handle, false) }

    /// The same, from the serial console (`OTA` lines), which can wait for room.
    pub fn write_blocking(&self, data: &[u8]) { self.submit(data, SERIAL, true) }

    fn submit(&self, data: &[u8], handle: u16, wait: bool) {
        let message = match data {
            [0x01, a, b, c, d] => Message::Begin { total: u32::from_le_bytes([*a, *b, *c, *d]), handle },
            [0x02, a, b, c, d, rest @ ..] if !rest.is_empty() => Message::Data { offset: u32::from_le_bytes([*a, *b, *c, *d]), bytes: rest.to_vec() },
            [0x03] => Message::Abort,
            _ => { warn!("UPDATE: unknown write ({} bytes)", data.len()); return; }
        };
        // A full queue drops the chunk; the offset gap that follows asks the app to resend.
        let size = if let Message::Data { bytes, .. } = &message { bytes.len() } else { 0 };
        use std::sync::atomic::Ordering::SeqCst;
        if wait {
            while self.queued.load(SeqCst) + size > QUEUE_BYTES { std::thread::sleep(Duration::from_millis(5)); }
        } else if self.queued.load(SeqCst) + size > QUEUE_BYTES {
            return;
        }
        self.queued.fetch_add(size, SeqCst);
        let sent = if wait { self.sender.send(message).is_ok() } else { self.sender.try_send(message).is_ok() };
        if !sent { self.queued.fetch_sub(size, SeqCst); }
    }
}

struct Transfer {
    handle: u16,
    total: u32,
    next: u32,
    header: Vec<u8>,
    expected_sha: [u8; 32],
    hasher: Sha256,
    ota: Option<(sys::esp_ota_handle_t, *const sys::esp_partition_t)>,
    last_ack: u32,
    last_resend: Option<(u32, Instant)>,
    last_data: Instant,
    started: Instant,
}

impl Transfer {
    fn abort(&mut self) {
        if let Some((ota, _)) = self.ota.take() { unsafe { sys::esp_ota_abort(ota) }; }
    }
}

fn worker(receiver: Receiver<Message>, characteristic: Arc<Mutex<BLECharacteristic>>, queued: Arc<std::sync::atomic::AtomicUsize>) {
    let reply = |handle: u16, bytes: &[u8]| {
        if handle == SERIAL {
            match bytes {
                [ACK | RESEND, a, b, c, d] => info!("UPDATE reply {:02x} {}", bytes[0], u32::from_le_bytes([*a, *b, *c, *d])),
                _ => info!("UPDATE reply {:02x} {}", bytes[0], String::from_utf8_lossy(&bytes[1..])),
            }
            return;
        }
        if let Err(error) = characteristic.lock().notify_with(bytes, handle) { warn!("UPDATE: reply not delivered: {error:?}"); }
    };
    let fail = |transfer: &mut Option<Transfer>, reason: String| {
        if let Some(mut current) = transfer.take() {
            current.abort();
            error!("UPDATE FAILED: {reason}");
            set_progress("error", current.next, current.total, &reason);
            reply(current.handle, &[&[FAIL], reason.as_bytes()].concat());
        }
    };
    let mut transfer: Option<Transfer> = None;
    loop {
        let message = match receiver.recv_timeout(Duration::from_secs(1)) {
            Ok(message) => message,
            Err(RecvTimeoutError::Timeout) => {
                if transfer.as_ref().is_some_and(|t| t.last_data.elapsed() > IDLE_ABORT) {
                    fail(&mut transfer, "no data for 30 s; update abandoned".into());
                }
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => return,
        };
        match message {
            Message::Abort => {
                if let Some(mut current) = transfer.take() {
                    current.abort();
                    info!("UPDATE: aborted by the app");
                    set_progress("idle", 0, 0, "");
                }
            }
            Message::Begin { total, handle } => {
                if let Some(mut current) = transfer.take() { current.abort(); }
                let max = unsafe { sys::esp_ota_get_next_update_partition(std::ptr::null()).as_ref() }.map(|p| p.size).unwrap_or(0);
                if total as usize <= HEADER_LEN + 0x10000 || total - HEADER_LEN as u32 > max {
                    let reason = format!("package size {total} doesn't fit the update slot ({max} bytes)");
                    reply(handle, &[&[FAIL], reason.as_bytes()].concat());
                    set_progress("error", 0, total, &reason);
                    continue;
                }
                info!("UPDATE: receiving a {total}-byte package");
                set_progress("receiving", 0, total, "");
                let now = Instant::now();
                transfer = Some(Transfer {
                    handle, total, next: 0, header: Vec::with_capacity(HEADER_LEN), expected_sha: [0; 32], hasher: Sha256::new(),
                    ota: None, last_ack: 0, last_resend: None, last_data: now, started: now,
                });
                reply(handle, &[READY]);
            }
            Message::Data { offset, bytes } => {
                queued.fetch_sub(bytes.len(), std::sync::atomic::Ordering::SeqCst);
                let Some(current) = transfer.as_mut() else { continue };
                current.last_data = Instant::now();
                if offset > current.next {
                    // A dropped chunk. Ask once per gap (the chunks already in flight also miss).
                    let fresh = current.last_resend.is_none_or(|(at, when)| at != current.next || when.elapsed() > Duration::from_millis(500));
                    if fresh {
                        current.last_resend = Some((current.next, Instant::now()));
                        reply(current.handle, &[&[RESEND], &current.next.to_le_bytes()[..]].concat());
                    }
                    continue;
                }
                let skip = (current.next - offset) as usize;
                if skip >= bytes.len() { continue; }
                let mut data = &bytes[skip..];
                if current.next as u64 + data.len() as u64 > current.total as u64 {
                    fail(&mut transfer, "data past the announced size".into());
                    continue;
                }
                if (current.next as usize) < HEADER_LEN {
                    let take = (HEADER_LEN - current.next as usize).min(data.len());
                    current.header.extend_from_slice(&data[..take]);
                    current.next += take as u32;
                    data = &data[take..];
                    if current.header.len() == HEADER_LEN {
                        match check_header(&current.header, current.total) {
                            Ok(sha) => current.expected_sha = sha,
                            Err(reason) => { fail(&mut transfer, reason); continue; }
                        }
                        match begin_flash() {
                            Ok(ota) => current.ota = Some(ota),
                            Err(reason) => { fail(&mut transfer, reason); continue; }
                        }
                        let label = String::from_utf8_lossy(&current.header[16..64]).trim_end_matches('\0').to_string();
                        info!("UPDATE: signature OK ({label}); writing the spare slot");
                    }
                }
                if !data.is_empty() {
                    let Some((ota, _)) = current.ota else { continue };
                    current.hasher.update(data);
                    let rc = unsafe { sys::esp_ota_write(ota, data.as_ptr() as *const _, data.len()) };
                    if rc != 0 {
                        fail(&mut transfer, format!("flash write failed ({rc})"));
                        continue;
                    }
                    current.next += data.len() as u32;
                }
                let current = transfer.as_mut().unwrap();
                set_progress("receiving", current.next, current.total, "");
                if current.next == current.total || current.next - current.last_ack >= ACK_EVERY {
                    current.last_ack = current.next;
                    reply(current.handle, &[&[ACK], &current.next.to_le_bytes()[..]].concat());
                }
                if current.next == current.total {
                    set_progress("verifying", current.next, current.total, "");
                    let mut finished = transfer.take().unwrap();
                    match finish(&mut finished) {
                        Ok(()) => {
                            info!("UPDATE: verified in {} s; booting the new firmware", finished.started.elapsed().as_secs());
                            set_progress("done", finished.total, finished.total, "");
                            reply(finished.handle, &[DONE]);
                            std::thread::sleep(Duration::from_millis(1500));
                            unsafe { sys::esp_restart() };
                        }
                        Err(reason) => {
                            transfer = Some(finished);
                            fail(&mut transfer, reason);
                        }
                    }
                }
            }
        }
    }
}

fn check_header(header: &[u8], total: u32) -> Result<[u8; 32], String> {
    if &header[..8] != MAGIC { return Err("not a dongle firmware package".into()); }
    let length = u32::from_le_bytes(header[8..12].try_into().unwrap());
    if length as usize + HEADER_LEN != total as usize { return Err(format!("the header says {length} bytes; {total} were announced")); }
    use p256::ecdsa::signature::Verifier;
    let key = p256::ecdsa::VerifyingKey::from_sec1_bytes(&UPDATE_KEY).map_err(|_| "bad built-in update key".to_string())?;
    let signature = p256::ecdsa::Signature::from_slice(&header[96..160]).map_err(|_| "malformed signature".to_string())?;
    key.verify(&header[..96], &signature).map_err(|_| "the signature doesn't match this dongle's update key".to_string())?;
    Ok(header[64..96].try_into().unwrap())
}

fn begin_flash() -> Result<(sys::esp_ota_handle_t, *const sys::esp_partition_t), String> {
    let partition = unsafe { sys::esp_ota_get_next_update_partition(std::ptr::null()) };
    if partition.is_null() { return Err("no spare app slot (flash the two-slot layout over USB once)".into()); }
    let mut handle: sys::esp_ota_handle_t = 0;
    // Sequential writes erase as they go, so no multi-second erase stalls the Bluetooth link.
    let rc = unsafe { sys::esp_ota_begin(partition, sys::OTA_WITH_SEQUENTIAL_WRITES as usize, &mut handle) };
    if rc != 0 { return Err(format!("couldn't start writing the spare slot ({rc})")); }
    Ok((handle, partition))
}

fn finish(transfer: &mut Transfer) -> Result<(), String> {
    let digest: [u8; 32] = std::mem::take(&mut transfer.hasher).finalize().into();
    if digest != transfer.expected_sha { return Err("the image's SHA-256 doesn't match its signed header".into()); }
    let Some((ota, partition)) = transfer.ota.take() else { return Err("nothing was written".into()) };
    let rc = unsafe { sys::esp_ota_end(ota) };
    if rc != 0 { return Err(format!("ESP-IDF rejected the image ({rc})")); }
    let rc = unsafe { sys::esp_ota_set_boot_partition(partition) };
    if rc != 0 { return Err(format!("couldn't switch the boot slot ({rc})")); }
    Ok(())
}

/// The running slot's label, and whether this image is still on probation.
pub fn running() -> (String, bool) {
    unsafe {
        let partition = sys::esp_ota_get_running_partition();
        let Some(info) = partition.as_ref() else { return ("?".into(), false) };
        let label = std::ffi::CStr::from_ptr(info.label.as_ptr()).to_string_lossy().into_owned();
        let mut state: sys::esp_ota_img_states_t = 0;
        let pending = sys::esp_ota_get_state_partition(partition, &mut state) == 0
            && state == sys::esp_ota_img_states_t_ESP_OTA_IMG_PENDING_VERIFY;
        (label, pending && !CONFIRMED.load(std::sync::atomic::Ordering::SeqCst))
    }
}

static CONFIRMED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// A freshly updated image confirms itself after `PROBATION`; a crash before then rolls back.
pub fn confirm_after_probation() {
    let (slot, pending) = running();
    if !pending {
        info!("UPDATE: running {slot}");
        return;
    }
    warn!("UPDATE: running a new image from {slot} on probation; it confirms itself in {} s", PROBATION.as_secs());
    std::thread::Builder::new()
        .stack_size(4096)
        .spawn(|| {
            std::thread::sleep(PROBATION);
            let rc = unsafe { sys::esp_ota_mark_app_valid_cancel_rollback() };
            CONFIRMED.store(true, std::sync::atomic::Ordering::SeqCst);
            info!("UPDATE: new firmware confirmed (rc {rc}); no rollback");
        })
        .expect("probation thread");
}

/// The first 8 hex digits of the running image's ELF SHA-256 (dongle-pack's `id`).
pub fn build_id() -> String {
    let mut buffer = [0u8; 9];
    unsafe { sys::esp_app_get_elf_sha256(buffer.as_mut_ptr() as *mut _, buffer.len()) };
    String::from_utf8_lossy(&buffer[..8]).into_owned()
}
