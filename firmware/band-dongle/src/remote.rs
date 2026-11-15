//! The dongle's host side: one Bluetooth HID device that several hosts (an iPhone, a laptop) can be
//! paired with at once. Keys go only to the **active** host, never mirrored.
//!
//! Each host is a phone or a computer, and reads a different report map: a phone sees only
//! Consumer Control media keys (report 5) and a headset's phone-mute button (report 6), because
//! iOS hides its on-screen keyboard while any keyboard is connected. A computer also sees a
//! keyboard (report 1, for slides and Teams shortcuts) and a mouse (report 2). Hosts cache the
//! map when they pair, so the kind is decided then: new devices pair as phones, unless a
//! "pair a computer" window is open (for 2 minutes after power-up, the app, the `pair computer`
//! command, or a long BOOT press).
//!
//! Pairing is closed by default once a host is known: an unknown device that pairs outside a
//! window is disconnected and its pairing deleted.

use std::sync::Arc;
use std::time::{Duration, Instant};

use esp32_nimble::utilities::mutex::Mutex;
use esp32_nimble::utilities::BleUuid;
use esp32_nimble::{BLEAdvertisementData, BLEAddress, BLEAddressType, BLECharacteristic, BLEConnDesc, BLEDevice, BLEHIDDevice};
use esp_idf_svc::nvs::{EspNvs, NvsDefault};
use log::{info, warn};
use np_profiles::{HostKind, Hosts, ProfileSet, ProfileTarget};

use crate::profiles;

pub const KEYBOARD_ID: u8 = 1;
pub const MOUSE_ID: u8 = 2;
pub const CONSUMER_ID: u8 = 5;
pub const TELEPHONY_ID: u8 = 6;

/// Keyboard, report 1: modifiers, reserved, six key usages.
const KEYBOARD_COLLECTION: &[u8] = &[
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, KEYBOARD_ID, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x06,
    0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0,
];

/// Mouse, report 2: eight buttons, then relative X, Y and wheel (the air mouse). The same four
/// bytes as before 0.16's buttons 4–8 (they were padding), so a host that kept the old map just
/// ignores them. On an iPhone the pointer needs AssistiveTouch, which also gives buttons 4–8 any
/// action (Home, App Switcher, Control Center, Screenshot, a Shortcut...).
const MOUSE_COLLECTION: &[u8] = &[
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, MOUSE_ID, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01,
    0x29, 0x08, 0x15, 0x00, 0x25, 0x01, 0x95, 0x08, 0x75, 0x01, 0x81, 0x02,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08,
    0x95, 0x03, 0x81, 0x06, 0xC0, 0xC0,
];

/// Consumer Control, report 5: bit 0 Next, 1 Previous, 2 Stop, 3 Play/Pause, 4 Mute, 5 Vol+, 6 Vol−,
/// 7 Voice Command (Apple keyboards' microphone key: dictation on a Mac, Siri on an iPhone).
const CONSUMER_COLLECTION: &[u8] = &[
    0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, CONSUMER_ID, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08,
    0x09, 0xB5, 0x09, 0xB6, 0x09, 0xB7, 0x09, 0xCD, 0x09, 0xE2, 0x09, 0xE9, 0x09, 0xEA, 0x09, 0xCF,
    0x81, 0x02, 0xC0,
];

/// Telephony (headset), report 6: bit 0 Phone Mute (a toggle), then padding.
const TELEPHONY_COLLECTION: &[u8] = &[
    0x05, 0x0B, 0x09, 0x05, 0xA1, 0x01, 0x85, TELEPHONY_ID, 0x15, 0x00, 0x25, 0x01, 0x09, 0x2F, 0x75, 0x01,
    0x95, 0x01, 0x81, 0x06, 0x75, 0x07, 0x95, 0x01, 0x81, 0x01, 0xC0,
];

const PAIRING_WINDOW: Duration = Duration::from_secs(120);
/// Hosts that can be connected at once (the band is a separate, client-side link).
const MAX_HOSTS: usize = 5;

/// With no host connected (plugged in, or the last one went away), the dongle advertises every
/// 20–30 ms for this long so the computer reconnects at once, then every 100–150 ms: it's on
/// whenever a host slot is free, and a busy radio makes the band link miss connection events (the
/// band then retransmits). Bonded hosts still reconnect within a second or so. Units: 0.625 ms.
const FAST_ADVERTISING: Duration = Duration::from_secs(30);
const FAST_INTERVAL: (u16, u16) = (32, 48);
const SLOW_INTERVAL: (u16, u16) = (160, 240);
/// A host's link at 15 ms with no skipped events, so the air mouse's moves (and every key) reach
/// it as they come (macOS and iOS otherwise pick slower intervals). Within Apple's rules: min = max
/// = 15 ms, supervision 2 s. The dongle runs on USB power; a phone spends a little more battery.
fn request_fast_link(handle: u16) {
    let params = esp_idf_svc::sys::ble_gap_upd_params {
        itvl_min: 12, itvl_max: 12, latency: 0, supervision_timeout: 200,
        min_ce_len: esp_idf_svc::sys::BLE_GAP_INITIAL_CONN_MIN_CE_LEN as _,
        max_ce_len: esp_idf_svc::sys::BLE_GAP_INITIAL_CONN_MAX_CE_LEN as _,
    };
    let rc = unsafe { esp_idf_svc::sys::ble_gap_update_params(handle, &params) };
    if rc != 0 { warn!("HOST: couldn't ask host {handle} for a 15 ms link (rc {rc})"); }
}

/// When each computer's link was last asked to be fast (`Remote::tune_links`).
static LINK_ASKED: std::sync::Mutex<Vec<(u16, Instant)>> = std::sync::Mutex::new(Vec::new());

