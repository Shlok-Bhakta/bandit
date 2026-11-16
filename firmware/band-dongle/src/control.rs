//! The private control service for the Neural Playground app (CONTROL.md): status, text commands,
//! the log, and firmware updates. Every characteristic needs an encrypted (bonded) link.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use esp32_nimble::utilities::mutex::Mutex;
use esp32_nimble::utilities::BleUuid;
use esp32_nimble::{uuid128, BLECharacteristic, BLEDevice, NimbleProperties};
use log::{info, warn};

use crate::ota::{self, Updater};
use band_core::events::BatteryDetail;
use crate::profiles;
use crate::remote::{keys, Action, Kind, MediaKey, Remote};

pub const SERVICE: BleUuid = uuid128!("4e500100-3c1a-4e0b-9d1e-6f2b5a7c8d90");
const STATUS: BleUuid = uuid128!("4e500101-3c1a-4e0b-9d1e-6f2b5a7c8d90");
const COMMAND: BleUuid = uuid128!("4e500102-3c1a-4e0b-9d1e-6f2b5a7c8d90");
const LOG: BleUuid = uuid128!("4e500103-3c1a-4e0b-9d1e-6f2b5a7c8d90");
const UPDATE: BleUuid = uuid128!("4e500104-3c1a-4e0b-9d1e-6f2b5a7c8d90");
const CHANGED: BleUuid = uuid128!("4e500105-3c1a-4e0b-9d1e-6f2b5a7c8d90");

/// `band pause` / the G0 button (the XIAO's BOOT): the band is released so the phone app can use it.
pub static PAUSED: AtomicBool = AtomicBool::new(false);
/// The G0 button was pressed (it toggled `PAUSED`), or held 2 s (pair a computer): the control
/// thread logs it and opens the window.
pub static BUTTON_PRESSED: AtomicBool = AtomicBool::new(false);
pub static BUTTON_HELD: AtomicBool = AtomicBool::new(false);

/// For the serial console's `OTA` lines (tests an update over USB without the app).
static UPDATER: std::sync::OnceLock<Updater> = std::sync::OnceLock::new();

/// `OTA <base64 Update-characteristic write> <first 8 hex of its SHA-256>` from serial: the same
/// protocol as the app's. Serial drops bytes when the dongle is busy (Bluetooth writes arrive whole
/// and checked), so each line carries a checksum; a damaged line is dropped and the gap re-requested.
pub fn serial_update(line: &str) {
    use base64::Engine;
    use sha2::Digest;
    let Some(updater) = UPDATER.get() else { return warn!("UPDATE: not ready") };
    let (encoded, check) = line.rsplit_once(' ').unwrap_or((line, ""));
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(encoded) else { return };
    let digest = sha2::Sha256::digest(&bytes);
    let expected: String = digest[..4].iter().map(|b| format!("{b:02x}")).collect();
    if check == expected { updater.write_blocking(&bytes) }
}
pub fn paused() -> bool { PAUSED.load(Ordering::SeqCst) }

/// Power experiments (`power motion|writing on|auto`): keep the band's wrist motion or its
/// handwriting model on regardless of gestures, to measure what they cost. Not saved.
pub static FORCE_MOTION: AtomicBool = AtomicBool::new(false);
/// The gesture lab logs every band message in full until this uptime (s): `lab on` sets it 10
/// minutes ahead (the app says it again while its lab is open), `lab off` clears it.
static LAB_UNTIL: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
const LAB_SECONDS: u32 = 600;

fn uptime_seconds() -> u32 { (unsafe { esp_idf_svc::sys::esp_timer_get_time() } / 1_000_000) as u32 }

/// Whether the gesture lab is on (`lab on`): full gesture messages and flick peaks in the log.
pub fn lab_on() -> bool { uptime_seconds() < LAB_UNTIL.load(Ordering::Relaxed) }
pub static FORCE_WRITING: AtomicBool = AtomicBool::new(false);

// ---- the band, as the status reports it ----

#[derive(Clone)]
pub struct Band {
    pub state: &'static str,
    pub battery: Option<u8>,
    pub charging: Option<bool>,
    pub hand: Option<&'static str>,
    /// The band's own battery voltage and current (negative while charging), when it reports them.
    pub millivolts: Option<u32>,
    pub milliamps: Option<i32>,
}

