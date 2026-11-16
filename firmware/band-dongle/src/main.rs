//! band-dongle: the Meta Neural Band without a phone.
//!
//! Connects to the bonded band, runs band-core's encrypted session with the owner key, and turns
//! gestures into input for one active host at a time (remote.rs): media keys, Apple's microphone
//! key and a headset's phone-mute button on a phone; on a computer also slide and Teams shortcuts.
//! The Neural Playground app manages it over a private control service (control.rs, CONTROL.md),
//! including signed over-the-air firmware updates (ota.rs).
//!
//! The owner key is provisioned over serial (`OWNER <base64>`), stored in NVS, never compiled in
//! and never logged; only its public fingerprint is printed.

mod ancs;
mod cardputer;
mod coc;
mod control;
mod controller;
mod memory;
mod ota;
mod profiles;
mod remote;

use std::io::BufRead;
use std::time::{Duration, Instant};

use band_core::events::Event;
use band_core::identity::EnrollmentIdentity;
use band_core::responder::{Responder, SimMode};
use band_core::session::BandSession;
use controller::Controller;
use remote::Remote;
use base64::Engine;
use esp32_nimble::enums::{AuthReq, SecurityIOCap};
use esp32_nimble::utilities::BleUuid;
use esp32_nimble::{uuid128, BLEAddress, BLEAddressType, BLEDevice};
use control::paused;
use esp_idf_svc::hal::task::block_on;
use esp_idf_svc::nvs::{EspDefaultNvsPartition, EspNvs, NvsDefault};
use log::{error, info, warn};
use sha2::{Digest, Sha256};

/// NVS key of the band's Bluetooth identity address (6 bytes little-endian, then its type),
/// learned when it connects; until then the dongle finds the band by scanning.
const BAND_KEY: &str = "band";
const BAND_SERVICE: BleUuid = BleUuid::Uuid16(0xFEB8);
/// What updated band firmware advertises (seen in the phone app's scan: "Services FD5F").
const BAND_ADVERTISED: BleUuid = BleUuid::Uuid16(0xFD5F);
const PSM_CHARACTERISTIC: BleUuid = uuid128!("2d41da7c-82b6-42aa-b34e-e2e01df8cc1a");
/// The BOOT button (G0 on the Cardputer, BOOT on a XIAO ESP32-S3): a press releases the band (so
/// the phone app can use it) and another reclaims it; holding it 2 s opens a window for pairing a computer.
const BOOT_BUTTON: i32 = 0;

/// Polled every 30 ms on the esp_timer task, not a thread of its own (3 KB of stack): it only
/// flips `control::PAUSED` or raises `control::BUTTON_HELD`, and the control thread does the rest.
fn watch_boot_button() {
    unsafe {
        let config = esp_idf_svc::sys::gpio_config_t {
            pin_bit_mask: 1u64 << BOOT_BUTTON,
            mode: esp_idf_svc::sys::gpio_mode_t_GPIO_MODE_INPUT,
            pull_up_en: esp_idf_svc::sys::gpio_pullup_t_GPIO_PULLUP_ENABLE,
            pull_down_en: esp_idf_svc::sys::gpio_pulldown_t_GPIO_PULLDOWN_DISABLE,
            intr_type: esp_idf_svc::sys::gpio_int_type_t_GPIO_INTR_DISABLE,
        };
        esp_idf_svc::sys::gpio_config(&config);
    }
    use std::sync::atomic::Ordering::SeqCst;
    let mut pressed: Option<Instant> = None;
    let mut long_handled = false;
    let poll = move || {
        let down = unsafe { esp_idf_svc::sys::gpio_get_level(BOOT_BUTTON) } == 0;
        match (down, pressed) {
            (true, None) => { pressed = Some(Instant::now()); long_handled = false; }
            (true, Some(since)) if !long_handled && since.elapsed() >= Duration::from_secs(2) => {
                long_handled = true;
                control::BUTTON_HELD.store(true, SeqCst);
            }
            (false, Some(_)) => {
                pressed = None;
                if !long_handled {
                    control::PAUSED.fetch_xor(true, SeqCst);
                    control::BUTTON_PRESSED.store(true, SeqCst);
                }
            }
            _ => {}
        }
    };
    let timer = esp_idf_svc::timer::EspTaskTimerService::new().and_then(|service| service.timer(poll))
        .and_then(|timer| timer.every(Duration::from_millis(30)).map(|_| timer));
    match timer {
        Ok(timer) => std::mem::forget(timer),
        Err(error) => warn!("BOOT button: couldn't poll it ({error})"),
    }
}


fn fingerprint(identity: &EnrollmentIdentity) -> String {
    let digest = Sha256::digest(identity.app_point());
    digest[..8].chunks(2).map(|pair| format!("{:02X}{:02X}", pair[0], pair[1])).collect::<Vec<_>>().join("-")
}

/// The self-test, at the main task's priority, half a minute after boot (the control thread starts
/// it): off the path to connecting the band (its key exchanges and signatures take a while), and
/// its stack is taken only while it runs. It used 10.7 KB (0.15.1).
fn spawn_self_test() {
    let spawned = memory::spawn_with(c"self-test", 12 * 1024, Some(1), || {
        if let Err(error) = self_test() { error!("SELF-TEST FAIL: {error}"); }
        info!("self-test: {} B of its stack unused", memory::own_stack_unused());
    });
    if let Err(error) = spawned { warn!("Couldn't start the self-test: {error}"); }
}