/// Since when no host has been connected, and whether advertising runs at the fast interval.
static ALONE: std::sync::Mutex<(Option<Instant>, bool)> = std::sync::Mutex::new((None, true));
/// Set while the band's link is being made: a host connecting at the same moment makes it fail
/// (0x3e, then retries for seconds).
static HELD: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum MediaKey {
    Next = 0,
    Previous = 1,
    PlayPause = 3,
    /// Unmapped (swipe down misfired while scrolling), kept so the layout, and the pairing, stay the same.
    #[allow(dead_code)]
    Mute = 4,
    VolumeUp = 5,
    VolumeDown = 6,
    /// Apple's microphone key: dictation on a Mac, Siri on an iPhone.
    Voice = 7,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind { Phone, Mac, Windows, Linux, Tv }

impl Kind {
    pub const ALL: [Kind; 5] = [Kind::Phone, Kind::Mac, Kind::Windows, Kind::Linux, Kind::Tv];

    /// The status JSON's `k`: `phone`, `computer` or `tv` (`os` says which computer).
    pub fn name(self) -> &'static str {
        match self { Kind::Phone => "phone", Kind::Mac | Kind::Windows | Kind::Linux => "computer", Kind::Tv => "tv" }
    }
    /// What commands call it (`pair <kind>`, `kind <h> <kind>`).
    pub fn word(self) -> &'static str {
        match self { Kind::Phone => "phone", Kind::Mac => "mac", Kind::Windows => "windows", Kind::Linux => "linux", Kind::Tv => "tv" }
    }
    pub fn from_word(word: &str) -> Option<Kind> {
        match word { "computer" => Some(Kind::Mac), word => Kind::ALL.into_iter().find(|kind| kind.word() == word) }
    }
    pub fn os(self) -> Option<&'static str> {
        match self { Kind::Mac => Some("mac"), Kind::Windows => Some("windows"), Kind::Linux => Some("linux"), _ => None }
    }
    fn label(self) -> &'static str {
        match self { Kind::Phone => "Phone", Kind::Mac => "Mac", Kind::Windows => "Windows PC", Kind::Linux => "Linux PC", Kind::Tv => "TV" }
    }
    /// NVS code; `c` (a computer, before the OS was known) reads as a Mac.
    fn code(self) -> char { match self { Kind::Phone => 'p', Kind::Mac => 'c', Kind::Windows => 'w', Kind::Linux => 'x', Kind::Tv => 't' } }
    fn from_code(code: &str) -> Kind {
        Kind::ALL.into_iter().find(|kind| code.starts_with(kind.code())).unwrap_or(Kind::Phone)
    }
    /// A computer: modes, write mode's handwriting and mouse.
    pub fn computer(self) -> bool { matches!(self, Kind::Mac | Kind::Windows | Kind::Linux) }

    pub fn host_kind(self) -> HostKind {
        match self { Kind::Phone => HostKind::Phone, Kind::Mac => HostKind::Mac, Kind::Windows => HostKind::Windows,
                     Kind::Linux => HostKind::Linux, Kind::Tv => HostKind::Tv }
    }
    /// Reads the computer report map (keyboard and mouse); a phone's has no keyboard, because
    /// iOS hides its on-screen keyboard while a keyboard is connected (a mouse since 0.16). Hosts cache the map when
    /// they pair, so a host can't move between the two without pairing again.
    pub fn keyboard(self) -> bool { self != Kind::Phone }
    /// Shortcuts are written with ⌘ (GUI); Windows and Linux use Ctrl for the same ones.
    fn modifiers(self, modifiers: u8) -> u8 {
        if matches!(self, Kind::Windows | Kind::Linux) && modifiers & keys::GUI != 0 {
            (modifiers & !keys::GUI) | keys::CTRL
        } else {
            modifiers
        }
    }
}

/// The air mouse's settings (NVS "mouse": speed, then flags bit 0 flip x, bit 1 flip y, bit 2
/// no typing).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MouseSettings {
    /// 1–10.
    pub speed: u8,
    pub flip_x: bool,
    pub flip_y: bool,
    /// The band's handwriting typed in write mode (it may quiet the gyro: unverified). Off,
    /// write mode is only the air mouse.
    pub typing: bool,
}

impl Default for MouseSettings {
    fn default() -> Self { Self { speed: 5, flip_x: false, flip_y: false, typing: true } }
}

/// Mouse buttons in report 2's first byte.
pub mod buttons {
    pub const LEFT: u8 = 1;
    pub const RIGHT: u8 = 2;
    pub const MIDDLE: u8 = 4;
}

/// Keyboard usages and modifiers the dongle sends itself (profiles bring their own).
pub mod keys {
    pub const CTRL: u8 = 0x01;
    pub const SHIFT: u8 = 0x02;
    pub const GUI: u8 = 0x08;
    pub const B: u8 = 0x05;
    pub const M: u8 = 0x10;
    pub const RIGHT: u8 = 0x4F;
    pub const LEFT: u8 = 0x50;
    pub const ENTER: u8 = 0x28;
    pub const BACKSPACE: u8 = 0x2A;
    pub const SPACE: u8 = 0x2C;
    pub const ALT: u8 = 0x04;
    pub const TAB: u8 = 0x2B;

    /// A typed character on a US layout: (modifiers, usage).
    pub fn for_char(c: char) -> Option<(u8, u8)> {
        np_profiles::char_usage(c).map(|(shift, usage)| (if shift { SHIFT } else { 0 }, usage))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Action {
    Media(MediaKey),
    /// The headset phone-mute button.
    PhoneMute,
    /// A keyboard chord (computers only).
    Key { modifiers: u8, usage: u8 },
}

impl Action {
    pub const TEAMS_MUTE: Action = Action::Key { modifiers: keys::GUI | keys::SHIFT, usage: keys::M };
}

struct Host {
    handle: u16,
    addr: Option<[u8; 6]>,
    kind: Kind,
    name: String,
    /// Encrypted and accepted: gestures may go here.
    ready: bool,
    /// Its active profile's id: what it resolves to is looked up in whichever set is current
    /// (`State::effective`), so a new set never pairs an old index with a different profile.
    profile: String,
    /// Switched by the app in front (`app_changed`): the profile to go back to for an app no
    /// profile lists. Not saved: the host's helper says which app is in front when it reconnects.
    home: Option<String>,
}

#[derive(Clone)]
struct Known {
    addr: [u8; 6],
    kind: Kind,
    name: String,
    /// The profile it was last switched to ("": the set's start profile for its kind).
    profile: String,
}

/// What a computer's helper asks the band to say (`buzz`), each with its own pattern.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alert {
    /// An agent finished (Copilot's turn ended).
    Done,
    /// An agent is asking you something.
    Question,
    Error,
}

impl Alert {
    pub fn from_word(word: &str) -> Option<Alert> {
        match word { "done" => Some(Alert::Done), "question" => Some(Alert::Question), "error" => Some(Alert::Error), _ => None }
    }
}

struct State {
    hosts: Vec<Host>,
    known: Vec<Known>,
    active: Option<u16>,
    preferred: Option<[u8; 6]>,
    /// The one mode earlier firmware kept for every computer: a computer with no profile of its
    /// own starts in it.
    legacy_mode: Option<&'static str>,
    pairing: Option<(Kind, Instant)>,
    /// The active host changed (the band buzzes: once for a phone, twice for a computer).
    switched: Option<Kind>,
    /// The active host's profile changed: that profile's buzz pattern.
    profile_switched: Option<np_profiles::Pattern>,
    /// Patterns asked for over the control service (`buzz <name>`, `buzz try <pattern>`).
    patterns: std::collections::VecDeque<np_profiles::Pattern>,
    /// Something on a computer wants you (`buzz`): its pattern, for the band.
    /// Alerts not yet buzzed, oldest first (a few: they can come close together).
    alerts: std::collections::VecDeque<Alert>,
    /// Bumped whenever where gestures go, or what they do there, changes (a tap waiting for a
    /// second one is dropped then rather than acted on somewhere else).
    generation: u32,
    /// A `hold:` chord held down on a host (push-to-talk): (handle, modifiers, usage).
    held: Option<(u16, u8, u8)>,
    /// The saved hosts couldn't be read: nothing is saved over them, and bonded devices that
    /// aren't in the (empty) list are kept for this session rather than refused.
    unreadable: bool,
}

impl State {
    fn window(&mut self) -> Option<Kind> {
        match self.pairing {
            Some((kind, opened)) if opened.elapsed() < PAIRING_WINDOW => Some(kind),
            Some(_) => { self.pairing = None; None }
            None => None,
        }
    }