static BAND: std::sync::Mutex<Band> = std::sync::Mutex::new(Band {
    state: "searching", battery: None, charging: None, hand: None, millivolts: None, milliamps: None,
});

pub fn set_band_state(state: &'static str) { BAND.lock().unwrap().state = state; }
pub fn set_band_battery(level: u8, charging: Option<bool>, detail: Option<BatteryDetail>) {
    let mut band = BAND.lock().unwrap();
    band.battery = Some(level);
    band.charging = charging;
    band.millivolts = detail.and_then(|detail| detail.millivolts);
    band.milliamps = detail.and_then(|detail| detail.milliamps);
}

/// How often the band's battery is read: every 2 minutes (each read wakes its radio), or faster
/// during a power measurement (`power sample <seconds>`).
static BATTERY_EVERY: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(120);
pub fn battery_every() -> f64 { f64::from(BATTERY_EVERY.load(Ordering::Relaxed)) }
pub fn set_band_hand(hand: Option<&'static str>) { BAND.lock().unwrap().hand = hand; }
/// The band as the status reports it (the Cardputer's screen shows it too).
pub fn band() -> Band { BAND.lock().unwrap().clone() }

// ---- the log: everything logged through `log` also lands in a ring for the app ----

/// The backlog the app can ask for (`logs`), in bytes: 200 long lines took ~60 KB of a heap that
/// has ~115 KB free, and the band's receive buffer then couldn't grow (0.12.3 crashed so).
const RING_BYTES: usize = 12 * 1024;
/// The most log text notified per 250 ms.
const PENDING_BYTES: usize = 4096;
/// 180 bytes fits every iPhone's MTU (185+).
const PIECE_BYTES: usize = 180;

/// The last `RING_BYTES` of log lines, each ending in `\n`, in one buffer allocated at boot:
/// a `String` per line, all over the heap, left it in pieces. Subscribers are sent pieces of it
/// straight from here (positions count every byte ever logged).
struct Ring {
    buffer: Vec<u8>,
    /// Where the oldest byte is, and how many there are.
    head: usize,
    len: usize,
    /// Bytes ever dropped from the front: positions below are gone.
    dropped: u64,
    /// The next position to notify live.
    live: u64,
    /// The backlog being sent: the next position and where it ends (what was logged before `logs`).
    backlog: Option<(u64, u64)>,
    /// A marker to send before anything else (the backlog's start and end).
    marker: Option<&'static str>,
}

impl Ring {
    fn push(&mut self, line: &str) {
        let size = line.len() + 1;
        if self.buffer.len() < RING_BYTES || size > RING_BYTES { return; }
        while self.len + size > RING_BYTES {
            // The oldest line goes, newline and all.
            let mut gone = 0;
            while gone < self.len {
                let byte = self.buffer[(self.head + gone) % RING_BYTES];
                gone += 1;
                if byte == b'\n' { break; }
            }
            self.head = (self.head + gone) % RING_BYTES;
            self.len -= gone;
            self.dropped += gone as u64;
        }
        for &byte in line.as_bytes().iter().chain(b"\n") {
            self.buffer[(self.head + self.len) % RING_BYTES] = byte;
            self.len += 1;
        }
    }

    fn end(&self) -> u64 { self.dropped + self.len as u64 }

    /// Bytes from position `from` (or the oldest kept, if it's gone) up to `to`, as many as fit
    /// `out` without splitting a character: where they started, and how many.
    fn copy(&self, from: u64, to: u64, out: &mut [u8]) -> (u64, usize) {
        let from = from.max(self.dropped);
        let available = to.min(self.end()).saturating_sub(from) as usize;
        let start = (from - self.dropped) as usize;
        let byte = |i: usize| self.buffer[(self.head + start + i) % RING_BYTES];
        let mut n = available.min(out.len());
        while n < available && n > 0 && byte(n) & 0xC0 == 0x80 { n -= 1; }
        for (i, slot) in out[..n].iter_mut().enumerate() { *slot = byte(i); }
        (from, n)
    }

    /// The next piece for subscribers: a marker, the backlog (after `logs`), else what was logged
    /// since the last piece. Its length (0: nothing to send).
    fn next_piece(&mut self, out: &mut [u8]) -> usize {
        if let Some(marker) = self.marker {
            if marker.len() > out.len() { return 0; }
            out[..marker.len()].copy_from_slice(marker.as_bytes());
            self.marker = None;
            return marker.len();
        }
        if let Some((from, to)) = self.backlog {
            let (start, n) = self.copy(from, to, out);
            if n > 0 {
                self.backlog = Some((start + n as u64, to));
                return n;
            }
            self.backlog = None;
            self.marker = Some("--- live ---\n");
            return self.next_piece(out);
        }
        let (start, n) = self.copy(self.live, u64::MAX, out);
        self.live = start + n as u64;
        n
    }

    /// `logs`: the backlog, then what's logged from now on.
    fn send_backlog(&mut self) {
        self.backlog = Some((0, self.end()));
        self.live = self.end();
        self.marker = Some("--- backlog ---\n");
    }

    /// No subscribers: nothing waits for them.
    fn skip(&mut self) {
        self.live = self.end();
        self.backlog = None;
        self.marker = None;
    }
}

static RING: std::sync::Mutex<Ring> = std::sync::Mutex::new(Ring {
    buffer: Vec::new(), head: 0, len: 0, dropped: 0, live: 0, backlog: None, marker: None,
});

struct Tee;

static ESP: esp_idf_svc::log::EspLogger = esp_idf_svc::log::EspIdfLogger::new(esp_idf_svc::log::EspIdfLogFilter::new());

impl log::Log for Tee {
    fn enabled(&self, metadata: &log::Metadata) -> bool { metadata.level() <= log::Level::Info }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) { return; }
        ESP.log(record);
        let level = match record.level() { log::Level::Error => "E", log::Level::Warn => "W", _ => "I" };
        let uptime = unsafe { esp_idf_svc::sys::esp_timer_get_time() } / 1000;
        let mut line = format!("{}.{:03} {level} {}", uptime / 1000, uptime % 1000, record.args());
        if line.len() > 300 {
            let mut end = 300;
            while !line.is_char_boundary(end) { end -= 1; }
            line.truncate(end);
        }
        if let Ok(mut ring) = RING.try_lock() { ring.push(&line); }
    }

    fn flush(&self) {}
}