/// band-core against its own simulated band (scheme 3, like this band's firmware), on this chip.
fn self_test() -> anyhow::Result<()> {
    let started = Instant::now();
    let owner = EnrollmentIdentity::new(p256::ecdsa::SigningKey::random(&mut rand_core::OsRng), None);
    let mut band = Responder::new(SimMode::Enrolled, p256::ecdsa::SigningKey::random(&mut rand_core::OsRng));
    let mut session = BandSession::new(Some(owner), None, false);
    let mut to_band = session.request()?;
    let mut connected = false;
    let mut time = 0.0;
    for _ in 0..64 {
        let from_band = band.respond(&to_band)?;
        to_band.clear();
        if from_band.is_empty() {
            break;
        }
        time += 0.01;
        let result = session.feed(&from_band, time)?;
        to_band.extend(result.outgoing);
        connected |= result.events.iter().any(|event| matches!(event, Event::Connected));
    }
    anyhow::ensure!(connected, "the simulated session never connected");
    let gesture = band.gesture(3, 2, 1)?; // index tap
    let events = session.feed(&gesture, time + 0.01)?.events;
    let decoded = events.iter().any(|event| matches!(event, Event::Gesture(g) if g.finger == "index"));
    anyhow::ensure!(decoded, "the simulated gesture didn't decode");
    info!("SELF-TEST PASS: band-core handshake + owner trust + gesture on the ESP32 in {} ms", started.elapsed().as_millis());
    Ok(())
}

/// `bench`: the band's hot path on this chip, for comparing builds without a band streaming
/// motion (it doesn't while charging): a simulated band's gyro and orientation packets through
/// `BandSession::feed_into`, alone and with a `Controller`, timing only the dongle's side.
pub fn spawn_bench(remote: Remote) {
    let spawned = memory::spawn_with(c"bench", 12 * 1024, Some(1), move || match bench(&remote) {
        Ok(report) => info!("BENCH: {report}"),
        Err(error) => warn!("BENCH failed: {error}"),
    });
    if let Err(error) = spawned { warn!("Couldn't start the bench: {error}"); }
}

fn bench(remote: &Remote) -> anyhow::Result<String> {
    let owner = EnrollmentIdentity::new(p256::ecdsa::SigningKey::random(&mut rand_core::OsRng), None);
    let mut band = Responder::new(SimMode::Enrolled, p256::ecdsa::SigningKey::random(&mut rand_core::OsRng));
    let mut session = BandSession::new(Some(owner), None, false);
    let mut to_band = session.request()?;
    let mut time = 0.0;
    for _ in 0..64 {
        let from_band = band.respond(&to_band)?;
        to_band.clear();
        if from_band.is_empty() { break; }
        time += 0.01;
        to_band.extend(session.feed(&from_band, time)?.outgoing);
    }
    let mut controller = Controller::new(remote);
    let (mut packets, mut events, mut through, mut alone) = (0u32, 0usize, Duration::ZERO, Duration::ZERO);
    for round in 0..200i16 {
        let mut batch = Vec::with_capacity(20);
        for i in 0..10i16 {
            batch.push(band.gyro3([round % 7 + i, -3, 2])?);
            batch.push(band.orientation([1.0, 0.0, 0.0, 0.0])?);
        }
        // Odd rounds: band-core alone (the events dropped); even: through the controller too.
        let only_core = round % 2 == 1;
        let started = Instant::now();
        for packet in batch.iter().filter(|packet| !packet.is_empty()) {
            time += 0.01;
            session.feed_into(packet, time, &mut |event| { events += 1; if !only_core { controller.event(event, time, None); } })?;
            packets += 1;
        }
        if only_core { alone += started.elapsed(); } else { through += started.elapsed(); }
        // The idle tasks run (the task watchdog watches them).
        std::thread::sleep(Duration::from_millis(2));
    }
    anyhow::ensure!(events > 0, "the simulated band sent no motion");
    let half = packets / 2;
    Ok(format!("{packets} packets, {events} events: {} us a packet through the controller, {} us band-core alone",
               (through / half).as_micros(), (alone / half).as_micros()))
}

fn load_owner(nvs: &EspNvs<NvsDefault>) -> Option<EnrollmentIdentity> {
    let mut buffer = [0u8; 97];
    let bytes = nvs.get_blob("owner", &mut buffer).ok().flatten()?;
    let (private, band) = match bytes.len() {
        32 => (&bytes[..32], None),
        97 => (&bytes[..32], Some(&bytes[32..])),
        _ => return None,
    };
    EnrollmentIdentity::from_bytes(private, band).ok()
}