    fn activate(&mut self, handle: u16) {
        if self.active == Some(handle) { return; }
        let Some(host) = self.hosts.iter().find(|host| host.handle == handle && host.ready) else { return };
        self.active = Some(handle);
        self.preferred = host.addr;
        self.switched = Some(host.kind);
        self.generation += 1;
        info!("ROUTE: gestures now go to {} ({})", host.name, host.kind.word());
    }

    fn known_index(&self, addr: [u8; 6]) -> Option<usize> { self.known.iter().position(|known| known.addr == addr) }

    /// A host's profile in `set`: its own, if the set has it and allows the host, else `profile_for`.
    fn effective(&self, set: &ProfileSet, host: &Host) -> usize {
        set.index_of(&host.profile).filter(|i| set.profiles[*i].allows(host.kind.host_kind()))
            .unwrap_or_else(|| self.profile_for(set, host.addr, host.kind))
    }

    /// The profile a host is in: the one it was last switched to, if the set still has it and it
    /// allows this kind; earlier firmware's mode for a computer; else the set's start for its kind.
    fn profile_for(&self, set: &ProfileSet, addr: Option<[u8; 6]>, kind: Kind) -> usize {
        let allowed = |index: &usize| set.profiles[*index].allows(kind.host_kind());
        let saved = addr.and_then(|addr| self.known_index(addr)).map(|i| self.known[i].profile.as_str()).filter(|id| !id.is_empty());
        saved.and_then(|id| set.index_of(id)).filter(allowed)
            .or_else(|| self.legacy_mode.filter(|_| kind.computer()).and_then(|id| set.index_of(id)).filter(allowed))
            .unwrap_or_else(|| set.start_for(kind.host_kind()))
    }
}

struct Inner {
    keyboard: Arc<Mutex<BLECharacteristic>>,
    consumer: Arc<Mutex<BLECharacteristic>>,
    telephony: Arc<Mutex<BLECharacteristic>>,
    /// Battery Service level (0x2A19): the band's battery, which hosts show as this device's.
    battery: Arc<Mutex<BLECharacteristic>>,
    mouse: Arc<Mutex<BLECharacteristic>>,
    mouse_settings: std::sync::Mutex<MouseSettings>,
    state: std::sync::Mutex<State>,
    nvs: std::sync::Mutex<EspNvs<NvsDefault>>,
    /// Keyboard reports go out one press-and-release at a time: a held chord's release can't land
    /// between another key's press and its release (which would hold the chord again).
    keys: std::sync::Mutex<()>,
    /// One save of the hosts at a time, snapshot and write together: a slower save can't write an
    /// older list over a newer one.
    saving: std::sync::Mutex<()>,
}

#[derive(Clone)]
pub struct Remote(Arc<Inner>);

fn addr_hex(addr: [u8; 6]) -> String { addr.iter().rev().map(|b| format!("{b:02X}")).collect::<Vec<_>>().join(":") }

/// The addresses of the hosts saved in NVS (little-endian).
pub fn known_addresses(nvs: &EspNvs<NvsDefault>) -> Vec<[u8; 6]> {
    load_known(nvs).ok().flatten().unwrap_or_default().into_iter().map(|known| known.addr).collect()
}

/// The saved hosts: `Ok(None)` before any were saved, `Err` if they're there but can't be read
/// (they must not be replaced by adopted phones then).
fn load_known(nvs: &EspNvs<NvsDefault>) -> Result<Option<Vec<Known>>, String> {
    let Some(len) = nvs.str_len("hosts").map_err(|e| e.to_string())? else { return Ok(None) };
    let mut buffer = vec![0u8; len + 1];
    let text = nvs.get_str("hosts", &mut buffer).map_err(|e| e.to_string())?.ok_or("vanished")?;
    Ok(Some(text.lines().filter_map(|line| {
        // addr|kind|name|profile (before 0.11: no profile).
        let mut fields = line.splitn(4, '|');
        let hex = fields.next()?;
        let kind = Kind::from_code(fields.next()?);
        let name = fields.next().unwrap_or("").to_string();
        let profile = fields.next().unwrap_or("").to_string();
        let bytes: Vec<u8> = (0..6).filter_map(|i| u8::from_str_radix(hex.get(i * 2..i * 2 + 2)?, 16).ok()).collect();
        Some(Known { addr: bytes.try_into().ok()?, kind, name, profile })
    }).collect()))
}

impl Remote {
    /// `band` is excluded when existing pairings are adopted as hosts.
    pub fn new(nvs: EspNvs<NvsDefault>, band: Option<BLEAddress>) -> anyhow::Result<Self> {
        let device = BLEDevice::take();
        let server = device.get_server();
        // Advertising is managed by `keep_discoverable` (several hosts at once).
        server.advertise_on_disconnect(false);
        let mut hid = BLEHIDDevice::new(server);
        // Report characteristics in the order earlier firmware created them, so an existing
        // phone pairing keeps its handles; keyboard and mouse come after.
        let consumer = hid.input_report(CONSUMER_ID);
        let telephony = hid.input_report(TELEPHONY_ID);
        let keyboard = hid.input_report(KEYBOARD_ID);
        let mouse = hid.input_report(MOUSE_ID);
        hid.manufacturer("Neural Playground");
        hid.pnp(0x02, 0x16C0, 0x27DE, 0x0600);
        hid.hid_info(0x00, 0x01);
        let phone_map = [CONSUMER_COLLECTION, TELEPHONY_COLLECTION, MOUSE_COLLECTION].concat();
        let computer_map = [KEYBOARD_COLLECTION, MOUSE_COLLECTION, CONSUMER_COLLECTION, TELEPHONY_COLLECTION].concat();
        hid.report_map(&phone_map);
        // Hosts show this as NP Band Remote's battery: the band's last reading (0 until the first one).
        let battery_level = nvs.get_u8("bat").ok().flatten().unwrap_or(0);
        hid.set_battery_level(battery_level);
        let battery_service = esp_idf_svc::hal::task::block_on(server.get_service(BleUuid::Uuid16(0x180F))).cloned().expect("battery service");
        let battery = block_on_characteristic(&battery_service, BleUuid::Uuid16(0x2A19));

        let (known, adopt, unreadable) = match load_known(&nvs) {
            Ok(Some(known)) => (known, false, false),
            Err(error) => {
                warn!("HOSTS: the saved hosts can't be read ({error}); nothing is saved over them until the dongle restarts and reads them");
                (Vec::new(), false, true)
            }
            Ok(None) => {
                // First boot with host management: the pairings that already exist are trusted (as phones).
                let adopted: Vec<Known> = device.bonded_addresses().unwrap_or_default().into_iter()
                    .filter(|address| Some(*address) != band)
                    .map(|address| Known { addr: address.as_le_bytes(), kind: Kind::Phone, name: "Phone".into(), profile: String::new() })
                    .collect();
                info!("HOSTS: adopted {} existing pairing(s) as phones", adopted.len());
                (adopted, true, false)
            }
        };
        let mut preferred_bytes = [0u8; 6];
        let preferred = nvs.get_blob("active", &mut preferred_bytes).ok().flatten().and_then(|bytes| bytes.try_into().ok());
        // Before 0.11 one mode (0 media, 1 slides, 2 or 4 write, 3 copilot) applied to every computer.
        let legacy_mode = nvs.get_u8("mode").ok().flatten()
            .map(|code| match code { 1 => "slides", 2 | 4 => "write", 3 => "copilot", _ => "media" });
        let mut mouse_bytes = [0u8; 2];
        let mouse_settings = match nvs.get_blob("mouse", &mut mouse_bytes).ok().flatten() {
            Some(&[speed, flags]) => MouseSettings { speed: speed.clamp(1, 10), flip_x: flags & 1 != 0, flip_y: flags & 2 != 0, typing: flags & 4 == 0 },
            _ => MouseSettings::default(),
        };
        let remote = Remote(Arc::new(Inner {
            keyboard, consumer, telephony, battery, mouse, mouse_settings: std::sync::Mutex::new(mouse_settings),
            // Plugging the dongle in (into the laptop, usually) opens a window for pairing a computer.
            state: std::sync::Mutex::new(State {
                hosts: Vec::new(), known, active: None, preferred, legacy_mode,
                pairing: Some((Kind::Mac, Instant::now())), switched: None, profile_switched: None, patterns: Default::default(), alerts: Default::default(), generation: 0, held: None,
                unreadable,
            }),
            nvs: std::sync::Mutex::new(nvs),
            keys: std::sync::Mutex::new(()),
            saving: std::sync::Mutex::new(()),
        }));
        if adopt { remote.save_known(); }

        let map_owner = remote.clone();
        let report_map = block_on_characteristic(hid.hid_service(), BleUuid::Uuid16(0x2a4b));
        report_map.lock().on_read(move |characteristic, desc| {
            let computer = map_owner.kind_of(desc.conn_handle()).is_some_and(Kind::keyboard);
            characteristic.set_value(if computer { &computer_map } else { &phone_map });
        });

        let on_connect = remote.clone();
        server.on_connect(move |_, desc| on_connect.connected(desc));
        let on_disconnect = remote.clone();
        server.on_disconnect(move |desc, reason| on_disconnect.disconnected(desc, reason));
        let on_auth = remote.clone();
        server.on_authentication_complete(move |server, desc, result| on_auth.authenticated(server, desc, result));

        let _ = hid;
        Ok(remote)
    }