static TEE: Tee = Tee;

pub fn init_logging() {
    // First thing at boot, outside the main heap region (it keeps one block that much bigger).
    RING.lock().unwrap().buffer = crate::memory::in_spare_regions(0, || vec![0; RING_BYTES]);
    let _ = log::set_logger(&TEE);
    log::set_max_level(log::LevelFilter::Info);
}

// ---- the service ----

pub struct Control {
    status: Arc<Mutex<BLECharacteristic>>,
    changed: Arc<Mutex<BLECharacteristic>>,
    log: Arc<Mutex<BLECharacteristic>>,
    remote: Remote,
}

/// The connection of the app that last said `hello`: the status's `you`.
static APP_HANDLE: std::sync::atomic::AtomicU16 = std::sync::atomic::AtomicU16::new(0);

impl Control {
    /// Registers the service; call before advertising starts (the GATT table is built then).
    pub fn new(remote: &Remote) -> Self {
        let server = BLEDevice::take().get_server();
        let service = server.create_service(SERVICE);
        // Only ever add characteristics at the end (this is the last service): hosts cache the
        // handles, and a characteristic that gains a descriptor shifts every one after it. iOS kept
        // writing commands to the old handles when 0.11.0 gave Status a notify descriptor.
        let status = service.lock().create_characteristic(STATUS, NimbleProperties::READ | NimbleProperties::READ_ENC);
        let command = service.lock().create_characteristic(COMMAND, NimbleProperties::WRITE | NimbleProperties::WRITE_ENC);
        let log = service.lock().create_characteristic(LOG, NimbleProperties::NOTIFY | NimbleProperties::READ | NimbleProperties::READ_ENC);
        let update = service.lock().create_characteristic(
            UPDATE,
            NimbleProperties::WRITE | NimbleProperties::WRITE_NO_RSP | NimbleProperties::WRITE_ENC | NimbleProperties::NOTIFY,
        );
        let changed = service.lock().create_characteristic(CHANGED, NimbleProperties::NOTIFY);

        // The status is longer than one packet, so it's read in pieces, and esp32-nimble only calls
        // `on_read` for some of them (in practice: the first read only, which froze the app's
        // status). The control thread refreshes the value instead (`spawn`).
        status.lock().set_value(status_json(remote, 0).as_bytes());
        let commander = remote.clone();
        profiles::start(remote.clone());
        command.lock().on_write(move |args| {
            let text = String::from_utf8_lossy(args.recv_data()).trim().to_string();
            let handle = args.desc().conn_handle();
            // A profile upload's steps must run in the order they were written: one worker.
            if let Some(rest) = text.strip_prefix("profiles ") { return profiles::enqueue(rest.trim()); }
            // Commands can block briefly (NVS, a key press): run them off the Bluetooth host task.
            let remote = commander.clone();
            let _ = crate::memory::spawn(c"command", 6144, move || run(&remote, &text, Some(handle)));
        });
        let updater = Updater::start(update.clone());
        let _ = UPDATER.set(updater.clone());
        update.lock().on_write(move |args| updater.write(args.recv_data(), args.desc().conn_handle()));
        Self { status, changed, log, remote: remote.clone() }
    }