/// Reads serial lines; `OWNER <base64 key or air-gestures JSON owner_key>` provisions the key.
fn spawn_serial_reader(partition: EspDefaultNvsPartition, remote: Remote) {
    unsafe {
        let mut config = esp_idf_svc::sys::usb_serial_jtag_driver_config_t { tx_buffer_size: 1024, rx_buffer_size: 4096 };
        esp_idf_svc::sys::usb_serial_jtag_driver_install(&mut config);
        esp_idf_svc::sys::esp_vfs_usb_serial_jtag_use_driver();
    }
    // It used 3 KB of 8 (0.15.1), with the commands' own: command threads get 6 KB too. `OWNER`
    // derives its public key on a thread of its own.
    memory::spawn(c"serial", 6144, move || {
            let mut nvs = match EspNvs::new(partition, "np", true) {
                Ok(nvs) => nvs,
                Err(error) => { error!("serial: NVS unavailable: {error}"); return; }
            };
            let stdin = std::io::stdin();
            for line in stdin.lock().lines().map_while(Result::ok) {
                handle_serial(line.trim(), &mut nvs, &remote);
            }
        })
        .expect("serial reader thread");
}

/// `UNPAIR` over serial: forget the Bluetooth pairing with the band (it re-pairs in pairing mode).
static UNPAIR_REQUEST: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn handle_serial(line: &str, nvs: &mut EspNvs<NvsDefault>, remote: &Remote) {
    if let Some(encoded) = line.strip_prefix("OWNER ") {
        match base64::engine::general_purpose::STANDARD.decode(encoded.trim()) {
            Ok(bytes) if bytes.len() == 32 || bytes.len() == 97 => {
                let checked = memory::spawn(c"owner", 12 * 1024, {
                    let bytes = bytes.clone();
                    move || {
                        let band = (bytes.len() == 97).then(|| &bytes[32..]);
                        EnrollmentIdentity::from_bytes(&bytes[..32], band).map(|identity| fingerprint(&identity))
                            .map_err(|error| error.to_string())
                    }
                });
                let checked = checked.map_err(|error| error.to_string()).and_then(|thread| thread.join().map_err(|_| "panicked".to_string()));
                match checked {
                    Ok(Ok(print)) => match nvs.set_blob("owner", &bytes) {
                        Ok(()) => info!("Owner key stored in NVS (fingerprint {print}). Rebooting."),
                        Err(error) => error!("Couldn't store the owner key: {error}"),
                    },
                    Ok(Err(error)) => error!("That isn't a valid owner key: {error}"),
                    Err(error) => error!("Couldn't check the owner key: {error}"),
                }
                std::thread::sleep(Duration::from_millis(300));
                unsafe { esp_idf_svc::sys::esp_restart() };
            }
            Ok(bytes) => error!("Owner key must be 32 or 97 bytes (got {})", bytes.len()),
            Err(_) => error!("Owner key isn't valid base64"),
        }
    } else if line == "PAUSE" || line == "RESUME" {
        control::PAUSED.store(line == "PAUSE", std::sync::atomic::Ordering::SeqCst);
        info!("band link {}", if line == "PAUSE" { "paused" } else { "resumed" });
    } else if line == "FORGET" {
        let _ = nvs.remove("owner");
        let _ = nvs.remove("guess");
        info!("Owner key removed from NVS.");
    } else if line == "UNPAIR" {
        UNPAIR_REQUEST.store(true, std::sync::atomic::Ordering::SeqCst);
    } else if let Some(encoded) = line.strip_prefix("OTA ") {
        control::serial_update(encoded.trim());
    } else if let Some(rest) = line.strip_prefix("IDENTITY").filter(|rest| rest.is_empty() || rest.starts_with(' ')) {
        identity_command(rest.trim(), nvs);
    } else if line == "HELP" {
        info!("Commands: OWNER <base64>, FORGET, PAUSE, RESUME, UNPAIR, IDENTITY [<mac>|clear], and the app's control commands (CONTROL.md: status, target, mode, pair, key, ...)");
    } else if !line.is_empty() {
        control::run(remote, line, None);
    }
}

/// NVS key of the base MAC address this dongle answers to in place of its chip's own (6 bytes),
/// when it took another dongle's place (`IDENTITY`): the band and the paired hosts know a dongle by
/// its Bluetooth address, so with the other's NVS copied over too nothing needs pairing again.
const IDENTITY_KEY: &str = "mac";

fn read_mac(kind: esp_idf_svc::sys::esp_mac_type_t) -> [u8; 6] {
    let mut mac = [0u8; 6];
    unsafe { esp_idf_svc::sys::esp_read_mac(mac.as_mut_ptr(), kind) };
    mac
}

fn mac_text(mac: &[u8; 6]) -> String { mac.iter().map(|b| format!("{b:02X}")).collect::<Vec<_>>().join(":") }

/// Before Bluetooth starts: the saved identity, if there is one.
fn adopt_identity(nvs: &EspNvs<NvsDefault>) {
    let mut mac = [0u8; 6];
    let Ok(Some(saved)) = nvs.get_blob(IDENTITY_KEY, &mut mac) else { return };
    if saved.len() != 6 { return warn!("IDENTITY: the saved one isn't 6 bytes; using the chip's own"); }
    let rc = unsafe { esp_idf_svc::sys::esp_base_mac_addr_set(mac.as_ptr()) };
    if rc == 0 {
        info!("IDENTITY: answering as {} (Bluetooth {}), not this chip's own", mac_text(&mac), mac_text(&read_mac(esp_idf_svc::sys::esp_mac_type_t_ESP_MAC_BT)));
    } else {
        warn!("IDENTITY: couldn't use {} (rc {rc}); using the chip's own", mac_text(&mac));
    }
}