    /// Starts advertising, with `control` (the private control service, CONTROL.md) in the scan
    /// response so the app finds it. Every service must exist by now: the GATT table is built here.
    pub fn advertise(&self, control: BleUuid) -> anyhow::Result<()> {
        let device = BLEDevice::take();
        let advertising = device.get_advertising();
        advertising.lock().scan_response(true).set_data(
            BLEAdvertisementData::new()
                .name("NP Band Remote")
                .appearance(0x03C0) // generic HID
                .add_service_uuid(BleUuid::Uuid16(0x1812)),
        )?;
        let BleUuid::Uuid128(bytes) = control else { anyhow::bail!("the control service needs a 128-bit UUID") };
        let mut response = vec![17u8, 0x07];
        response.extend_from_slice(&bytes);
        advertising.lock().set_raw_scan_response_data(&response)?;
        *ALONE.lock().unwrap() = (Some(Instant::now()), true);
        advertising.lock().min_interval(FAST_INTERVAL.0).max_interval(FAST_INTERVAL.1);
        advertising.lock().start()?;
        info!("HOST side: advertising \"NP Band Remote\" (phones: media keys, voice, phone mute and mouse; computers: also a keyboard)");
        Ok(())
    }

    fn kind_of(&self, handle: u16) -> Option<Kind> {
        self.0.state.lock().unwrap().hosts.iter().find(|host| host.handle == handle).map(|host| host.kind)
    }

    fn connected(&self, desc: &BLEConnDesc) {
        let mut state = self.0.state.lock().unwrap();
        // Bonded hosts connect with their identity resolved, so a known computer reads the computer map.
        let addr = desc.id_address().as_le_bytes();
        let (kind, name) = match state.known_index(addr) {
            Some(index) => (state.known[index].kind, state.known[index].name.clone()),
            None => {
                let kind = state.window().unwrap_or(Kind::Phone);
                (kind, format!("New {}", kind.name()))
            }
        };
        info!("HOST: {} connected ({:?}, handle {})", name, desc.address(), desc.conn_handle());
        state.hosts.retain(|host| host.handle != desc.conn_handle());
        state.hosts.push(Host { handle: desc.conn_handle(), addr: None, kind, name, ready: false, profile: String::new(), home: None });
    }

