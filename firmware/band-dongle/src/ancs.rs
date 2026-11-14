//! Calls on an iPhone, through Apple's Notification Center Service (ANCS): a bonded accessory
//! may subscribe to the phone's notifications. The dongle only reads calls: one ringing buzzes
//! the band (`Controller::poll`), and `call:answer` / `call:end` press the notification's
//! buttons (answer / decline, or end the call in progress).
//!
//! It runs on the phone's own connection (the dongle is the GATT client there): discover the
//! service, find Notification Source's CCCD, subscribe. iOS asks once whether to share
//! notifications with "NP Band Remote" (or under the device's Bluetooth settings). The NimBLE
//! callbacks run on its host task; `STATE` is shared with the controller.

use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::Mutex;
use std::time::Instant;

use esp_idf_svc::sys as ble;
use log::{info, warn};

/// 7905F431-B5CE-4E99-A40F-4B1E122D00D0, little-endian.
const SERVICE: [u8; 16] = [0xD0, 0x00, 0x2D, 0x12, 0x1E, 0x4B, 0x0F, 0xA4, 0x99, 0x4E, 0xCE, 0xB5, 0x31, 0xF4, 0x05, 0x79];
/// Notification Source 9FBF120D-6301-42D9-8C58-25E699A21DBD.
const NOTIFICATION_SOURCE: [u8; 16] = [0xBD, 0x1D, 0xA2, 0x99, 0xE6, 0x25, 0x58, 0x8C, 0xD9, 0x42, 0x01, 0x63, 0x0D, 0x12, 0xBF, 0x9F];
/// Control Point 69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9.
const CONTROL_POINT: [u8; 16] = [0xD9, 0xD9, 0xAA, 0xFD, 0xBD, 0x9B, 0x21, 0x98, 0xA8, 0x49, 0xE1, 0x45, 0xF3, 0xD8, 0xD1, 0x69];

const CATEGORY_INCOMING_CALL: u8 = 1;
const CATEGORY_ACTIVE_CALL: u8 = 12;
const EVENT_REMOVED: u8 = 2;
const COMMAND_PERFORM_ACTION: u8 = 2;
const ACTION_POSITIVE: u8 = 0;
const ACTION_NEGATIVE: u8 = 1;

/// A ringing call stops buzzing after this long even if the phone never says it's over.
pub const RING_LIMIT_SECS: u64 = 60;

#[derive(Default)]
struct Phone {
    conn: u16,
    service: (u16, u16),
    /// Characteristics found: (definition handle, value handle, which).
    chars: Vec<(u16, u16, Which)>,
    source: u16,
    control: u16,
    /// The ringing call's notification id, since when.
    ringing: Option<(u32, Instant)>,
    /// The call in progress (iOS 17+ posts it as a notification too).
    active: Option<u32>,
}

#[derive(Clone, Copy, PartialEq)]
enum Which { Source, Control, Other }

static STATE: Mutex<Option<Phone>> = Mutex::new(None);
/// The phone connection and its Notification Source handle, for the GAP listener (which sees
/// every notification, the band's ~70 a second included) to filter without a lock.
static WATCHED: (AtomicU16, AtomicU16) = (AtomicU16::new(u16::MAX), AtomicU16::new(0));
static mut LISTENER: ble::ble_gap_event_listener = unsafe { core::mem::zeroed() };
static LISTENING: std::sync::Once = std::sync::Once::new();

fn done(error: *const ble::ble_gatt_error) -> Option<u16> {
    let status = unsafe { (*error).status };
    (status != 0).then_some(status)
}

/// Starts watching calls on an encrypted phone connection (an Android phone has no ANCS: it
/// logs that once, and nothing changes).
pub fn watch(conn: u16) {
    LISTENING.call_once(|| unsafe {
        let rc = ble::ble_gap_event_listener_register(core::ptr::addr_of_mut!(LISTENER), Some(on_gap_event), core::ptr::null_mut());
        if rc != 0 { warn!("CALLS: couldn't listen for notifications (rc {rc})"); }
    });
    *STATE.lock().unwrap() = Some(Phone { conn, ..Default::default() });
    WATCHED.0.store(conn, Ordering::SeqCst);
    WATCHED.1.store(0, Ordering::SeqCst);
    let uuid = ble::ble_uuid128_t { u: ble::ble_uuid_t { type_: ble::BLE_UUID_TYPE_128 as u8 }, value: SERVICE };
    let rc = unsafe { ble::ble_gattc_disc_svc_by_uuid(conn, &uuid.u, Some(on_service), core::ptr::null_mut()) };
    if rc != 0 { warn!("CALLS: couldn't look for the phone's notifications (rc {rc})"); }
}

/// The phone went away.
pub fn forget(conn: u16) {
    let mut state = STATE.lock().unwrap();
    if state.as_ref().is_some_and(|phone| phone.conn == conn) {
        *state = None;
        WATCHED.0.store(u16::MAX, Ordering::SeqCst);
    }
}