/// `IDENTITY` (show it), `IDENTITY <aa:bb:cc:dd:ee:ff>` (answer as that base MAC from the next
/// boot) or `IDENTITY clear` (the chip's own again). Serial only: it needs the dongle in hand.
fn identity_command(arg: &str, nvs: &mut EspNvs<NvsDefault>) {
    let chip = {
        let mut mac = [0u8; 6];
        unsafe { esp_idf_svc::sys::esp_efuse_mac_get_default(mac.as_mut_ptr()) };
        mac
    };
    if arg.is_empty() {
        return info!("IDENTITY: base {} (the chip's own is {}), Bluetooth {}", mac_text(&read_mac(esp_idf_svc::sys::esp_mac_type_t_ESP_MAC_BASE)),
                     mac_text(&chip), mac_text(&read_mac(esp_idf_svc::sys::esp_mac_type_t_ESP_MAC_BT)));
    }
    let result = if arg == "clear" {
        nvs.remove(IDENTITY_KEY).map(|_| ())
    } else {
        let bytes: Vec<u8> = arg.split([':', '-']).filter_map(|part| u8::from_str_radix(part, 16).ok()).collect();
        let Ok(mac) = <[u8; 6]>::try_from(bytes) else { return error!("IDENTITY: a MAC is six hex bytes, like 24:EC:4A:00:4F:54") };
        if mac[0] & 1 != 0 { return error!("IDENTITY: {} is a multicast address", mac_text(&mac)); }
        nvs.set_blob(IDENTITY_KEY, &mac)
    };
    match result {
        Ok(()) => info!("IDENTITY: {} from the next boot. Rebooting.", if arg == "clear" { "the chip's own".to_string() } else { arg.to_uppercase() }),
        Err(error) => return error!("IDENTITY: couldn't save it: {error}"),
    }
    std::thread::sleep(Duration::from_millis(300));
    unsafe { esp_idf_svc::sys::esp_restart() };
}

/// How a session went, for choosing the next scheme-26 guess.
#[derive(Default)]
struct Outcome {
    /// The band offered scheme 26 and nothing it sent authenticated under this guess.
    wrong_guess: bool,
    /// The band's identity address, once the link was encrypted.
    band: Option<BLEAddress>,
    /// The session got as far as streaming.
    live: bool,
}

fn saved_band(nvs: &EspNvs<NvsDefault>) -> Option<BLEAddress> {
    let mut bytes = [0u8; 7];
    let blob = nvs.get_blob(BAND_KEY, &mut bytes).ok().flatten()?;
    let (address, kind) = (blob.get(..6)?.try_into().ok()?, blob.get(6).copied()?);
    let kind = if kind == BLEAddressType::Random as u8 { BLEAddressType::Random } else { BLEAddressType::Public };
    Some(BLEAddress::from_le_bytes(address, kind))
}

fn save_band(nvs: &EspNvs<NvsDefault>, address: BLEAddress) {
    let mut bytes = [0u8; 7];
    bytes[..6].copy_from_slice(&address.as_le_bytes());
    bytes[6] = address.addr_type() as u8;
    match nvs.set_blob(BAND_KEY, &bytes) {
        Ok(_) => info!("Saved the band's address {address}"),
        Err(error) => warn!("Couldn't save the band's address: {error}"),
    }
}

/// Dongles from before the address was learned: the one pairing that isn't a known host is the band.
fn adopt_band(nvs: &EspNvs<NvsDefault>, device: &BLEDevice) -> Option<BLEAddress> {
    let hosts = remote::known_addresses(nvs);
    let mut others = device.bonded_addresses().unwrap_or_default().into_iter()
        .filter(|address| !hosts.contains(&address.as_le_bytes()));
    let band = others.next()?;
    if others.next().is_some() { return None; }
    save_band(nvs, band);
    Some(band)
}

/// Waits for the band to advertise, scanning continuously (the dongle runs on USB power, so the
/// band's first advertisement is enough). It advertises FD5F on updated firmware (FEB8, which
/// holds the L2CAP PSM, only after connecting) under a name like "Meta Band 00B2"; in pairing
/// mode, and after a firmware update, from an address other than its saved identity, which is why
/// this scans rather than connecting to the saved address. Returns None when the band is released
/// or its pairing is to be forgotten.
async fn find_band(saved: Option<BLEAddress>) -> Option<BLEAddress> {
    let device = BLEDevice::take();
    let mut scan = esp32_nimble::BLEScan::new();
    scan.active_scan(true).interval(30).window(30).filter_duplicates(true);
    let mut waiting_logged = false;
    loop {
        if paused() || UNPAIR_REQUEST.load(std::sync::atomic::Ordering::SeqCst) { return None; }
        let found = scan
            .start(device, 5000, |advertiser, data| {
                let named = data.name().is_some_and(|name| name.starts_with(b"Meta Band"));
                let ours = saved.is_some_and(|saved| advertiser.addr() == saved);
                (ours || named || data.is_advertising_service(&BAND_ADVERTISED) || data.is_advertising_service(&BAND_SERVICE)).then(|| {
                    info!("SCAN: band from {} (rssi {}, name {:?})", advertiser.addr(), advertiser.rssi(), data.name());
                    advertiser.addr()
                })
            })
            .await;
        match found {
            Ok(Some(address)) => return Some(address),
            Ok(None) if !waiting_logged => {
                info!("SCAN: waiting for the band to advertise (off, connected elsewhere, or out of range)");
                waiting_logged = true;
            }
            Ok(None) => {}
            Err(error) => {
                warn!("SCAN failed: {error:?}");
                embassy_time::Timer::after(embassy_time::Duration::from_millis(500)).await;
            }
        }
    }
}