    fn disconnected(&self, desc: &BLEConnDesc, reason: Result<(), esp32_nimble::BLEError>) {
        let mut state = self.0.state.lock().unwrap();
        let handle = desc.conn_handle();
        let name = state.hosts.iter().find(|host| host.handle == handle).map(|host| host.name.clone()).unwrap_or_default();
        info!("HOST: {name} disconnected ({reason:?})");
        crate::ancs::forget(handle);
        state.hosts.retain(|host| host.handle != handle);
        if state.held.is_some_and(|(h, ..)| h == handle) { state.held = None; }
        if state.active == Some(handle) {
            state.active = None;
            state.generation += 1;
            let preferred = state.preferred;
            if let Some(next) = state.hosts.iter().find(|host| host.ready).map(|host| host.handle) {
                state.activate(next);
                // Keep the old preference: when that host comes back, gestures return to it.
                state.preferred = preferred;
            }
        }
    }

    fn authenticated(&self, server: &mut esp32_nimble::BLEServer, desc: &BLEConnDesc, result: Result<(), esp32_nimble::BLEError>) {
        let mut rssi = 0i8;
        let rssi = (unsafe { esp_idf_svc::sys::ble_gap_conn_rssi(desc.conn_handle(), &mut rssi) } == 0).then_some(rssi);
        info!("HOST: pairing {result:?} (bonded {}, encrypted {}, rssi {})", desc.bonded(), desc.encrypted(),
              rssi.map_or("?".into(), |rssi| format!("{rssi} dBm")));
        if result.is_err() || !desc.encrypted() { return; }
        let addr = desc.id_address().as_le_bytes();
        let handle = desc.conn_handle();
        let mut state = self.0.state.lock().unwrap();
        let window = state.window();
        let known = state.known_index(addr);
        let (kind, name) = match known {
            Some(index) => (state.known[index].kind, state.known[index].name.clone()),
            // Bonded, but the list that knew it couldn't be read: keep it (as a phone unless a
            // window says otherwise) for now, unsaved.
            None if state.unreadable && desc.bonded() => {
                let kind = window.unwrap_or(Kind::Phone);
                warn!("HOSTS: {} is bonded but the saved hosts can't be read; keeping it as a {} for now", addr_hex(addr), kind.word());
                (kind, kind.label().to_string())
            }
            None if window.is_some() || state.known.is_empty() => {
                let kind = window.unwrap_or(Kind::Phone);
                let count = state.known.iter().filter(|known| known.kind == kind).count();
                let name = if count == 0 { kind.label().to_string() } else { format!("{} {}", kind.label(), count + 1) };
                state.known.push(Known { addr, kind, name: name.clone(), profile: String::new() });
                state.pairing = None;
                info!("HOSTS: paired {} as a {} ({})", name, kind.word(), addr_hex(addr));
                (kind, name)
            }
            None => {
                warn!("HOSTS: {} tried to pair while pairing is closed; refusing it (open a window: the app, `pair computer`, or hold BOOT 2 s)", addr_hex(addr));
                drop(state);
                let _ = server.disconnect(handle);
                let _ = BLEDevice::take().delete_bond(&BLEAddress::from_le_bytes(addr, desc.id_address().addr_type()));
                return;
            }
        };
        let set = profiles::current();
        let profile = set.profiles[state.profile_for(&set, Some(addr), kind)].id.clone();
        if let Some(host) = state.hosts.iter_mut().find(|host| host.handle == handle) {
            host.addr = Some(addr);
            host.kind = kind;
            host.name = name;
            host.ready = true;
            host.profile = profile;
        }
        // A device that just paired gets the gestures: that's what you're setting up.
        if state.active.is_none() || state.preferred == Some(addr) || known.is_none() {
            state.activate(handle);
        }
        drop(state);
        if kind.computer() || kind == Kind::Phone { request_fast_link(handle); }
        if kind == Kind::Phone { crate::ancs::watch(handle); }
        if known.is_none() { self.save_known(); }
        self.save_preferred();
    }

    fn save_known(&self) {
        let _saving = self.0.saving.lock().unwrap();
        let state = self.0.state.lock().unwrap();
        if state.unreadable { return warn!("HOSTS: not saving: the saved hosts couldn't be read"); }
        let text: String = state.known.iter()
            .map(|known| format!("{}|{}|{}|{}\n", known.addr.iter().map(|b| format!("{b:02x}")).collect::<String>(), known.kind.code(),
                                 known.name.replace(['|', '\n'], " "), known.profile))
            .collect();
        drop(state);
        if let Err(error) = self.0.nvs.lock().unwrap().set_str("hosts", &text) { warn!("HOSTS: couldn't save: {error}"); }
    }

    fn save_preferred(&self) {
        let preferred = self.0.state.lock().unwrap().preferred;
        if let Some(addr) = preferred { let _ = self.0.nvs.lock().unwrap().set_blob("active", &addr); }
    }

    /// NimBLE stops advertising when a host connects; keep it on while there's room for another
    /// host, so the laptop and the phone can both (re)connect. Call every couple of seconds.
    /// Stops advertising while the band's link is made (a fraction of a second), then restarts it.
    pub fn hold_advertising(&self, hold: bool) {
        HELD.store(hold, std::sync::atomic::Ordering::SeqCst);
        if hold {
            let advertising = BLEDevice::take().get_advertising();
            let advertising = advertising.lock();
            if advertising.is_advertising() { let _ = advertising.stop(); }
        } else {
            self.keep_discoverable();
        }
    }

    /// macOS sets its own link parameters after connecting (a 15 ms interval, but skipping up to
    /// 22 events: a third of a second before a mouse move may go). Asks again, every 20 s at
    /// most, while a computer's or phone's link isn't 15 ms with no skipping. Call every couple of seconds.
    pub fn tune_links(&self) {
        let computers: Vec<u16> = {
            let state = self.0.state.lock().unwrap();
            state.hosts.iter().filter(|host| host.ready && (host.kind.computer() || host.kind == Kind::Phone)).map(|host| host.handle).collect()
        };
        let mut asked = LINK_ASKED.lock().unwrap();
        asked.retain(|(handle, _)| computers.contains(handle));
        for handle in computers {
            let mut desc = esp_idf_svc::sys::ble_gap_conn_desc::default();
            if unsafe { esp_idf_svc::sys::ble_gap_conn_find(handle, &mut desc) } != 0 { continue; }
            if desc.conn_latency == 0 && desc.conn_itvl <= 12 { continue; }
            if asked.iter().any(|(h, at)| *h == handle && at.elapsed() < Duration::from_secs(20)) { continue; }
            info!("HOST: host {handle}'s link is {:.2} ms skipping up to {}: asking for 15 ms, none skipped",
                  desc.conn_itvl as f32 * 1.25, desc.conn_latency);
            asked.retain(|(h, _)| *h != handle);
            asked.push((handle, Instant::now()));
            request_fast_link(handle);
        }
    }