    /// Notifies new log text, keeps the dongle discoverable, and calls `at_30s` once, half a
    /// minute after it starts. Runs forever on its own thread.
    pub fn spawn(self, at_30s: fn()) {
        // It used 2.8 KB of 6 (0.15.1, the app connected).
        crate::memory::spawn(c"control", 4608, move || {
                let mut ticks = 0u32;
                let (mut last, mut nudged) = (String::new(), 0u32);
                let mut piece = [0u8; PIECE_BYTES];
                loop {
                    std::thread::sleep(Duration::from_millis(250));
                    ticks += 1;
                    if ticks == 120 { at_30s(); }
                    if BUTTON_PRESSED.swap(false, Ordering::SeqCst) {
                        info!("BOOT button: band link {}", if paused() { "PAUSED (band released for the phone app)" } else { "resumed" });
                    }
                    if BUTTON_HELD.swap(false, Ordering::SeqCst) {
                        info!("BOOT button held: pairing a computer");
                        self.remote.open_pairing(Some(Kind::Mac));
                    }
                    if ticks % 8 == 0 { self.remote.keep_discoverable(); self.remote.tune_links(); }
                    if ticks % 4 == 0 {
                        let json = status_json(&self.remote, APP_HANDLE.load(Ordering::SeqCst));
                        self.status.lock().set_value(json.as_bytes());
                        // Subscribers get a one-byte nudge ("?") when something in it changed (not
                        // the uptime or heap), and once a minute: a whole status doesn't fit in a
                        // notification, so they read it. It keeps the app's Live Activity current
                        // while the app is in the background.
                        let key = without_counters(&json);
                        if key != last || ticks - nudged >= 240 {
                            last = key;
                            nudged = ticks;
                            let changed = self.changed.lock();
                            for (handle, ..) in self.remote.hosts() { let _ = changed.notify_with(b"?", handle); }
                        }
                    }
                    // Up to 4 KB a tick, a piece at a time out of the ring: the backlog, then what
                    // was logged meanwhile.
                    if self.log.lock().subscribed_count() == 0 {
                        RING.lock().unwrap().skip();
                        continue;
                    }
                    let mut sent = 0;
                    while sent < PENDING_BYTES {
                        let n = RING.lock().unwrap().next_piece(&mut piece);
                        if n == 0 { break; }
                        self.log.lock().set_value(&piece[..n]).notify();
                        sent += n;
                        std::thread::sleep(Duration::from_millis(8));
                    }
                }
            })
            .expect("control thread");
    }
}

/// The status without `up` and `heap`, which change every second.
fn without_counters(json: &str) -> String {
    match (json.find(",\"up\":"), json.find(",\"band\":")) {
        (Some(start), Some(end)) if start < end => format!("{}{}", &json[..start], &json[end..]),
        _ => json.to_string(),
    }
}