/// A call is ringing (and hasn't rung longer than `RING_LIMIT_SECS`).
pub fn ringing() -> bool {
    STATE.lock().unwrap().as_ref()
        .and_then(|phone| phone.ringing)
        .is_some_and(|(_, since)| since.elapsed().as_secs() < RING_LIMIT_SECS)
}

/// Answers the ringing call. False if none rings (or the phone doesn't share notifications).
pub fn answer() -> bool {
    let target = STATE.lock().unwrap().as_ref().and_then(|phone| Some((phone.conn, phone.control, phone.ringing?.0)));
    match target {
        Some((conn, control, uid)) if control != 0 => perform(conn, control, uid, ACTION_POSITIVE, "answering"),
        _ => { info!("CALLS: no call ringing to answer"); false }
    }
}

/// Declines the ringing call, else ends the one in progress.
pub fn end() -> bool {
    let target = STATE.lock().unwrap().as_ref().and_then(|phone| {
        let (uid, what) = match (phone.ringing, phone.active) {
            (Some((uid, _)), _) => (uid, "declining"),
            (None, Some(uid)) => (uid, "ending the call"),
            (None, None) => return None,
        };
        Some((phone.conn, phone.control, uid, what))
    });
    match target {
        Some((conn, control, uid, what)) if control != 0 => perform(conn, control, uid, ACTION_NEGATIVE, what),
        _ => { info!("CALLS: no call to end"); false }
    }
}

fn perform(conn: u16, control: u16, uid: u32, action: u8, what: &str) -> bool {
    let mut command = [COMMAND_PERFORM_ACTION, 0, 0, 0, 0, action];
    command[1..5].copy_from_slice(&uid.to_le_bytes());
    let rc = unsafe { ble::ble_gattc_write_flat(conn, control, command.as_ptr().cast(), command.len() as u16, Some(on_action_written), core::ptr::null_mut()) };
    if rc != 0 { warn!("CALLS: {what} failed (rc {rc})"); return false; }
    info!("CALLS: {what}");
    true
}

unsafe extern "C" fn on_service(conn: u16, error: *const ble::ble_gatt_error, service: *const ble::ble_gatt_svc, _: *mut core::ffi::c_void) -> i32 {
    match done(error) {
        None => {
            let (start, end) = ((*service).start_handle, (*service).end_handle);
            if let Some(phone) = STATE.lock().unwrap().as_mut().filter(|phone| phone.conn == conn) { phone.service = (start, end); }
        }
        Some(status) if status == ble::BLE_HS_EDONE as u16 => {
            let found = STATE.lock().unwrap().as_ref().filter(|phone| phone.conn == conn).map(|phone| phone.service).filter(|s| s.0 != 0);
            match found {
                Some((start, end)) => {
                    let rc = ble::ble_gattc_disc_all_chrs(conn, start, end, Some(on_characteristic), core::ptr::null_mut());
                    if rc != 0 { warn!("CALLS: couldn't read the notification service (rc {rc})"); }
                }
                None => info!("CALLS: this phone doesn't share notifications (not an iPhone): no call buzz or call actions"),
            }
        }
        Some(status) => warn!("CALLS: looking for the phone's notifications failed (status {status})"),
    }
    0
}

unsafe extern "C" fn on_characteristic(conn: u16, error: *const ble::ble_gatt_error, chr: *const ble::ble_gatt_chr, _: *mut core::ffi::c_void) -> i32 {
    let mut state = STATE.lock().unwrap();
    let Some(phone) = state.as_mut().filter(|phone| phone.conn == conn) else { return 0 };
    match done(error) {
        None => {
            let chr = &*chr;
            let which = if chr.uuid.u.type_ == ble::BLE_UUID_TYPE_128 as u8 {
                match chr.uuid.u128_.value {
                    NOTIFICATION_SOURCE => Which::Source,
                    CONTROL_POINT => Which::Control,
                    _ => Which::Other,
                }
            } else { Which::Other };
            phone.chars.push((chr.def_handle, chr.val_handle, which));
        }
        Some(status) if status == ble::BLE_HS_EDONE as u16 => {
            let source = phone.chars.iter().position(|c| c.2 == Which::Source);
            phone.control = phone.chars.iter().find(|c| c.2 == Which::Control).map_or(0, |c| c.1);
            let Some(index) = source else { warn!("CALLS: the phone's notification service has no source"); return 0 };
            phone.source = phone.chars[index].1;
            // Its descriptors run up to the next characteristic (or the service's end).
            let end = phone.chars.iter().map(|c| c.0).filter(|&d| d > phone.source).min().map_or(phone.service.1, |d| d - 1);
            let source = phone.source;
            drop(state);
            let rc = ble::ble_gattc_disc_all_dscs(conn, source, end, Some(on_descriptor), core::ptr::null_mut());
            if rc != 0 { warn!("CALLS: couldn't find where to subscribe (rc {rc})"); }
        }
        Some(status) => warn!("CALLS: reading the notification service failed (status {status})"),
    }
    0
}