    pub fn keep_discoverable(&self) {
        if HELD.load(std::sync::atomic::Ordering::SeqCst) { return; }
        let server = BLEDevice::take().get_server();
        let connected = server.connected_count();
        let fast = {
            let mut alone = ALONE.lock().unwrap();
            alone.0 = if connected > 0 { None } else { alone.0.or_else(|| Some(Instant::now())) };
            let fast = alone.0.is_some_and(|since| since.elapsed() < FAST_ADVERTISING);
            let changed = fast != alone.1;
            alone.1 = fast;
            changed.then_some(fast)
        };
        if connected >= MAX_HOSTS { return; }
        let advertising = BLEDevice::take().get_advertising();
        let mut advertising = advertising.lock();
        // (again under the lock: `hold_advertising` may have stopped it meanwhile)
        if HELD.load(std::sync::atomic::Ordering::SeqCst) { return; }
        if let Some(fast) = fast {
            let (min, max) = if fast { FAST_INTERVAL } else { SLOW_INTERVAL };
            if advertising.is_advertising() { let _ = advertising.stop(); }
            advertising.min_interval(min).max_interval(max);
        }
        if !advertising.is_advertising() {
            if let Err(error) = advertising.start() { warn!("HOST side: couldn't restart advertising: {error:?}") }
        }
    }

    /// The active host's profile set, profile (an index into it) and kind.
    pub fn active_profile(&self) -> Option<(Arc<ProfileSet>, usize, Kind)> {
        let set = profiles::current();
        let state = self.0.state.lock().unwrap();
        let host = state.active.and_then(|active| state.hosts.iter().find(|host| host.handle == active))?;
        let index = state.effective(&set, host);
        Some((set, index, host.kind))
    }

    /// Changes whenever the active host or its profile does.
    pub fn generation(&self) -> u32 { self.0.state.lock().unwrap().generation }

    /// Switches a host's profile (`None`: the active host's). It must allow that kind of host.
    pub fn set_profile(&self, handle: Option<u16>, target: ProfileTarget) -> Result<(), String> {
        self.switch_profile(handle, |_| Ok(target))
    }

    /// The target is worked out against the same set it's applied to.
    fn switch_profile(&self, handle: Option<u16>, target: impl FnOnce(&ProfileSet) -> Result<ProfileTarget, String>) -> Result<(), String> {
        let set = profiles::current();
        let target = target(&set)?;
        let mut state = self.0.state.lock().unwrap();
        let Some(handle) = handle.or(state.active) else { return Err("no host to switch".into()) };
        let active = state.active == Some(handle);
        let Some(host) = state.hosts.iter().find(|host| host.handle == handle && host.ready) else { return Err(format!("no connected host {handle}")) };
        let (kind, current) = (host.kind.host_kind(), state.effective(&set, host));
        let index = match target {
            ProfileTarget::Index(index) => index,
            ProfileTarget::Next | ProfileTarget::Previous => set.step(current, target == ProfileTarget::Next, kind)
                .ok_or_else(|| format!("{} has no other profile it can use", host.name))?,
        };
        let profile = set.profiles.get(index).ok_or_else(|| format!("no profile {index}"))?;
        if !profile.allows(kind) { return Err(format!("{} isn't for {} ({})", profile.name, host.name, host.kind.word())); }
        let host = state.hosts.iter_mut().find(|host| host.handle == handle).expect("found above");
        host.profile = profile.id.clone();
        // Chosen by hand: it stays until the next app that a profile lists.
        host.home = None;
        let (addr, name) = (host.addr, host.name.clone());
        if let Some(i) = addr.and_then(|addr| state.known_index(addr)) { state.known[i].profile = profile.id.clone(); }
        if active { state.profile_switched = Some(profile.buzz.clone()); }
        state.generation += 1;
        drop(state);
        self.save_known();
        info!("PROFILE: {name} is in {} ({})", profile.name, profile.id);
        Ok(())
    }

    pub fn set_profile_id(&self, handle: Option<u16>, id: &str) -> Result<(), String> {
        self.switch_profile(handle, |set| set.index_of(id).map(ProfileTarget::Index).ok_or_else(|| format!("no profile \"{id}\"")))
    }

    /// The app in front on host `handle` changed (its helper says so, by bundle id): switch to the
    /// profile that lists it, or back to the one the host had before, for an app none lists.
    pub fn app_changed(&self, handle: u16, app: &str) -> Result<(), String> {
        let set = profiles::current();
        let mut state = self.0.state.lock().unwrap();
        let Some(position) = state.hosts.iter().position(|host| host.handle == handle && host.ready) else { return Err(format!("no connected host {handle}")) };
        let current = state.effective(&set, &state.hosts[position]);
        let host = &mut state.hosts[position];
        let target = match set.for_app(app, host.kind.host_kind()) {
            Some(index) => {
                host.home.get_or_insert_with(|| set.profiles[current].id.clone());
                index
            }
            None => match host.home.take().and_then(|id| set.index_of(&id)) {
                Some(index) => index,
                None => return Ok(()),
            },
        };
        if target == current { return Ok(()); }
        let profile = &set.profiles[target];
        host.profile = profile.id.clone();
        let name = host.name.clone();
        // No buzz: it follows every app switch, and you can see which app you're in.
        state.generation += 1;
        drop(state);
        info!("PROFILE: {name} is in {} ({}) for {app}", profile.name, profile.id);
        Ok(())
    }

    pub fn take_profile_switched(&self) -> Option<np_profiles::Pattern> { self.0.state.lock().unwrap().profile_switched.take() }

    /// The band plays this pattern (`Controller::poll`).
    pub fn play(&self, pattern: np_profiles::Pattern) {
        let mut state = self.0.state.lock().unwrap();
        if state.patterns.len() < 4 { state.patterns.push_back(pattern); }
    }

    pub fn take_play(&self) -> Option<np_profiles::Pattern> { self.0.state.lock().unwrap().patterns.pop_front() }

    /// A new profile set: every host goes back to the profile it chose, if the set still has it.
    pub fn profiles_changed(&self) {
        let set = profiles::current();
        let mut state = self.0.state.lock().unwrap();
        let picks: Vec<String> = state.hosts.iter().map(|host| set.profiles[state.effective(&set, host)].id.clone()).collect();
        for (host, profile) in state.hosts.iter_mut().zip(picks) { host.profile = profile; }
        state.generation += 1;
    }