fn json_string(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => {}
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn json_option<T: std::fmt::Display>(value: Option<T>) -> String { value.map(|v| v.to_string()).unwrap_or_else(|| "null".into()) }

/// The most a GATT attribute holds: the status must fit, whole, or the app can't decode it.
const STATUS_MAX: usize = 512;

/// How much of the status fits: what's left out, step by step, when there are many hosts.
#[derive(Clone, Copy)]
struct Budget {
    name_chars: usize,
    error_chars: usize,
    host_profiles: bool,
    /// Leave out what the app can do without: heap, the air mouse, an idle update, `pe`.
    lean: bool,
    /// At most this many hosts (the active one first).
    hosts: usize,
}

/// The status (CONTROL.md). With many hosts, their names are cut short, then an error's text,
/// then their profiles, then the optional fields, then hosts other than the active one, so it is
/// always whole (at most `STATUS_MAX` bytes).
pub fn status_json(remote: &Remote, you: u16) -> String {
    let full = Budget { name_chars: 20, error_chars: 60, host_profiles: true, lean: false, hosts: usize::MAX };
    let mut budgets = vec![
        full,
        Budget { name_chars: 8, ..full },
        Budget { name_chars: 0, ..full },
        Budget { name_chars: 0, error_chars: 0, ..full },
        Budget { name_chars: 0, error_chars: 0, host_profiles: false, ..full },
        Budget { name_chars: 0, error_chars: 0, host_profiles: false, lean: true, ..full },
    ];
    budgets.extend((1..=4).rev().map(|hosts| Budget { name_chars: 0, error_chars: 0, host_profiles: false, lean: true, hosts }));
    budgets.into_iter().map(|budget| status_with(remote, you, budget))
        .find(|json| json.len() <= STATUS_MAX)
        .unwrap_or_else(|| status_with(remote, you, Budget { name_chars: 0, error_chars: 0, host_profiles: false, lean: true, hosts: 0 }))
}

fn status_with(remote: &Remote, you: u16, budget: Budget) -> String {
    let Budget { name_chars, error_chars, host_profiles, lean, hosts: max_hosts } = budget;
    let band = BAND.lock().unwrap().clone();
    let (slot, verify) = ota::running();
    let update = ota::progress();
    let uptime = unsafe { esp_idf_svc::sys::esp_timer_get_time() } / 1_000_000;
    let heap = unsafe { esp_idf_svc::sys::esp_get_free_heap_size() };
    let state = if paused() { "paused" } else { band.state };
    let mut hosts = remote.hosts();
    let mode = hosts.iter().find(|host| host.3).map(|host| host.4.clone()).unwrap_or_default();
    if hosts.len() > max_hosts {
        hosts.sort_by_key(|host| !host.3);
        hosts.truncate(max_hosts);
    }
    let hosts: Vec<String> = hosts.into_iter().map(|(handle, kind, name, active, profile)| {
        let name: String = name.chars().take(name_chars).collect();
        // Defaults are left out to save room: os `mac`, name "", act false.
        let os = kind.os().filter(|os| *os != "mac").map(|os| format!(",\"os\":\"{os}\"")).unwrap_or_default();
        let name = if name.is_empty() { String::new() } else { format!(",\"n\":{}", json_string(&name)) };
        let active = if active { ",\"act\":true" } else { "" };
        let profile = if host_profiles { format!(",\"p\":\"{profile}\"") } else { String::new() };
        format!("{{\"h\":{handle},\"k\":\"{}\"{os}{name}{active}{profile}}}", kind.name())
    }).collect();
    let profile_error = profiles::error().filter(|_| !lean)
        .map(|e| format!(",\"pe\":{}", json_string(&e.chars().take(error_chars).collect::<String>()))).unwrap_or_default();
    let error: String = update.error.chars().take(error_chars).collect();
    let mouse = remote.mouse_settings();
    let heap = if lean { String::new() } else { format!(",\"heap\":{heap}") };
    let mouse = if lean { String::new() } else {
        format!(",\"mouse\":{{\"sp\":{},\"fx\":{},\"fy\":{},\"ty\":{}}}", mouse.speed, mouse.flip_x, mouse.flip_y, mouse.typing)
    };
    let update = if lean && update.state == "idle" { String::new() } else {
        format!(",\"upd\":{{\"s\":\"{}\",\"got\":{},\"of\":{},\"e\":{}}}", update.state, update.got, update.of, json_string(&error))
    };
    format!(
        "{{\"fw\":\"{}\",\"id\":\"{}\",\"slot\":\"{slot}\",\"verify\":{verify},\"up\":{uptime}{heap},\
         \"band\":{{\"s\":\"{state}\",\"bat\":{},\"chg\":{},\"hand\":{},\"mv\":{},\"ma\":{}}},\
         \"mode\":\"{mode}\",\"ph\":\"{}\"{profile_error}{mouse},\"pair\":{},\"you\":{you},\"hosts\":[{}]{update}}}",
        env!("CARGO_PKG_VERSION"), ota::build_id(),
        json_option(band.battery), json_option(band.charging), json_option(band.hand.map(|hand| format!("\"{hand}\""))),
        json_option(band.millivolts), json_option(band.milliamps),
        profiles::hash(), remote.pairing_seconds(), hosts.join(","),
    )
}

/// A control command (CONTROL.md), from the app (`from` = its connection handle) or serial.
pub fn run(remote: &Remote, line: &str, from: Option<u16>) {
    let (verb, rest) = line.split_once(' ').map(|(verb, rest)| (verb, rest.trim())).unwrap_or((line, ""));
    let handle_arg = |text: &str| text.split_whitespace().next().and_then(|h| h.parse::<u16>().ok());
    match verb {
        "hello" => if let Some(handle) = from {
            APP_HANDLE.store(handle, Ordering::SeqCst);
            remote.hello(handle, if rest.is_empty() { "iPhone" } else { rest });
            info!("CONTROL: the app on host {handle} says hello ({rest})");
        },
        "target" => {
            let ok = if rest == "next" { remote.target(None) } else { handle_arg(rest).is_some_and(|h| remote.target(Some(h))) };
            if !ok { warn!("CONTROL: no connected host {rest}"); }
        }
        // Before 0.11, `mode` set every computer's mode: now it's the active host's profile.
        // 0.9's mouse mode is part of write.
        "mode" => if let Err(error) = remote.set_profile_id(None, if rest == "mouse" { "write" } else { rest }) { warn!("CONTROL: {error}") },
        "profile" => {
            let (host, target) = match rest.split_once(' ') {
                Some((handle, id)) if handle.parse::<u16>().is_ok() => (handle.parse().ok(), id.trim()),
                _ => (None, rest),
            };
            let result = match target {
                "next" => remote.set_profile(host, np_profiles::ProfileTarget::Next),
                "previous" => remote.set_profile(host, np_profiles::ProfileTarget::Previous),
                id => remote.set_profile_id(host, id),
            };
            if let Err(error) = result { warn!("CONTROL: {error}"); }
        }
        // A computer's helper (np-appwatch): an agent finished, asks something, or failed.
        // Also any pattern of the dongle's set by name, or one being designed (`buzz try <pattern>`).
        "buzz" => match crate::remote::Alert::from_word(rest) {
            Some(alert) => remote.alert(alert),
            None => match rest.strip_prefix("try ") {
                Some(text) => match np_profiles::parse_pattern(text.trim()) {
                    Ok(pattern) => remote.play(pattern),
                    Err(error) => warn!("CONTROL: buzz try: {error}"),
                },
                None => match profiles::current().pattern(rest) {
                    Some(pattern) => remote.play(pattern),
                    None => warn!("CONTROL: buzz done|question|error|<pattern name>|try <pattern>"),
                },
            },
        },
        "lab" => match rest {
            "on" => {
                let was = lab_on();
                LAB_UNTIL.store(uptime_seconds() + LAB_SECONDS, Ordering::Relaxed);
                if !was { info!("LAB on: every band message in full, and flick peaks, for {} min", LAB_SECONDS / 60); }
            }
            "off" => { LAB_UNTIL.store(0, Ordering::Relaxed); info!("LAB off"); }
            _ => warn!("CONTROL: lab on|off"),
        },
        // A computer's helper (np-appwatch): the bundle id of the app now in front (none: it
        // paused or quit, so the computer goes back to its own profile).
        "app" => match from {
            Some(handle) => if let Err(error) = remote.app_changed(handle, rest) { warn!("CONTROL: {error}") },
            None => warn!("CONTROL: app [bundle id] comes from a connected computer"),
        },
        // From serial (the app's arrive in `Control::new`'s write handler, in order).
        "profiles" => profiles::enqueue(rest),
        "mouse" => {
            let mut settings = remote.mouse_settings();
            match rest.split_once(' ').unwrap_or((rest, "")) {
                ("speed", n) if n.parse::<u8>().is_ok_and(|n| (1..=10).contains(&n)) => settings.speed = n.parse().unwrap(),
                ("flipx", on) => settings.flip_x = on != "off" && (on == "on" || !settings.flip_x),
                ("flipy", on) => settings.flip_y = on != "off" && (on == "on" || !settings.flip_y),
                ("type", on) => settings.typing = on != "off" && (on == "on" || !settings.typing),
                _ => { warn!("CONTROL: mouse speed <1-10> | mouse flipx|flipy|type [on|off]"); return; }
            }
            remote.set_mouse_settings(settings);
        }
        "pair" => match (rest, Kind::from_word(rest)) {
            ("close", _) => remote.open_pairing(None),
            (_, Some(kind)) => remote.open_pairing(Some(kind)),
            _ => warn!("CONTROL: pair phone|mac|windows|linux|tv|computer | pair close"),
        },
        "kind" => match rest.split_once(' ').map(|(handle, kind)| (handle.parse::<u16>(), Kind::from_word(kind.trim()))) {
            Some((Ok(handle), Some(kind))) => if let Err(error) = remote.set_kind(handle, kind) { warn!("CONTROL: {error}") },
            _ => warn!("CONTROL: kind <h> phone|mac|windows|linux|tv"),
        },
        "name" => match rest.split_once(' ') {
            Some((handle, name)) if handle.parse::<u16>().is_ok() => remote.rename(handle.parse().unwrap(), name.trim()),
            _ => warn!("CONTROL: name <h> <text>"),
        },
        "forget" => if !handle_arg(rest).is_some_and(|h| remote.forget(h)) { warn!("CONTROL: no connected host {rest}") },
        "band" => match rest {
            "pause" => { PAUSED.store(true, Ordering::SeqCst); info!("CONTROL: band link paused (released for the phone app)"); }
            "resume" => { PAUSED.store(false, Ordering::SeqCst); info!("CONTROL: band link resumed"); }
            _ => warn!("CONTROL: band pause | band resume"),
        },
        "key" => {
            let action = match rest {
                "playpause" => Action::Media(MediaKey::PlayPause),
                "next" => Action::Media(MediaKey::Next),
                "previous" => Action::Media(MediaKey::Previous),
                "volup" => Action::Media(MediaKey::VolumeUp),
                "voldown" => Action::Media(MediaKey::VolumeDown),
                "voice" => Action::Media(MediaKey::Voice),
                "phonemute" => Action::PhoneMute,
                "teamsmute" => Action::TEAMS_MUTE,
                "right" => Action::Key { modifiers: 0, usage: keys::RIGHT },
                "left" => Action::Key { modifiers: 0, usage: keys::LEFT },
                "blank" => Action::Key { modifiers: 0, usage: keys::B },
                _ => { warn!("CONTROL: unknown key {rest}"); return; }
            };
            remote.send(action);
        }
        "power" if rest.starts_with("sample") => {
            let seconds = rest["sample".len()..].trim().parse::<u32>().unwrap_or(120).clamp(5, 600);
            BATTERY_EVERY.store(seconds, Ordering::Relaxed);
            info!("POWER: battery read every {seconds} s");
        }
        "power" => {
            let flag = match rest.split_whitespace().next() { Some("motion") => &FORCE_MOTION, Some("writing") => &FORCE_WRITING, _ => {
                warn!("CONTROL: power motion|writing on|auto"); return;
            } };
            let on = rest.ends_with(" on");
            flag.store(on, Ordering::SeqCst);
            info!("POWER: {rest} ({})", if on { "forced on for a measurement" } else { "as gestures need it" });
        }
        "logs" => RING.lock().unwrap().send_backlog(),
        "status" => info!("STATUS {}", status_json(remote, from.unwrap_or(0))),
        "bench" => crate::spawn_bench(remote.clone()),
        "reboot" => {
            info!("CONTROL: rebooting");
            std::thread::sleep(Duration::from_millis(300));
            unsafe { esp_idf_svc::sys::esp_restart() };
        }
        _ => warn!("CONTROL: unknown command {:?}", line.chars().take(60).collect::<String>()),
    }
}