/// NVS key of the band's L2CAP PSM (u16), read from its GATT table once instead of on every connect.
const PSM_KEY: &str = "psm";

async fn read_psm(client: &mut esp32_nimble::BLEClient) -> anyhow::Result<u16> {
    let step = |name: &'static str| move |e| anyhow::anyhow!("{name}: {e:?}");
    embassy_time::with_timeout(embassy_time::Duration::from_secs(10), async {
        let service = client.get_service(BAND_SERVICE).await.map_err(step("FEB8 service"))?;
        let characteristic = service.get_characteristic(PSM_CHARACTERISTIC).await.map_err(step("PSM characteristic"))?;
        let value = characteristic.read_value().await.map_err(step("PSM read"))?;
        anyhow::ensure!(value.len() == 2, "unexpected PSM value ({} bytes)", value.len());
        Ok(u16::from_le_bytes([value[0], value[1]]))
    }).await.map_err(|_| anyhow::anyhow!("GATT timed out"))?
}

/// The link while it's being set up: 7.5–15 ms and no skipped events, since the handshake is a
/// string of round trips. Once the band is live it moves to `LOW_POWER_LINK`.
/// Units: 1.25 ms (interval), 10 ms (supervision timeout), 0.625 ms (scan while connecting).
const SETUP_LINK: (u16, u16, u16, u16) = (6, 12, 0, 400);
/// The band may skip up to 4 connection events while it has nothing to send (it still sends at the
/// next one when it does), so it needn't wake every 30-50 ms.
const LOW_POWER_LINK: (u16, u16, u16, u16) = (24, 40, 4, 400);

fn update_link(conn_handle: u16, (itvl_min, itvl_max, latency, supervision_timeout): (u16, u16, u16, u16)) {
    let params = esp_idf_svc::sys::ble_gap_upd_params {
        itvl_min, itvl_max, latency, supervision_timeout,
        min_ce_len: esp_idf_svc::sys::BLE_GAP_INITIAL_CONN_MIN_CE_LEN as _,
        max_ce_len: esp_idf_svc::sys::BLE_GAP_INITIAL_CONN_MAX_CE_LEN as _,
    };
    let rc = unsafe { esp_idf_svc::sys::ble_gap_update_params(conn_handle, &params) };
    if rc != 0 { warn!("Couldn't update the band link's parameters: {rc}"); }
}

/// The band link's current interval and latency (the band may ask for its own).
pub fn link_params(conn_handle: u16) -> String {
    let mut desc = esp_idf_svc::sys::ble_gap_conn_desc::default();
    if unsafe { esp_idf_svc::sys::ble_gap_conn_find(conn_handle, &mut desc) } != 0 { return "?".into(); }
    format!("{:.1} ms latency {} timeout {} ms", desc.conn_itvl as f32 * 1.25, desc.conn_latency, desc.supervision_timeout as u32 * 10)
}

/// Until NimBLE reports the disconnect (at most 1.5 s), so the next connect doesn't find it open.
async fn closed(client: &esp32_nimble::BLEClient) {
    for _ in 0..150 {
        if !client.connected() { return; }
        embassy_time::Timer::after(embassy_time::Duration::from_millis(10)).await;
    }
}

/// Host advertising stays off while it lives (see `Remote::hold_advertising`).
struct HeldAdvertising<'a>(&'a Remote);

impl<'a> HeldAdvertising<'a> {
    fn new(remote: &'a Remote) -> Self { remote.hold_advertising(true); Self(remote) }
}

impl Drop for HeldAdvertising<'_> {
    fn drop(&mut self) { self.0.hold_advertising(false); }
}