    /// The first connected host of a kind gets the gestures.
    pub fn target_kind(&self, hosts: Hosts) -> bool {
        let handle = {
            let state = self.0.state.lock().unwrap();
            state.hosts.iter().find(|host| host.ready && hosts.matches(host.kind.host_kind())).map(|host| host.handle)
        };
        handle.is_some_and(|handle| self.target(Some(handle)))
    }

    /// Activates host `handle`, or the next connected one after the active host (`None`).
    pub fn target(&self, handle: Option<u16>) -> bool {
        match handle {
            Some(handle) => self.retarget(|ready, _| ready.contains(&handle).then_some(handle)),
            None => self.step(true),
        }
    }

    /// The next (or previous) connected host, in connection order, wrapping around.
    pub fn step(&self, forward: bool) -> bool {
        self.retarget(|ready, active| {
            let position = active.and_then(|active| ready.iter().position(|&h| h == active));
            let len = ready.len();
            match position {
                Some(i) => ready.get(if forward { (i + 1) % len } else { (i + len - 1) % len }).copied(),
                None => ready.first().copied(),
            }
        })
    }

    fn retarget(&self, choose: impl FnOnce(&[u16], Option<u16>) -> Option<u16>) -> bool {
        let mut state = self.0.state.lock().unwrap();
        let ready: Vec<u16> = state.hosts.iter().filter(|host| host.ready).map(|host| host.handle).collect();
        let next = choose(&ready, state.active);
        let Some(next) = next else { return false };
        if state.active == Some(next) {
            // Re-targeting the active host still buzzes, so "where are my keys going?" has an answer.
            state.switched = state.hosts.iter().find(|host| host.handle == next).map(|host| host.kind);
            return true;
        }
        state.activate(next);
        drop(state);
        self.save_preferred();
        true
    }

    /// The band buzzes `alert`'s pattern (`Controller::poll`).
    pub fn alert(&self, alert: Alert) {
        let mut state = self.0.state.lock().unwrap();
        if state.alerts.len() < 4 { state.alerts.push_back(alert); }
        drop(state);
        info!("ALERT: {alert:?}");
    }

    pub fn take_alert(&self) -> Option<Alert> { self.0.state.lock().unwrap().alerts.pop_front() }

    pub fn take_switched(&self) -> Option<Kind> { self.0.state.lock().unwrap().switched.take() }

    pub fn open_pairing(&self, kind: Option<Kind>) {
        let mut state = self.0.state.lock().unwrap();
        state.pairing = kind.map(|kind| (kind, Instant::now()));
        match kind {
            Some(kind) => info!("PAIRING: open for 120 s; the next new device pairs as a {}", kind.word()),
            None => info!("PAIRING: closed"),
        }
    }

    pub fn pairing_seconds(&self) -> u64 {
        let mut state = self.0.state.lock().unwrap();
        match (state.window(), state.pairing) {
            (Some(_), Some((_, opened))) => PAIRING_WINDOW.saturating_sub(opened.elapsed()).as_secs(),
            _ => 0,
        }
    }

    /// The host behind `handle` names itself (the app's `hello`); it is a phone.
    pub fn hello(&self, handle: u16, name: &str) {
        let name: String = name.chars().filter(|c| !c.is_control() && *c != '|').take(24).collect();
        let mut state = self.0.state.lock().unwrap();
        let Some(host) = state.hosts.iter_mut().find(|host| host.handle == handle) else { return };
        host.name = name.clone();
        let addr = host.addr;
        if let Some(index) = addr.and_then(|addr| state.known_index(addr)) {
            state.known[index].name = name;
        }
        drop(state);
        self.save_known();
    }

    pub fn rename(&self, handle: u16, name: &str) { self.hello(handle, name) }

    /// Says what a connected host is. Only between kinds with the same report map (any but a
    /// phone): a host caches its map when it pairs, so phone ↔ the rest needs pairing again.
    pub fn set_kind(&self, handle: u16, kind: Kind) -> Result<(), String> {
        let mut state = self.0.state.lock().unwrap();
        let Some(host) = state.hosts.iter_mut().find(|host| host.handle == handle) else { return Err(format!("no connected host {handle}")) };
        if host.kind.keyboard() != kind.keyboard() {
            return Err(format!("{} can't become a {} without pairing again: forget it, open a {} pairing window and connect it again",
                               host.name, kind.word(), kind.word()));
        }
        host.kind = kind;
        let (addr, name) = (host.addr, host.name.clone());
        if let Some(index) = addr.and_then(|addr| state.known_index(addr)) { state.known[index].kind = kind; }
        // A TV can't stay in, say, write mode.
        let set = profiles::current();
        let profile = state.hosts.iter().find(|host| host.handle == handle).map(|host| set.profiles[state.effective(&set, host)].id.clone());
        if let Some(host) = state.hosts.iter_mut().find(|host| host.handle == handle) { host.profile = profile.unwrap_or_default(); }
        state.generation += 1;
        if state.active == Some(handle) { state.switched = Some(kind); }
        drop(state);
        self.save_known();
        info!("HOSTS: {name} is a {}", kind.word());
        Ok(())
    }

    pub fn forget(&self, handle: u16) -> bool {
        let mut state = self.0.state.lock().unwrap();
        let Some(host) = state.hosts.iter().find(|host| host.handle == handle) else { return false };
        let addr = host.addr;
        let name = host.name.clone();
        if let Some(addr) = addr { state.known.retain(|known| known.addr != addr); }
        drop(state);
        self.save_known();
        info!("HOSTS: forgetting {name}");
        let device = BLEDevice::take();
        let _ = device.get_server().disconnect(handle);
        if let Some(addr) = addr {
            for kind in [BLEAddressType::Public, BLEAddressType::Random] {
                let _ = device.delete_bond(&BLEAddress::from_le_bytes(addr, kind));
            }
        }
        true
    }

    /// The band's battery reading, shown by every host as this device's battery. It isn't a
    /// gesture, so all subscribed hosts get it. Saved so a reboot doesn't show a made-up level.
    pub fn set_battery(&self, level: u8) {
        let level = level.min(100);
        let mut battery = self.0.battery.lock();
        if battery.value_mut().as_slice() == [level] { return; }
        battery.set_value(&[level]).notify();
        drop(battery);
        let _ = self.0.nvs.lock().unwrap().set_u8("bat", level);
    }