unsafe extern "C" fn on_descriptor(conn: u16, error: *const ble::ble_gatt_error, _: u16, dsc: *const ble::ble_gatt_dsc, _: *mut core::ffi::c_void) -> i32 {
    // The CCCD once found (the walk goes on to the range's end).
    static CCCD: AtomicU16 = AtomicU16::new(0);
    match done(error) {
        None => {
            let dsc = &*dsc;
            if dsc.uuid.u.type_ == ble::BLE_UUID_TYPE_16 as u8 && dsc.uuid.u16_.value == ble::BLE_GATT_DSC_CLT_CFG_UUID16 as u16 {
                CCCD.store(dsc.handle, Ordering::SeqCst);
            }
        }
        Some(status) if status == ble::BLE_HS_EDONE as u16 => {
            let cccd = CCCD.swap(0, Ordering::SeqCst);
            if cccd == 0 { warn!("CALLS: nowhere to subscribe to the phone's notifications"); return 0; }
            let enable = [1u8, 0];
            let rc = ble::ble_gattc_write_flat(conn, cccd, enable.as_ptr().cast(), 2, Some(on_subscribed), core::ptr::null_mut());
            if rc != 0 { warn!("CALLS: couldn't subscribe (rc {rc})"); }
        }
        Some(status) => warn!("CALLS: finding where to subscribe failed (status {status})"),
    }
    0
}

unsafe extern "C" fn on_subscribed(conn: u16, error: *const ble::ble_gatt_error, _: *mut ble::ble_gatt_attr, _: *mut core::ffi::c_void) -> i32 {
    match done(error) {
        None => {
            let source = STATE.lock().unwrap().as_ref().filter(|phone| phone.conn == conn).map_or(0, |phone| phone.source);
            WATCHED.1.store(source, Ordering::SeqCst);
            info!("CALLS: watching the iPhone's calls");
        }
        // 0x105 (insufficient authentication) or "not allowed": the phone said no, or asks first.
        Some(status) => warn!("CALLS: the phone didn't share its notifications (status {status:#x}): allow it under Settings › Bluetooth › NP Band Remote › Share System Notifications"),
    }
    0
}

unsafe extern "C" fn on_action_written(_: u16, error: *const ble::ble_gatt_error, _: *mut ble::ble_gatt_attr, _: *mut core::ffi::c_void) -> i32 {
    if let Some(status) = done(error) { warn!("CALLS: the phone refused the call action (status {status:#x})"); }
    0
}

unsafe extern "C" fn on_gap_event(event: *mut ble::ble_gap_event, _: *mut core::ffi::c_void) -> i32 {
    if (*event).type_ as u32 != ble::BLE_GAP_EVENT_NOTIFY_RX { return 0; }
    let rx = &(*event).__bindgen_anon_1.notify_rx;
    if rx.conn_handle != WATCHED.0.load(Ordering::Relaxed) || rx.attr_handle != WATCHED.1.load(Ordering::Relaxed) || rx.attr_handle == 0 { return 0; }
    let mut data = [0u8; 8];
    let mut length = 0u16;
    // EventID, EventFlags, CategoryID, CategoryCount, NotificationUID.
    let _ = ble::ble_hs_mbuf_to_flat(rx.om, data.as_mut_ptr().cast(), 8, &mut length);
    if length < 8 { return 0; }
    let (event_id, flags, category) = (data[0], data[1], data[2]);
    let uid = u32::from_le_bytes([data[4], data[5], data[6], data[7]]);
    let mut state = STATE.lock().unwrap();
    let Some(phone) = state.as_mut() else { return 0 };
    match category {
        CATEGORY_INCOMING_CALL if event_id == EVENT_REMOVED => {
            if phone.ringing.is_some_and(|(ringing, _)| ringing == uid) {
                phone.ringing = None;
                info!("CALLS: no longer ringing");
            }
        }
        // Added, or modified. A call already ringing when the dongle subscribed counts too.
        CATEGORY_INCOMING_CALL => {
            if phone.ringing.is_none_or(|(ringing, _)| ringing != uid) {
                phone.ringing = Some((uid, Instant::now()));
                info!("CALLS: ringing (flags {flags:#04x})");
            }
        }
        CATEGORY_ACTIVE_CALL if event_id == EVENT_REMOVED => {
            if phone.active == Some(uid) { phone.active = None; info!("CALLS: call over"); }
        }
        CATEGORY_ACTIVE_CALL => {
            if phone.active != Some(uid) {
                phone.active = Some(uid);
                info!("CALLS: call in progress (flags {flags:#04x})");
            }
        }
        _ => {}
    }
    0
}