/// When each step of making the band link finished, logged once the band is live.
struct Timeline {
    seen: Instant,
    steps: Vec<(&'static str, Instant)>,
    /// Time spent in band-core (its key exchange and signatures) up to then.
    core: Duration,
}

impl Timeline {
    fn new() -> Self { Self { seen: Instant::now(), steps: Vec::new(), core: Duration::ZERO } }
    fn mark(&mut self, step: &'static str) { self.steps.push((step, Instant::now())); }
    fn report(&self) -> String {
        let mut last = self.seen;
        let steps: Vec<String> = self.steps.iter().map(|(step, at)| {
            let part = format!("{step} {} ms", at.duration_since(last).as_millis());
            last = *at;
            part
        }).collect();
        // Most of the handshake is the band's own key exchange and signature (about 1.5 s).
        format!("{} ms from seeing the band ({}; band-core {} ms of it)", last.duration_since(self.seen).as_millis(),
                steps.join(", "), self.core.as_millis())
    }
}

async fn run_band(client: &mut esp32_nimble::BLEClient, identity: &EnrollmentIdentity, remote: &Remote, nvs: &EspNvs<NvsDefault>,
                  saved: Option<BLEAddress>, guess: usize, outcome: &mut Outcome) -> anyhow::Result<()> {
    // Made now (its key pair takes a while), not once the band is waiting for it.
    // Wrist motion is off until a pinch hold needs it (the controller turns it on).
    let mut session = BandSession::new(Some(identity.clone()), None, false).with_scheme_guess(guess).without_motion();
    control::set_band_state("searching");
    let Some(address) = find_band(saved).await else { anyhow::bail!("stopped looking for the band (released, or forgetting its pairing)") };
    let mut timeline = Timeline::new();
    let held = HeldAdvertising::new(remote);
    if client.connected() {
        warn!("Previous connection still open; closing it first");
        let _ = client.disconnect();
        closed(client).await;
    }
    let (itvl_min, itvl_max, latency, timeout) = SETUP_LINK;
    client.set_connection_params(itvl_min, itvl_max, latency, timeout, 16, 16);
    info!("Connecting to the band {address}");
    control::set_band_state("connecting");
    let step = |name: &'static str| move |e| anyhow::anyhow!("{name}: {e:?}");
    let seconds = embassy_time::Duration::from_secs;
    // The band was just seen advertising, so this takes ~100 ms (a few retries at worst).
    match embassy_time::with_timeout(seconds(5), client.connect(&address)).await {
        Ok(result) => result.map_err(step("connect"))?,
        Err(_) => {
            // NimBLE's own attempt runs on (30 s): stop it, or the next scan and connect find it
            // busy. Its cancellation lands in this client's signal, so the next try gets a new one.
            unsafe { esp_idf_svc::sys::ble_gap_conn_cancel() };
            embassy_time::Timer::after(embassy_time::Duration::from_millis(300)).await;
            *client = BLEDevice::take().new_client();
            anyhow::bail!("connect timed out");
        }
    }
    timeline.mark("link");
    embassy_time::with_timeout(seconds(15), client.secure_connection()).await.map_err(|_| anyhow::anyhow!("encryption timed out"))?.map_err(step("encryption"))?;
    timeline.mark("encryption");
    drop(held);
    info!("Bluetooth link encrypted (bonded)");
    outcome.band = client.desc().ok().map(|desc| desc.id_address());
    let conn_handle = client.desc().map_err(step("connection handle"))?.conn_handle();
    let cached = nvs.get_u16(PSM_KEY).ok().flatten();
    let psm = match cached { Some(psm) => psm, None => read_psm(client).await? };
    info!("PSM {psm}{}; opening the L2CAP channel", if cached.is_some() { " (saved)" } else { "" });
    let channel = match coc::Channel::connect(conn_handle, psm, Duration::from_secs(5)) {
        Err(error) if cached.is_some() => {
            warn!("L2CAP on the saved PSM failed ({error:#}); reading it again");
            let _ = nvs.remove(PSM_KEY);
            coc::Channel::connect(conn_handle, read_psm(client).await?, Duration::from_secs(5))?
        }
        channel => channel?,
    };
    timeline.mark("L2CAP");
    let result = stream_session(&channel, identity, remote, &mut session, conn_handle, &mut timeline, outcome).await;
    if session.scheme_guess().is_some() && session.authenticated_packets() == 0 {
        outcome.wrong_guess = true;
    }
    match (outcome.live, cached) {
        (false, Some(_)) => { let _ = nvs.remove(PSM_KEY); } // maybe not the band's session channel any more
        (true, None) => { let _ = nvs.set_u16(PSM_KEY, psm); }
        _ => {}
    }
    let (sdus, bytes) = channel.stats();
    info!("L2CAP closed after {sdus} SDUs / {bytes} bytes");
    // Dropping the link closes the channel (see `coc::Channel`).
    let _ = client.disconnect();
    closed(client).await;
    result
}

/// A band silent this long is asked whether it's still subscribed; this long with no answer, the
/// link is dropped and made again.
const QUIET_QUERY: f64 = 5.0;
const QUIET_LOST: f64 = 20.0;

async fn stream_session(channel: &coc::Channel, identity: &EnrollmentIdentity, remote: &Remote, session: &mut BandSession,
                        conn_handle: u16, timeline: &mut Timeline, outcome: &mut Outcome) -> anyhow::Result<()> {
    let started = Instant::now();
    let now = || started.elapsed().as_secs_f64();
    let mut controller = Controller::new(remote);
    let request = Instant::now();
    channel.send(&session.request()?)?;
    timeline.core += request.elapsed();
    info!("Sent RequestEncryption; running band-core as owner {}", fingerprint(identity));

    let mut next_battery = 0.0;
    let mut last_traffic = now();
    let mut last_status_query = 0.0;
    let mut last_report = -100.0;
    let mut reports = 0u32;
    // The most events one SDU made, and its size, since the last report.
    let mut burst = (0usize, 0usize);
    let mut slowest = Duration::ZERO;
    // Time the loop spends working (not waiting for the band) since the last report: its CPU load.
    let mut busy = Duration::ZERO;
    loop {
        let round = Instant::now();
        let mut outgoing = Vec::new();
        let received = channel.take();
        if received.is_empty() {
            embassy_time::Timer::after(embassy_time::Duration::from_millis(5)).await;
        }
        let working = Instant::now();
        for sdu in received {
            last_traffic = now();
            let feeding = Instant::now();
            // Events go to the controller as they're decoded: one record of motion is hundreds.
            let mut hand = session.hand();
            let (mut battery, mut events) = (None, 0usize);
            let bytes = session.feed_into(&sdu, now(), &mut |event| {
                events += 1;
                match event {
                    // Its detail is read from the session once the feed is done.
                    Event::BatteryStatus(Some(_)) => battery = Some(event),
                    event => {
                        match &event { Event::Handedness(h) => hand = Some(*h), Event::HandednessFailure(_) => hand = None, _ => {} }
                        controller.event(event, now(), hand);
                    }
                }
            }).map_err(|e| anyhow::anyhow!("session: {e}"))?;
            if let Some(event) = battery {
                controller.battery_detail = session.battery_detail();
                controller.event(event, now(), session.hand());
            }
            if !outcome.live { timeline.core += feeding.elapsed(); }
            outgoing.extend(bytes);
            if events > burst.0 { burst = (events, sdu.len()); }
        }
        if !outcome.live && session.streams_enabled() {
            outcome.live = true;
            timeline.mark("handshake");
            info!("CONNECTED: {}", timeline.report());
            update_link(conn_handle, LOW_POWER_LINK);
        }
        let hand = session.hand();
        for event in session.tick(now()) { controller.event(event, now(), hand); }
        session.set_describe_gestures(control::lab_on());
        for line in session.take_diagnostics() {
            if line.starts_with("LAB ") { info!("{line}"); } else { info!("band-core: {line}"); }
        }
        outgoing.extend(controller.poll(session, now()));
        if session.streams_enabled() && now() >= next_battery {
            next_battery = now() + control::battery_every();
            outgoing.extend(session.query_battery_status(now())?);
        }
        // A quiet band (motion off, no gestures) sends nothing: ask for the subscription status.
        if session.streams_enabled() && now() - last_traffic >= QUIET_QUERY && now() - last_status_query >= QUIET_QUERY {
            last_status_query = now();
            outgoing.extend(session.query_stream_state()?);
        }
        if paused() {
            let bytes = session.stop().unwrap_or_default();
            if !bytes.is_empty() { let _ = channel.send(&bytes); }
            anyhow::bail!("released the band (BOOT button)");
        }
        if channel.overflowed() {
            anyhow::bail!("the band sent more than the dongle could hold before reading it; reconnecting");
        }
        if !channel.is_open() {
            anyhow::bail!("the band closed the L2CAP channel");
        }
        if now() - last_traffic > QUIET_LOST {
            anyhow::bail!("no traffic from the band for {QUIET_LOST} s (status queries unanswered)");
        }
        if !outgoing.is_empty() { channel.send(&outgoing)?; }
        slowest = slowest.max(round.elapsed());
        busy += working.elapsed();
        if session.streams_enabled() && now() - last_report >= 30.0 {
            last_report = now();
            let (sdus, bytes) = channel.stats();
            let hosts: Vec<String> = remote.hosts().iter().map(|host| format!("{} {}", host.0, link_params(host.0))).collect();
            info!("links to hosts: {}", hosts.join(", "));
            info!("memory: {}", memory::summary());
            // The pools and stacks sdkconfig.defaults and the threads were sized by: at first, then every 10 minutes.
            if reports % 20 <= 1 {
                info!("memory: pools {}", memory::pools());
                info!("memory: stack unused {}", memory::stacks());
            }
            reports += 1;
            info!("streaming: {} packets ({sdus} SDUs, {bytes} B, at most {} events from one of {} B, {} B waiting, {} ms a round, busy {} ms), {} gyro, {} gestures, motion {}, writing {}, hand {:?}, link {}",
                  session.authenticated_packets(), burst.0, burst.1, channel.take_peak(), slowest.as_millis(), busy.as_millis(), controller.motion, controller.gestures,
                  if session.motion_on() { "on" } else { "off" }, if session.band_writing() { "on" } else { "off" }, session.hand(),
                  link_params(conn_handle));
            burst = (0, 0);
            slowest = Duration::ZERO;
            busy = Duration::ZERO;
        }
    }
}

fn main() -> anyhow::Result<()> {
    esp_idf_svc::sys::link_patches();
    control::init_logging();
    info!("band-dongle v{} (band-core 4b59393 vendored, own L2CAP layer): several hosts, slides, Teams, control service, OTA",
          env!("CARGO_PKG_VERSION"));

    // What each step of starting up takes from the heap, logged once it's done.
    let mut marks = vec![("start", memory::free())];
    let mut mark = |step| marks.push((step, memory::free()));
    let partition = EspDefaultNvsPartition::take()?;
    let nvs = EspNvs::new(partition.clone(), "np", true)?;
    adopt_identity(&nvs);
    mark("NVS");
    // Bluetooth's buffer pools and tasks, kept for good: what doesn't fit 48 KB of the main region
    // goes to the spare ones (they then hold 41 KB of it, 0.15.2). 32 KB was too few on a chip's
    // first boot (0.18.0, a fresh Cardputer): the radio's full calibration took the rest, and
    // NimBLE's task didn't fit.
    let device = memory::in_spare_regions(48 * 1024, BLEDevice::take);
    memory::watch_lowest();
    device.security().set_auth(AuthReq::Bond | AuthReq::Sc).set_io_cap(SecurityIOCap::NoInputNoOutput).resolve_rpa();
    let mut client = device.new_client();
    let mut band_address = saved_band(&nvs).or_else(|| adopt_band(&nvs, device));
    mark("Bluetooth");
    profiles::load(&nvs);
    mark("profiles");
    let remote = Remote::new(EspNvs::new(partition.clone(), "np", true)?, band_address)?;
    mark("HID");
    let control = control::Control::new(&remote);
    remote.advertise(control::SERVICE)?;
    mark("control service");
    control.spawn(spawn_self_test);
    announce_gatt_changes(&nvs);
    ota::confirm_after_probation();
    spawn_serial_reader(partition, remote.clone());
    watch_boot_button();
    cardputer::start(remote.clone());
    mark("threads");
    let steps: Vec<String> = marks.windows(2).map(|pair| format!("{} {} B", pair[1].0, pair[0].1 as isize - pair[1].1 as isize)).collect();
    info!("memory at boot: {} B free at start; {}; {} B free now", marks[0].1, steps.join(", "), memory::free());
    let mut encryption_failures = 0;
    let mut failures = 0;

    loop {
        if paused() {
            std::thread::sleep(Duration::from_millis(100));
            continue;
        }
        let Some(identity) = load_owner(&nvs) else {
            control::set_band_state("no-owner");
            warn!("No owner key provisioned. Send: OWNER <base64 owner_key>");
            std::thread::sleep(Duration::from_secs(5));
            continue;
        };
        // Updated band firmware negotiates scheme 26, whose rules are guessed: the guess that
        // worked is kept in NVS, and one that authenticates nothing moves on to the next.
        let guess = nvs.get_u8("guess").ok().flatten().unwrap_or(0) as usize;
        let mut outcome = Outcome::default();
        let result = block_on(run_band(&mut client, &identity, &remote, &nvs, band_address, guess, &mut outcome));
        if let Some(band) = outcome.band.filter(|band| Some(*band) != band_address) {
            save_band(&nvs, band);
            band_address = Some(band);
        }
        control::set_band_state("searching");
        match &result {
            Ok(()) => info!("band session ended"),
            Err(error) => warn!("band session ended: {error:#}"),
        }
        // A band firmware update clears its pairings: the saved keys then never encrypt the link.
        // After two such failures in a row, forget them so the next attempt pairs afresh.
        let encryption_failed = result.as_ref().is_err_and(|error| error.to_string().starts_with("encryption"));
        encryption_failures = if encryption_failed { encryption_failures + 1 } else { 0 };
        if encryption_failures >= 2 || UNPAIR_REQUEST.swap(false, std::sync::atomic::Ordering::SeqCst) {
            encryption_failures = 0;
            let Some(band) = band_address else { continue };
            match device.delete_bond(&band) {
                Ok(()) => warn!("Forgot the Bluetooth pairing with the band. Put the band in pairing mode to pair it with this dongle again \
                                 (the owner key is kept; a band firmware update clears its pairings)."),
                Err(error) => warn!("Couldn't forget the band pairing: {error:?}"),
            }
        }
        if outcome.wrong_guess {
            let next = (guess + 1) % band_core::airshield::SCHEME_26_GUESSES.len();
            warn!("scheme 26 guess {guess} authenticated nothing; trying guess {next} next");
            let _ = nvs.set_u8("guess", next as u8);
        }
        // Straight back to scanning after a session that worked (the band turned off or
        // restarted); a band that keeps failing to connect is retried less and less often.
        failures = if outcome.live { 0 } else { failures + 1 };
        std::thread::sleep(Duration::from_millis([0, 500, 2000, 5000][failures.min(3)]));
    }
}

/// Bump when services or characteristics change, so paired hosts drop their cached GATT table.
const GATT_VERSION: u8 = 4;

/// NimBLE delivers a Service Changed indication to every paired host that subscribed to it (now,
/// or when it reconnects), so an update that adds characteristics needs no re-pairing.
fn announce_gatt_changes(nvs: &EspNvs<NvsDefault>) {
    if nvs.get_u8("gattv").ok().flatten() == Some(GATT_VERSION) { return; }
    unsafe { esp_idf_svc::sys::ble_svc_gatt_changed(0x0001, 0xffff) };
    let _ = nvs.set_u8("gattv", GATT_VERSION);
    info!("GATT layout v{GATT_VERSION}: paired hosts are told to rediscover services");
}