    /// Hosts for the status JSON: (handle, kind, name, active, profile id).
    pub fn hosts(&self) -> Vec<(u16, Kind, String, bool, String)> {
        let set = profiles::current();
        let state = self.0.state.lock().unwrap();
        state.hosts.iter().map(|host| (host.handle, host.kind, host.name.clone(), state.active == Some(host.handle),
                                       set.profiles[state.effective(&set, host)].id.clone())).collect()
    }

    /// Types text on the active host (US layout), one key at a time.
    pub fn type_text(&self, text: &str) {
        for c in text.chars() {
            if let Some((modifiers, usage)) = keys::for_char(c) { self.send(Action::Key { modifiers, usage }); }
        }
    }

    /// Presses a chord and keeps it down (push-to-talk) on the active computer. Returns the host it
    /// went to, for [`Self::release`]: the release must reach the same host even after a switch.
    pub fn hold(&self, modifiers: u8, usage: u8) -> Option<u16> {
        let _keys = self.0.keys.lock().unwrap();
        let (handle, name, kind) = {
            let state = self.0.state.lock().unwrap();
            let host = state.active.and_then(|active| state.hosts.iter().find(|host| host.handle == active))?;
            if !host.kind.keyboard() { return None; }
            (host.handle, host.name.clone(), host.kind)
        };
        let modifiers = kind.modifiers(modifiers);
        let sent = self.0.keyboard.lock().notify_with(&[modifiers, 0, usage, 0, 0, 0, 0, 0], handle);
        info!("HOLD {modifiers:#04x}+{usage:#04x} on {name}: {sent:?}");
        if sent.is_ok() { self.0.state.lock().unwrap().held = Some((handle, modifiers, usage)); }
        sent.ok().map(|_| handle)
    }

    /// One mouse report to the active host (every host's map has the mouse since 0.16): buttons
    /// held, a move and a wheel step. No release: the next report says what's held. Logged only when it fails.
    pub fn mouse(&self, buttons: u8, dx: i8, dy: i8, wheel: i8) -> bool {
        let handle = {
            let state = self.0.state.lock().unwrap();
            let Some(host) = state.active.and_then(|active| state.hosts.iter().find(|host| host.handle == active)) else { return false };
            host.handle
        };
        let sent = self.0.mouse.lock().notify_with(&[buttons, dx as u8, dy as u8, wheel as u8], handle);
        if let Err(error) = &sent { warn!("mouse report to host {handle} failed: {error:?}"); }
        sent.is_ok()
    }

    /// A click of `button`: down, then up.
    pub fn click(&self, button: u8) {
        if self.mouse(button, 0, 0, 0) {
            esp_idf_svc::hal::delay::FreeRtos::delay_ms(15);
            self.mouse(0, 0, 0, 0);
            info!("CLICK {button}");
        }
    }

    pub fn mouse_settings(&self) -> MouseSettings { *self.0.mouse_settings.lock().unwrap() }

    /// The dongle's NVS namespace (the profile set is kept there too).
    pub fn nvs(&self) -> &std::sync::Mutex<EspNvs<NvsDefault>> { &self.0.nvs }

    pub fn set_mouse_settings(&self, settings: MouseSettings) {
        let settings = MouseSettings { speed: settings.speed.clamp(1, 10), ..settings };
        *self.0.mouse_settings.lock().unwrap() = settings;
        let flags = u8::from(settings.flip_x) | u8::from(settings.flip_y) << 1 | u8::from(!settings.typing) << 2;
        let _ = self.0.nvs.lock().unwrap().set_blob("mouse", &[settings.speed, flags]);
        info!("MOUSE: speed {}, flip x {}, flip y {}, typing {}", settings.speed, settings.flip_x, settings.flip_y, settings.typing);
    }

    /// Lets go of every key held on `handle`.
    pub fn release(&self, handle: u16) {
        let _keys = self.0.keys.lock().unwrap();
        {
            let mut state = self.0.state.lock().unwrap();
            if state.held.is_some_and(|(h, ..)| h == handle) { state.held = None; }
        }
        let sent = self.0.keyboard.lock().notify_with(&[0; 8], handle);
        info!("RELEASE on host {handle}: {sent:?}");
    }

    pub fn send(&self, action: Action) {
        let _keys = self.0.keys.lock().unwrap();
        let (handle, kind, name, held) = {
            let state = self.0.state.lock().unwrap();
            let host = state.active.and_then(|active| state.hosts.iter().find(|host| host.handle == active));
            match host {
                Some(host) => (host.handle, host.kind, host.name.clone(), state.held.filter(|(h, ..)| *h == host.handle)),
                None => { info!("{action:?} (no host connected)"); return; }
            }
        };
        let (characteristic, press, release): (&Arc<Mutex<BLECharacteristic>>, Vec<u8>, Vec<u8>) = match action {
            Action::Media(key) => (&self.0.consumer, vec![1u8 << (key as u8)], vec![0]),
            Action::PhoneMute => (&self.0.telephony, vec![1], vec![0]),
            Action::Key { modifiers, usage } => {
                if !kind.keyboard() {
                    info!("{action:?} skipped: {name} is a phone (no keyboard)");
                    return;
                }
                // A report is every key down at once: a held chord (push-to-talk) stays down
                // through the key, its modifiers with it.
                match held {
                    Some((_, held_mods, held_usage)) => (&self.0.keyboard, vec![held_mods | kind.modifiers(modifiers), 0, held_usage, usage, 0, 0, 0, 0],
                                                         vec![held_mods, 0, held_usage, 0, 0, 0, 0, 0]),
                    None => (&self.0.keyboard, vec![kind.modifiers(modifiers), 0, usage, 0, 0, 0, 0, 0], vec![0; 8]),
                }
            }
        };
        let sent = characteristic.lock().notify_with(&press, handle);
        esp_idf_svc::hal::delay::FreeRtos::delay_ms(15);
        let _ = characteristic.lock().notify_with(&release, handle);
        match sent {
            Ok(()) => info!("{action:?} sent to {name}"),
            Err(error) => warn!("{action:?} to {name} failed: {error:?} (not subscribed: re-pair it if this persists)"),
        }
    }
}

/// `BLEService::get_characteristic` is async but never waits.
fn block_on_characteristic(service: &Arc<Mutex<esp32_nimble::BLEService>>, uuid: BleUuid) -> Arc<Mutex<BLECharacteristic>> {
    esp_idf_svc::hal::task::block_on(async { service.lock().get_characteristic(uuid).await.cloned() }).expect("GATT characteristic")
}
