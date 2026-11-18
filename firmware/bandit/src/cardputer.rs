//! The M5Stack Cardputer ADV the dongle runs on: its screen shows the band, the active device and
//! its profile (in the profile's colour, and so does the LED); its keyboard switches them, plays
//! media, or types on a computer (`fn K`). The G0 button does what the XIAO's BOOT button did.
//!
//! The board is recognised by its keyboard controller (a TCA8418 at 0x34 on G8/G9): without one
//! (a XIAO, or a Cardputer v1.1, whose keyboard is a plain matrix) nothing here starts and the
//! dongle runs headless as before. Everything runs on one thread at the main task's priority, and
//! the screen is redrawn only when what it shows changes (a few times a second while it animates).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use embedded_graphics_core::draw_target::DrawTarget;
use embedded_graphics_core::geometry::{OriginDimensions, Point, Size};
use embedded_graphics_core::pixelcolor::PixelColor;
use embedded_graphics_core::Pixel;
use esp_idf_svc::hal::adc::oneshot::config::{AdcChannelConfig, Calibration};
use esp_idf_svc::hal::adc::oneshot::{AdcChannelDriver, AdcDriver};
use esp_idf_svc::hal::adc::attenuation::DB_12;
use esp_idf_svc::hal::delay::FreeRtos;
use esp_idf_svc::hal::gpio::{Input, OutputPin, Output, PinDriver, Pull};
use esp_idf_svc::hal::i2c::{I2cConfig, I2cDriver};
use esp_idf_svc::hal::peripherals::Peripherals;
use esp_idf_svc::hal::rmt::config::{TransmitConfig, TxChannelConfig};
use esp_idf_svc::hal::rmt::encoder::{BytesEncoder, BytesEncoderConfig};
use esp_idf_svc::hal::rmt::{PinState, Pulse, PulseTicks, Symbol, TxChannelDriver};
use esp_idf_svc::hal::spi::config::{Config as SpiConfig, DriverConfig};
use esp_idf_svc::hal::spi::{Dma, SpiAnyPins, SpiDeviceDriver, SpiDriver};
use esp_idf_svc::hal::units::FromValueType;
use log::{info, warn};
use u8g2_fonts::types::{FontColor, HorizontalAlignment, VerticalPosition};
use u8g2_fonts::{fonts, FontRenderer};

use crate::control;
use crate::remote::{keys, Action, Alert, Kind, MediaKey, Remote};

// ---- what the band just did, for the screen (the controller says) ----

/// The letter menu is waiting for a letter (the controller says): the screen lists them.
static MENU_OPEN: AtomicBool = AtomicBool::new(false);

/// The letter menu opened or closed (the controller calls this).
pub fn menu(open: bool) { MENU_OPEN.store(open, Ordering::Relaxed); }

/// The last gesture and what it did, and when.
static GESTURE: Mutex<Option<(String, Instant)>> = Mutex::new(None);

/// A gesture ran `action` (the controller calls this): the screen shows it for a few seconds and
/// the LED flashes.
pub fn gesture(name: &str, action: &bandit_profiles::Action) {
    let text = format!("{}  >  {}", gesture_name(name), action_name(action));
    *GESTURE.lock().unwrap() = Some((text, Instant::now()));
}

fn gesture_name(name: &str) -> String {
    let words = match name {
        "index.doubleTap" => "Index double tap", "index.tripleTap" => "Index triple tap",
        "middle.doubleTap" => "Middle double tap", "middle.tripleTap" => "Middle triple tap",
        "dial.cw" => "Dial right", "dial.ccw" => "Dial left",
        "index.tap" => "Index tap", "middle.tap" => "Middle tap", "index.hold" => "Index hold", "middle.hold" => "Middle hold",
        other => return other.trim_start_matches("band.").replace('.', " ").char_indices()
            .map(|(i, c)| if i == 0 { c.to_ascii_uppercase() } else { c }).collect(),
    };
    words.to_string()
}

fn action_name(action: &bandit_profiles::Action) -> String {
    use bandit_profiles::{Action as Do, Button, Call, HostTarget, Media, ProfileTarget};
    match action {
        Do::None => "nothing".into(),
        Do::Media(media) => match media {
            Media::PlayPause => "Play/Pause", Media::Next => "Next track", Media::Previous => "Previous track",
            Media::VolumeUp => "Volume up", Media::VolumeDown => "Volume down", Media::Mute => "Mute", Media::Voice => "Voice",
        }.into(),
        Do::PhoneMute => "Mute call".into(),
        Do::Call(Call::Answer) => "Answer call".into(),
        Do::Call(Call::End) => "End call".into(),
        Do::Call(Call::Toggle) => "Answer/End call".into(),
        Do::Key(chord) => chord_name(chord),
        Do::Hold(chord) => format!("hold {}", chord_name(chord)),
        Do::Type(text) => format!("type \"{text}\""),
        Do::Click(button) => match button {
            Button::Left => "Click".into(), Button::Right => "Right click".into(), Button::Middle => "Middle click".into(),
            Button::Extra(n) => format!("Mouse button {n}"),
        },
        Do::Scroll(steps) => if *steps > 0 { "Scroll up" } else { "Scroll down" }.into(),
        Do::Profile(target) => match target {
            ProfileTarget::Index(index) => crate::profiles::current().profiles.get(*index)
                .map_or("Profile".into(), |profile| format!("Go to {}", profile.name)),
            ProfileTarget::Next => "Next profile".into(),
            ProfileTarget::Previous => "Previous profile".into(),
            ProfileTarget::Back => "Back a profile".into(),
            ProfileTarget::Home => "Home profile".into(),
            ProfileTarget::App => "The app's profile".into(),
        },
        Do::Host(target) => match target {
            HostTarget::Next => "Next device".into(),
            HostTarget::Previous => "Previous device".into(),
            HostTarget::Kind(hosts) => format!("Go to the {}", hosts.name()),
        },
        Do::Menu => "Letter menu".into(),
        Do::Write(_) => "Handwriting".into(),
        Do::Buzz(_) => "Buzz".into(),
        Do::Apps(forward) => if *forward { "App switcher" } else { "App switcher back" }.into(),
        Do::Point => "Air mouse".into(),
    }
}

/// `cmd+shift+t`, as PROFILES.md writes it.
fn chord_name(chord: &bandit_profiles::Chord) -> String {
    use bandit_profiles::modifiers::{ALT, CTRL, GUI, SHIFT};
    let mut name = String::new();
    for (bit, word) in [(GUI, "cmd+"), (CTRL, "ctrl+"), (ALT, "alt+"), (SHIFT, "shift+")] {
        if chord.modifiers & bit != 0 { name.push_str(word); }
    }
    let key = match chord.usage {
        usage @ 0x04..=0x1D => ((b'a' + usage - 0x04) as char).to_string(),
        usage @ 0x1E..=0x26 => ((b'1' + usage - 0x1E) as char).to_string(),
        0x27 => "0".into(),
        usage @ 0x3A..=0x45 => format!("f{}", usage - 0x39),
        usage => match usage {
            0x28 => "enter", 0x29 => "esc", 0x2A => "backspace", 0x2B => "tab", 0x2C => "space",
            0x2D => "-", 0x2E => "=", 0x2F => "[", 0x30 => "]", 0x31 => "\\", 0x33 => ";", 0x34 => "'", 0x35 => "`",
            0x36 => ",", 0x37 => ".", 0x38 => "/", 0x39 => "capslock",
            0x4F => "right", 0x50 => "left", 0x51 => "down", 0x52 => "up",
            0x4A => "home", 0x4B => "pageup", 0x4C => "delete", 0x4D => "end", 0x4E => "pagedown",
            _ => "?",
        }.into(),
    };
    name + &key
}

/// What each gesture does in this profile on `kind` (the set's `everywhere` ones included), in
/// the order the app lists them: what's typed and the pointer first, when the profile has them.
fn gesture_rows(profile: &bandit_profiles::Profile, kind: bandit_profiles::HostKind) -> Vec<(String, String)> {
    use bandit_profiles::Gesture;
    let mut rows = Vec::new();
    if profile.pointer { rows.push(("Pinch + move".to_string(), "Mouse pointer".to_string())); }
    if profile.typing { rows.push(("Write in the air".to_string(), "Typed".to_string())); }
    let band = profile.gestures.keys().chain(profile.everywhere.keys()).filter(|g| matches!(g, Gesture::Band(_)));
    let mut seen = Vec::new();
    for gesture in Gesture::ALL.iter().chain(band) {
        if seen.contains(gesture) { continue; }
        seen.push(*gesture);
        if let Some(action) = profile.binding(*gesture, kind).and_then(|binding| binding.resolve(kind)) {
            rows.push((gesture_name(&gesture.name()), action_name(action)));
        }
    }
    rows
}

// ---- start ----

/// Looks for the Cardputer's keyboard and, when it's there, runs the screen, keyboard, battery
/// and LED on a thread of their own. Call once, after the HID service is up.
pub fn start(remote: Remote) {
    // It used 3.4 KB of 8 (0.18.0).
    let started = crate::memory::spawn_with(c"cardputer", 6 * 1024, Some(1), move || {
        let Some(peripherals) = Peripherals::take().ok() else { return warn!("CARDPUTER: peripherals already taken") };
        let pins = peripherals.pins;
        let i2c = I2cDriver::new(peripherals.i2c0, pins.gpio8, pins.gpio9, &I2cConfig::new().baudrate(400.kHz().into()));
        let keyboard = match i2c.map_err(|e| e.to_string()).and_then(Keyboard::new) {
            Ok(keyboard) => keyboard,
            Err(error) => return info!("CARDPUTER: no keyboard controller ({error}): running headless"),
        };
        let int = PinDriver::input(pins.gpio11, Pull::Up).ok();
        let display = match Display::new(peripherals.spi3, pins.gpio36, pins.gpio35, pins.gpio37, pins.gpio34, pins.gpio33, pins.gpio38) {
            Ok(display) => display,
            Err(error) => return warn!("CARDPUTER: the screen didn't start: {error}"),
        };
        let adc = AdcDriver::new(peripherals.adc1).ok();
        let battery = adc.as_ref().and_then(|adc| {
            let config = AdcChannelConfig { attenuation: DB_12, calibration: Calibration::Curve, ..Default::default() };
            let mut channel = AdcChannelDriver::new(adc, pins.gpio10, &config).ok()?;
            // Behind a halving divider.
            Some(Box::new(move || channel.read().ok().map(|mv| f32::from(mv) * 2.0)) as Battery)
        });
        let led = Led::new(pins.gpio21).map_err(|error| warn!("CARDPUTER: no LED ({error})")).ok();
        info!("CARDPUTER: screen, keyboard{}{} ready", if battery.is_some() { ", battery" } else { "" }, if led.is_some() { ", LED" } else { "" });
        let mut ui = Ui::new(remote, display, keyboard, int, battery, led);
        ui.run();
    });
    if let Err(error) = started { warn!("CARDPUTER: couldn't start its thread: {error}"); }
}

// ---- the screen: an ST7789V2, 240×135 in a 240×320 controller, drawn a band at a time ----

const WIDTH: usize = 240;
const HEIGHT: usize = 135;
/// Where the visible 240×135 sits in the controller's memory, turned landscape (M5GFX's numbers).
const COL_START: u16 = 40;
const ROW_START: u16 = 53;
/// The screen is drawn in bands of this many rows (5 of them), each drawn whole and sent: 3.2 KB
/// for the band, not 16 KB for the screen (the band's session needs the heap more).
const BAND: usize = 27;
/// Rows sent per SPI transfer (1.4 KB of DMA buffer).
const STRIP: usize = 3;

/// A palette index: pixels are 4 bits, so the profile's colour is a palette entry and changing
/// profile recolours everything at once.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Ink(u8);

impl PixelColor for Ink { type Raw = (); }

const BG: Ink = Ink(0);
const CARD: Ink = Ink(1);
const LINE: Ink = Ink(2);
const DIM: Ink = Ink(3);
const TEXT: Ink = Ink(4);
const WHITE: Ink = Ink(5);
const ACCENT: Ink = Ink(6);
/// The accent at 22% over the background: the hero card.
const DEEP: Ink = Ink(7);
/// At 45%: the card's glow edge and dots.
const MID: Ink = Ink(8);
const GREEN: Ink = Ink(9);
const AMBER: Ink = Ink(10);
const RED: Ink = Ink(11);
// 12: spare.
/// At 10%: the glow around the card.
const HALO: Ink = Ink(13);
/// The accent mixed halfway to white: labels on the card.
const LIGHT: Ink = Ink(14);
const SHADOW: Ink = Ink(15);

const BASE: [u32; 16] = [
    0x07080d, 0x141722, 0x262b3a, 0x7c8499, 0xe8eaf0, 0xffffff, 0, 0, 0, 0x34d399, 0xffb840, 0xff616b, 0x6094ff, 0, 0, 0x020306,
];

fn mix(a: u32, b: u32, t: f32) -> u32 {
    let channel = |shift: u32| {
        let (x, y) = (((a >> shift) & 0xff) as f32, ((b >> shift) & 0xff) as f32);
        ((x + (y - x) * t).round() as u32).min(255) << shift
    };
    channel(16) | channel(8) | channel(0)
}

/// 0xRRGGBB as the panel's RGB565, high byte first.
fn rgb565(color: u32) -> [u8; 2] {
    let (r, g, b) = ((color >> 16) & 0xff, (color >> 8) & 0xff, color & 0xff);
    let value = ((r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)) as u16;
    value.to_be_bytes()
}

/// One band of the screen, from row `top`: drawing anywhere on the screen lands only here.
struct Frame {
    pixels: Vec<u8>,
    top: i32,
    palette: [[u8; 2]; 16],
}

impl Frame {
    fn new() -> Self {
        let mut frame = Frame { pixels: vec![0; WIDTH * BAND / 2], top: 0, palette: [[0; 2]; 16] };
        frame.set_accent(0x6094ff);
        frame
    }

    fn set_accent(&mut self, accent: u32) {
        let mut colors = BASE;
        colors[ACCENT.0 as usize] = accent;
        colors[DEEP.0 as usize] = mix(BASE[0], accent, 0.22);
        colors[MID.0 as usize] = mix(BASE[0], accent, 0.45);
        colors[HALO.0 as usize] = mix(BASE[0], accent, 0.10);
        colors[LIGHT.0 as usize] = mix(accent, 0xffffff, 0.55);
        for (slot, color) in self.palette.iter_mut().zip(colors) { *slot = rgb565(color); }
    }

    fn clear(&mut self, ink: Ink) { self.pixels.fill(ink.0 << 4 | ink.0); }

    fn set(&mut self, x: i32, y: i32, ink: Ink) {
        let y = y - self.top;
        if x < 0 || y < 0 || x >= WIDTH as i32 || y >= BAND as i32 { return; }
        let index = y as usize * (WIDTH / 2) + x as usize / 2;
        let byte = &mut self.pixels[index];
        *byte = if x % 2 == 0 { (*byte & 0x0f) | ink.0 << 4 } else { (*byte & 0xf0) | ink.0 };
    }

    fn fill(&mut self, x: i32, y: i32, w: i32, h: i32, ink: Ink) {
        for row in y.max(self.top)..(y + h).min(self.top + BAND as i32) {
            for column in x.max(0)..(x + w).min(WIDTH as i32) { self.set(column, row, ink); }
        }
    }

    /// A rectangle with corners of radius `r`.
    fn rounded(&mut self, x: i32, y: i32, w: i32, h: i32, r: i32, ink: Ink) {
        for row in 0..h {
            // How far in the corner curve starts on this row.
            let dy = if row < r { r - row } else if row >= h - r { row - (h - r) + 1 } else { 0 };
            let inset = if dy == 0 { 0 } else { r - ((r * r - dy * dy) as f32).max(0.0).sqrt() as i32 };
            self.fill(x + inset, y + row, w - 2 * inset, 1, ink);
        }
    }

    fn disc(&mut self, cx: i32, cy: i32, r: i32, ink: Ink) {
        for dy in -r..=r {
            let half = ((r * r - dy * dy) as f32).sqrt() as i32;
            self.fill(cx - half, cy + dy, 2 * half + 1, 1, ink);
        }
    }

    /// A triangle pointing left or right, `size` tall, its point at (x, cy).
    fn arrow(&mut self, x: i32, cy: i32, size: i32, right: bool, ink: Ink) {
        for step in 0..=size / 2 {
            let column = if right { x - step } else { x + step };
            self.fill(column, cy - step, 1, 2 * step + 1, ink);
        }
    }

    /// Signal bars, `level` of 4 lit, standing on `bottom`; `scale` 1 is 11 px wide.
    fn bars(&mut self, x: i32, bottom: i32, level: u8, scale: i32) {
        let lit = match level { 3.. => GREEN, 2 => AMBER, _ => RED };
        for bar in 0..4 {
            let height = (bar + 1) * 5 * scale / 2;
            self.fill(x + bar * 3 * scale, bottom - height, 2 * scale, height, if bar < i32::from(level) { lit } else { LINE });
        }
    }

    /// A lightning bolt 5 wide and 8 tall from (x, top): charging.
    fn bolt(&mut self, x: i32, top: i32, ink: Ink) {
        for (row, (start, len)) in [(3, 2), (2, 2), (1, 2), (0, 5), (2, 2), (1, 2), (1, 1), (0, 1)].into_iter().enumerate() {
            self.fill(x + start, top + row as i32, len, 1, ink);
        }
    }

    /// Text with its baseline at `y`; returns how wide it was.
    fn text<F: u8g2_fonts::Font>(&mut self, text: &str, x: i32, y: i32, align: HorizontalAlignment, ink: Ink) -> i32 {
        let renderer = FontRenderer::new::<F>().with_ignore_unknown_chars(true);
        let width = text_width::<F>(text);
        let _ = renderer.render_aligned(text, Point::new(x, y), VerticalPosition::Baseline, align, FontColor::Transparent(ink), self);
        width
    }
}

fn text_width<F: u8g2_fonts::Font>(text: &str) -> i32 {
    FontRenderer::new::<F>().with_ignore_unknown_chars(true)
        .get_rendered_dimensions(text, Point::zero(), VerticalPosition::Baseline)
        .map(|dims| dims.advance.x).unwrap_or(0)
}

/// `text` cut to fit `width` pixels in font `F`, with "..." when it was cut.
fn fit<F: u8g2_fonts::Font>(text: &str, width: i32) -> String {
    if text_width::<F>(text) <= width { return text.to_string(); }
    let mut cut: String = text.to_string();
    while !cut.is_empty() && text_width::<F>(&format!("{cut}...")) > width { cut.pop(); }
    format!("{}...", cut.trim_end())
}

impl OriginDimensions for Frame {
    fn size(&self) -> Size { Size::new(WIDTH as u32, HEIGHT as u32) }
}

impl DrawTarget for Frame {
    type Color = Ink;
    type Error = core::convert::Infallible;

    fn draw_iter<I: IntoIterator<Item = Pixel<Ink>>>(&mut self, pixels: I) -> Result<(), Self::Error> {
        for Pixel(point, ink) in pixels { self.set(point.x, point.y, ink); }
        Ok(())
    }
}

/// Reads the Cardputer's battery, in mV.
type Battery<'d> = Box<dyn FnMut() -> Option<f32> + 'd>;

struct Display<'d> {
    spi: SpiDeviceDriver<'d, SpiDriver<'d>>,
    dc: PinDriver<'d, Output>,
    backlight: PinDriver<'d, Output>,
    /// Held high for good: a dropped pin driver lets the pin float, and a floating reset holds the
    /// panel in reset (lit, blank).
    _reset: PinDriver<'d, Output>,
    strip: Vec<u8>,
}

impl<'d> Display<'d> {
    #[allow(clippy::too_many_arguments)]
    fn new(
        spi: impl SpiAnyPins + 'd, sclk: impl OutputPin + 'd, mosi: impl OutputPin + 'd, cs: impl OutputPin + 'd,
        dc: impl OutputPin + 'd, reset: impl OutputPin + 'd, backlight: impl OutputPin + 'd,
    ) -> anyhow::Result<Self> {
        let driver = SpiDriver::new(spi, sclk, mosi, None::<esp_idf_svc::hal::gpio::AnyIOPin>,
                                    &DriverConfig::new().dma(Dma::Auto(WIDTH * STRIP * 2)))?;
        let spi = SpiDeviceDriver::new(driver, Some(cs), &SpiConfig::new().baudrate(40.MHz().into()))?;
        let mut reset = PinDriver::output(reset)?;
        reset.set_low()?;
        FreeRtos::delay_ms(10);
        reset.set_high()?;
        FreeRtos::delay_ms(120);
        let mut display = Display {
            spi,
            dc: PinDriver::output(dc)?,
            backlight: PinDriver::output(backlight)?,
            _reset: reset,
            strip: vec![0; WIDTH * STRIP * 2],
        };
        display.init()?;
        Ok(display)
    }

    fn command(&mut self, command: u8, data: &[u8]) -> anyhow::Result<()> {
        self.dc.set_low()?;
        self.spi.write(&[command])?;
        if !data.is_empty() {
            self.dc.set_high()?;
            self.spi.write(data)?;
        }
        Ok(())
    }

    /// M5GFX's ST7789 setup for this panel.
    fn init(&mut self) -> anyhow::Result<()> {
        self.command(0x01, &[])?; // software reset
        FreeRtos::delay_ms(150);
        self.command(0x11, &[])?; // out of sleep
        FreeRtos::delay_ms(120);
        self.command(0xB7, &[0x35])?;
        self.command(0xBB, &[0x28])?;
        self.command(0xC0, &[0x0C])?;
        self.command(0xC2, &[0x01, 0xFF])?;
        self.command(0xC3, &[0x10])?;
        self.command(0xC4, &[0x20])?;
        self.command(0xD0, &[0xA4, 0xA1])?;
        self.command(0xB0, &[0x00, 0xC0])?;
        self.command(0xE0, &[0xD0, 0x00, 0x02, 0x07, 0x0A, 0x28, 0x32, 0x44, 0x42, 0x06, 0x0E, 0x12, 0x14, 0x17])?;
        self.command(0xE1, &[0xD0, 0x00, 0x02, 0x07, 0x0A, 0x28, 0x31, 0x54, 0x47, 0x0E, 0x1C, 0x17, 0x1B, 0x1E])?;
        self.command(0x3A, &[0x55])?; // 16 bits a pixel
        // Landscape: row/column exchange, mirrored as M5GFX's rotation 1 (MV|MX|MH), BGR.
        self.command(0x36, &[0x20 | 0x40 | 0x04 | 0x08])?;
        self.command(0x21, &[])?; // inverted (this panel's colours are)
        self.command(0x29, &[])?; // on
        self.backlight.set_high()?;
        Ok(())
    }

    fn light(&mut self, on: bool) {
        let _ = if on { self.backlight.set_high() } else { self.backlight.set_low() };
    }

    /// Starts writing rows `from` to `to` (exclusive): the bands follow, top first (`send`).
    fn begin(&mut self, from: u16, to: u16) -> anyhow::Result<()> {
        let (x0, x1) = (COL_START, COL_START + WIDTH as u16 - 1);
        let (y0, y1) = (ROW_START + from, ROW_START + to - 1);
        self.command(0x2A, &[(x0 >> 8) as u8, x0 as u8, (x1 >> 8) as u8, x1 as u8])?;
        self.command(0x2B, &[(y0 >> 8) as u8, y0 as u8, (y1 >> 8) as u8, y1 as u8])?;
        self.command(0x2C, &[])?;
        self.dc.set_high()?;
        Ok(())
    }

    fn send(&mut self, frame: &Frame) -> anyhow::Result<()> {
        for strip in frame.pixels.chunks(WIDTH / 2 * STRIP) {
            let mut out = 0;
            for byte in strip {
                for nibble in [byte >> 4, byte & 0x0f] {
                    self.strip[out..out + 2].copy_from_slice(&frame.palette[nibble as usize]);
                    out += 2;
                }
            }
            self.spi.write(&self.strip[..out])?;
        }
        Ok(())
    }
}

// ---- the keyboard: a TCA8418 scanning 7×8, which M5's library maps onto 4 rows of 14 keys ----

const TCA8418: u8 = 0x34;

/// What each key is, by the printed layout. Control characters stand for the keys without one:
/// \x01 fn, \x02 shift, \x03 ctrl, \x04 opt, \x05 alt, \x08 backspace.
const LAYOUT: [&str; 4] = ["`1234567890-=\x08", "\tqwertyuiop[]\\", "\x01\x02asdfghjkl;'\n", "\x03\x04\x05zxcvbnm,./ "];
const SHIFTED: [&str; 4] = ["~!@#$%^&*()_+\x08", "\tQWERTYUIOP{}|", "\x01\x02ASDFGHJKL:\"\n", "\x03\x04\x05ZXCVBNM<>? "];

struct Keyboard<'d> {
    i2c: I2cDriver<'d>,
    fn_down: bool,
    shift: bool,
    ctrl: bool,
    opt: bool,
    alt: bool,
}

/// A key pressed, with the modifiers held.
#[derive(Clone, Copy, Debug)]
struct Press {
    key: char,
    fn_down: bool,
    shift: bool,
    ctrl: bool,
    opt: bool,
    alt: bool,
}

impl<'d> Keyboard<'d> {
    fn new(mut i2c: I2cDriver<'d>) -> Result<Self, String> {
        let mut write = |register: u8, value: u8| i2c.write(TCA8418, &[register, value], 50).map_err(|e| e.to_string());
        // Rows 0–6 and columns 0–7 scan the keys; key events (not GPIO ones) raise its INT line.
        write(0x1D, 0x7F)?;
        write(0x1E, 0xFF)?;
        write(0x1F, 0x00)?;
        write(0x01, 0x01)?;
        let mut keyboard = Keyboard { i2c, fn_down: false, shift: false, ctrl: false, opt: false, alt: false };
        while keyboard.event()?.is_some() {}
        Ok(keyboard)
    }

    /// The next raw event (bit 7: pressed; the low 7 bits are the key number, from 1).
    fn event(&mut self) -> Result<Option<u8>, String> {
        let mut count = [0u8];
        self.i2c.write_read(TCA8418, &[0x03], &mut count, 50).map_err(|e| e.to_string())?;
        if count[0] & 0x0f == 0 {
            let _ = self.i2c.write(TCA8418, &[0x02, 0x01], 50);
            return Ok(None);
        }
        let mut event = [0u8];
        self.i2c.write_read(TCA8418, &[0x04], &mut event, 50).map_err(|e| e.to_string())?;
        Ok(Some(event[0]))
    }

    /// Key presses since the last call (modifiers are tracked, not returned).
    fn presses(&mut self) -> Vec<Press> {
        let mut presses = Vec::new();
        for _ in 0..16 {
            let Ok(Some(event)) = self.event() else { break };
            let pressed = event & 0x80 != 0;
            let number = (event & 0x7f).saturating_sub(1);
            let (row, column) = (number / 10, number % 10);
            // M5's remap: two scan rows to each printed column, the scan column picks the row.
            let (printed_row, printed_column) = ((column % 4) as usize, (row * 2 + u8::from(column > 3)) as usize);
            let Some(key) = LAYOUT.get(printed_row).and_then(|row| row.chars().nth(printed_column)) else { continue };
            match key {
                '\x01' => self.fn_down = pressed,
                '\x02' => self.shift = pressed,
                '\x03' => self.ctrl = pressed,
                '\x04' => self.opt = pressed,
                '\x05' => self.alt = pressed,
                _ if pressed => {
                    let key = if self.shift { SHIFTED[printed_row].chars().nth(printed_column).unwrap_or(key) } else { key };
                    presses.push(Press { key, fn_down: self.fn_down, shift: self.shift, ctrl: self.ctrl, opt: self.opt, alt: self.alt });
                }
                _ => {}
            }
        }
        presses
    }
}

// ---- the LED: one WS2812 on G21 ----

struct Led<'d> {
    channel: TxChannelDriver<'d>,
    encoder: BytesEncoder,
    shown: Option<[u8; 3]>,
}

impl<'d> Led<'d> {
    fn new(pin: impl OutputPin + 'd) -> anyhow::Result<Self> {
        let config = TxChannelConfig { resolution: 10.MHz().into(), ..Default::default() };
        let channel = TxChannelDriver::new(pin, &config)?;
        let ticks = |n| PulseTicks::new(n);
        // At 10 MHz: a 0 is 0.3 µs high then 0.9 low, a 1 the other way round.
        let bit0 = Symbol::new(Pulse::new(PinState::High, ticks(3)?), Pulse::new(PinState::Low, ticks(9)?));
        let bit1 = Symbol::new(Pulse::new(PinState::High, ticks(9)?), Pulse::new(PinState::Low, ticks(3)?));
        let encoder = BytesEncoder::with_config(&BytesEncoderConfig { bit0, bit1, msb_first: true, ..Default::default() })?;
        Ok(Led { channel, encoder, shown: None })
    }

    fn show(&mut self, color: u32, brightness: f32) {
        let scale = |shift: u32| ((((color >> shift) & 0xff) as f32) * brightness).round() as u8;
        let grb = [scale(8), scale(16), scale(0)];
        if self.shown == Some(grb) { return; }
        self.shown = Some(grb);
        if let Err(error) = self.channel.send_and_wait(&mut self.encoder, &grb, &TransmitConfig::default()) {
            warn!("CARDPUTER: LED: {error}");
        }
    }
}

// ---- what's shown, and the keys ----

/// The profile's colour: the app's, else the built-in profiles' (the app's own `builtinColors`).
fn profile_color(profile: &bandit_profiles::Profile) -> u32 {
    profile.color.unwrap_or(match profile.id.as_str() {
        "media" => 0xff616b, "slides" => 0xffb840, "write" => 0xbf80ff, "copilot" => 0x4cc9f0, "tv" => 0xa6e05a,
        _ => 0x6094ff,
    })
}

#[derive(Clone, PartialEq)]
enum Screen {
    Home,
    Help,
    /// Keys go to the active computer as typing (`fn K` again ends it).
    Typing,
    /// The band's and each device's signal strength, live (and logged): for finding how far it reaches.
    Signal,
    /// What the active profile's gestures do on the active device, a page at a time.
    Gestures(usize),
}

/// Gestures on a page of that screen.
const GESTURE_ROWS: usize = 6;

/// Signal strengths in dBm, the band's and each device's.
#[derive(Clone, PartialEq, Default)]
struct Signal {
    band: Option<i8>,
    /// The band's weakest since the signal screen opened.
    lowest: Option<i8>,
    hosts: Vec<(String, Option<i8>)>,
}

/// Bars out of 4.
fn bars(rssi: i8) -> u8 {
    match rssi { -60.. => 4, -70.. => 3, -80.. => 2, -90.. => 1, _ => 0 }
}

fn quality(rssi: i8) -> &'static str {
    match rssi { -60.. => "Great", -70.. => "Good", -80.. => "Fair", -90.. => "Weak", _ => "Very weak" }
}

/// Everything the screen draws, so it's redrawn only when this changes.
#[derive(Clone, PartialEq)]
struct View {
    screen: Screen,
    band: &'static str,
    band_battery: Option<u8>,
    /// The band's signal (dBm), in the status bar.
    band_rssi: Option<i8>,
    charging: bool,
    own_battery: Option<u8>,
    own_charging: bool,
    /// The Cardputer's battery in volts, for the help screen.
    volts: Option<f32>,
    profile: Option<(String, u32, usize, usize)>,
    host: Option<(String, Kind)>,
    hosts: usize,
    pairing: u64,
    update: Option<(u32, u32)>,
    note: Option<String>,
    /// On the signal screen.
    signal: Option<Signal>,
    /// On the gestures screen: (gesture, what it does).
    gestures: Option<Vec<(String, String)>>,
    /// While the letter menu waits: (letter, what it does).
    menu: Option<Vec<(char, String)>>,
    /// An animation frame (the live dot breathing, the search dots), while one runs.
    tick: u32,
}

struct Ui<'d> {
    remote: Remote,
    display: Display<'d>,
    frame: Frame,
    keyboard: Keyboard<'d>,
    int: Option<PinDriver<'d, Input>>,
    battery: Option<Battery<'d>>,
    led: Option<Led<'d>>,
    screen: Screen,
    /// A short message after a key did something, until it expires.
    toast: Option<(String, Instant)>,
    millivolts: Option<f32>,
    last: Option<View>,
    /// The last key or G0 press: the screen goes dark `SCREEN_ON` after it.
    touched: Instant,
    dark: bool,
    signal: Signal,
    /// When the signal was last logged.
    logged: Instant,
    battery_logged: Instant,
    /// The last five minutes' battery readings, oldest first, and whether it's on a charger.
    trend: std::collections::VecDeque<f32>,
    rising: bool,
}

/// Battery readings in the charging trend (every 10 s: five minutes).
const TREND: usize = 31;

const TOAST: Duration = Duration::from_millis(1600);
const GESTURE_SHOWN: Duration = Duration::from_secs(6);
/// How long the screen stays lit after the last key (or G0) press.
/// Letters in each of the letter menu's two columns.
const MENU_ROWS: usize = 5;
const SCREEN_ON: Duration = Duration::from_secs(10);

impl<'d> Ui<'d> {
    fn new(remote: Remote, display: Display<'d>, keyboard: Keyboard<'d>, int: Option<PinDriver<'d, Input>>,
           battery: Option<Battery<'d>>, led: Option<Led<'d>>) -> Self {
        Ui { remote, display, frame: Frame::new(), keyboard, int, battery, led, screen: Screen::Home, toast: None, millivolts: None, last: None,
             touched: Instant::now(), dark: false, signal: Signal::default(), logged: Instant::now(),
             battery_logged: Instant::now(), trend: Default::default(), rising: false }
    }

    fn run(&mut self) {
        let started = Instant::now();
        let mut next_battery = Instant::now();
        let mut next_signal = Instant::now();
        loop {
            // INT is low while key events wait; without it, ask every round.
            if self.int.as_ref().is_none_or(|int| int.is_low()) {
                for press in self.keyboard.presses() {
                    // A key in the dark only wakes the screen (no profile changes by accident),
                    // except in keyboard mode, where it's typed too.
                    let woke = self.wake();
                    if !woke || self.screen == Screen::Typing { self.key(press); }
                }
            }
            // G0 (main.rs acts on it): it wakes the screen too.
            if unsafe { esp_idf_svc::sys::gpio_get_level(0) } == 0 { self.wake(); }
            // The letter menu: a glance at the letters, so it lights the screen while it waits.
            if MENU_OPEN.load(Ordering::Relaxed) { self.wake(); }
            // Twice a second while it's watched (the signal screen, `SIGNAL on`), else for the bars.
            if Instant::now() >= next_signal {
                let watched = self.screen == Screen::Signal || control::SIGNAL_LOG.load(Ordering::Relaxed);
                next_signal = Instant::now() + if watched { Duration::from_millis(500) } else { Duration::from_secs(2) };
                self.sample_signal(watched);
            }
            // The signal screen stays lit: it's carried around.
            if !self.dark && self.touched.elapsed() >= SCREEN_ON && self.screen != Screen::Signal {
                self.dark = true;
                self.display.light(false);
            }
            if Instant::now() >= next_battery {
                next_battery = Instant::now() + Duration::from_secs(10);
                self.read_battery();
            }
            if self.dark {
                self.light();
                FreeRtos::delay_ms(20);
                continue;
            }
            let view = self.view(started.elapsed());
            if self.last.as_ref() != Some(&view) {
                // Only the animation moved: it's all in the top band (the status bar).
                let bands = match &self.last {
                    Some(last) if View { tick: view.tick, band_rssi: view.band_rssi, ..last.clone() } == view => 0..1,
                    _ => 0..HEIGHT / BAND,
                };
                if let Err(error) = self.show(&view, bands) { warn!("CARDPUTER: screen: {error}"); }
                self.last = Some(view);
            }
            self.light();
            FreeRtos::delay_ms(20);
        }
    }

    /// Counts as a touch; true when the screen was dark (it's lit again, redrawn first).
    fn wake(&mut self) -> bool {
        self.touched = Instant::now();
        if !self.dark { return false; }
        self.dark = false;
        self.last = None;
        let view = self.view(Duration::ZERO);
        if let Err(error) = self.show(&view, 0..HEIGHT / BAND) { warn!("CARDPUTER: screen: {error}"); }
        self.last = Some(view);
        self.display.light(true);
        true
    }

    fn sample_signal(&mut self, log: bool) {
        let band = control::band_rssi();
        let hosts = self.remote.hosts().into_iter().map(|host| (host.2, control::rssi(host.0))).collect();
        let lowest = match (self.signal.lowest, band) { (Some(low), Some(now)) => Some(low.min(now)), (low, now) => low.or(now) };
        self.signal = Signal { band, lowest, hosts };
        if log && self.logged.elapsed() >= Duration::from_secs(1) {
            self.logged = Instant::now();
            let dbm = |rssi: Option<i8>| rssi.map_or("-".to_string(), |rssi| format!("{rssi} dBm"));
            let hosts: String = self.signal.hosts.iter().map(|(name, rssi)| format!(", {name} {}", dbm(*rssi))).collect();
            info!("SIGNAL: band {}{hosts}", dbm(band));
        }
    }

    fn read_battery(&mut self) {
        let Some(millivolts) = self.battery.as_mut().and_then(|read| read()) else { return };
        if self.millivolts.is_none() || self.battery_logged.elapsed() >= Duration::from_secs(300) {
            self.battery_logged = Instant::now();
            info!("CARDPUTER: battery {:.2} V", millivolts / 1000.0);
        }
        // Charging, without a pin that says so: plugging a charger in lifts the battery's voltage at
        // once (and unplugging drops it), and charging climbs it slowly (~4 mV a minute from USB).
        let step = self.millivolts.map_or(0.0, |old| millivolts - old);
        let smoothed = match self.millivolts { Some(old) => old * 0.7 + millivolts * 0.3, None => millivolts };
        self.millivolts = Some(smoothed);
        self.trend.push_back(smoothed);
        if self.trend.len() > TREND { self.trend.pop_front(); }
        let rise = match (self.trend.front(), self.trend.back()) { (Some(first), Some(last)) if self.trend.len() == TREND => last - first, _ => 0.0 };
        let charging = if step > 40.0 || rise > 12.0 { true } else if step < -40.0 || rise < -6.0 { false } else { self.rising };
        if charging != self.rising {
            self.rising = charging;
            // A jump moves the trend's start too, or the old readings would undo it.
            if step.abs() > 40.0 { self.trend.clear(); self.trend.push_back(millivolts); self.millivolts = Some(millivolts); }
            info!("CARDPUTER: {} (battery {:.2} V, {step:+.0} mV just now, {rise:+.0} mV in 5 minutes)",
                  if charging { "charging" } else { "not charging" }, millivolts / 1000.0);
        }
    }

    /// On a charger: a computer on the USB port, or the battery climbing.
    fn own_charging(&self) -> bool {
        self.rising || unsafe { esp_idf_svc::sys::usb_serial_jtag_is_connected() }
    }

    fn own_battery(&self) -> Option<u8> {
        let millivolts = self.millivolts?;
        // A Li-ion cell, roughly: 3.3 V empty, 4.15 V full.
        Some(((millivolts - 3300.0) / (4150.0 - 3300.0) * 100.0).clamp(0.0, 100.0) as u8)
    }

    fn view(&mut self, uptime: Duration) -> View {
        let band = control::band();
        let state = if control::paused() { "paused" } else { band.state };
        let active = self.remote.active_profile();
        let profile = active.as_ref().map(|(set, index, _)| {
            let profile = &set.profiles[*index];
            (profile.name.clone(), profile_color(profile), *index, set.profiles.len())
        });
        let hosts = self.remote.hosts();
        let host = hosts.iter().find(|host| host.3).map(|host| (host.2.clone(), host.1));
        let update = crate::ota::progress();
        let update = (update.state == "receiving" || update.state == "verifying").then_some((update.got, update.of.max(1)));
        if self.toast.as_ref().is_some_and(|(_, at)| at.elapsed() > TOAST) { self.toast = None; }
        let note = self.toast.as_ref().map(|(text, _)| text.clone()).or_else(|| {
            GESTURE.lock().unwrap().as_ref().filter(|(_, at)| at.elapsed() < GESTURE_SHOWN).map(|(text, _)| text.clone())
        });
        let animating = matches!(state, "live" | "searching" | "connecting");
        View {
            screen: self.screen.clone(),
            band: state,
            band_battery: band.battery,
            band_rssi: self.signal.band.filter(|_| state == "live"),
            charging: band.charging == Some(true),
            own_battery: self.own_battery(),
            own_charging: self.own_charging(),
            volts: self.millivolts.map(|mv| (mv / 10.0).round() / 100.0),
            profile,
            host,
            hosts: hosts.len(),
            pairing: self.remote.pairing_seconds(),
            update,
            note,
            signal: (self.screen == Screen::Signal).then(|| self.signal.clone()),
            gestures: matches!(self.screen, Screen::Gestures(_)).then(|| active.as_ref()
                .map(|(set, index, kind)| gesture_rows(&set.profiles[*index], kind.host_kind())).unwrap_or_default()),
            menu: MENU_OPEN.load(Ordering::Relaxed).then(|| crate::profiles::current().menu.iter()
                .map(|(letter, action)| (letter.to_ascii_uppercase(), action_name(action))).collect()),
            tick: if animating { (uptime.as_millis() / 500) as u32 } else { 0 },
        }
    }

    fn toast(&mut self, text: impl Into<String>) { self.toast = Some((text.into(), Instant::now())); }

    fn key(&mut self, press: Press) {
        if press.fn_down && press.key.eq_ignore_ascii_case(&'k') {
            self.screen = if self.screen == Screen::Typing { Screen::Home } else { Screen::Typing };
            self.toast(if self.screen == Screen::Typing { "Keyboard on" } else { "Keyboard off" });
            return;
        }
        match self.screen {
            Screen::Typing => self.type_key(press),
            Screen::Help | Screen::Signal => self.screen = Screen::Home,
            Screen::Gestures(page) => self.gestures_key(press, page),
            Screen::Home => self.shortcut(press),
        }
    }

    /// The keys on the home screen.
    fn shortcut(&mut self, press: Press) {
        let remote = self.remote.clone();
        match press.key.to_ascii_lowercase() {
            key @ (',' | '<' | '/') if !(key == '/' && press.shift) => {
                let target = if key == '/' { bandit_profiles::ProfileTarget::Next } else { bandit_profiles::ProfileTarget::Previous };
                if let Err(error) = remote.set_profile(None, target) { self.toast(error) }
            }
            digit @ '1'..='9' => {
                let index = digit as usize - '1' as usize;
                let set = crate::profiles::current();
                match set.profiles.get(index) {
                    Some(target) => if let Err(error) = remote.set_profile_id(None, &target.id) { self.toast(error) },
                    None => self.toast(format!("No profile {}", index + 1)),
                }
            }
            '\t' => if !remote.step(!press.shift) { self.toast("No device connected") },
            ' ' => { remote.send(Action::Media(MediaKey::PlayPause)); self.toast("Play/Pause"); }
            ';' | ':' => { remote.send(Action::Media(MediaKey::VolumeUp)); self.toast("Volume up"); }
            '.' | '>' => { remote.send(Action::Media(MediaKey::VolumeDown)); self.toast("Volume down"); }
            '[' | '{' => { remote.send(Action::Media(MediaKey::Previous)); self.toast("Previous track"); }
            ']' | '}' => { remote.send(Action::Media(MediaKey::Next)); self.toast("Next track"); }
            'p' => {
                let paused = !control::PAUSED.fetch_xor(true, Ordering::SeqCst);
                info!("CARDPUTER: band link {}", if paused { "PAUSED (band released for the phone app)" } else { "resumed" });
                self.toast(if paused { "Band released" } else { "Band back" });
            }
            'b' => { remote.alert(Alert::Done); self.toast("Buzzing the band"); }
            'a' => { remote.open_pairing(Some(Kind::Mac)); self.toast("Pairing a computer"); }
            'i' => { remote.open_pairing(Some(Kind::Phone)); self.toast("Pairing a phone"); }
            '`' | '~' if remote.pairing_seconds() > 0 => { remote.open_pairing(None); self.toast("Pairing closed"); }
            'k' => {
                self.screen = Screen::Typing;
                self.toast("Keyboard on");
            }
            'h' | '?' => self.screen = Screen::Help,
            'g' => self.screen = Screen::Gestures(0),
            's' => {
                self.signal.lowest = None;
                self.screen = Screen::Signal;
            }
            _ => {}
        }
    }

    /// The gestures screen: `;` `,` back a page, `.` `/` `G` on (round to the first), any other key closes.
    fn gestures_key(&mut self, press: Press, page: usize) {
        let rows = self.remote.active_profile()
            .map(|(set, index, kind)| gesture_rows(&set.profiles[index], kind.host_kind()).len()).unwrap_or(0);
        let pages = rows.div_ceil(GESTURE_ROWS).max(1);
        self.screen = match press.key.to_ascii_lowercase() {
            ';' | ':' | ',' | '<' => Screen::Gestures((page + pages - 1) % pages),
            '.' | '>' | '/' | '?' | 'g' => Screen::Gestures((page + 1) % pages),
            _ => Screen::Home,
        };
    }

    /// Typing mode: the key, with its modifiers, to the active computer. Not logged (it could be
    /// a password).
    fn type_key(&mut self, press: Press) {
        let usage = if press.fn_down {
            match press.key {
                '`' | '~' => Some(0x29), // escape
                '\x08' => Some(0x4C),     // delete
                ';' | ':' => Some(0x52),  // up
                ',' | '<' => Some(0x50),  // left
                '.' | '>' => Some(0x51),  // down
                '/' | '?' => Some(0x4F),  // right
                c => "1234567890-=".find(c).or_else(|| "!@#$%^&*()_+".find(c)).map(|n| 0x3A + n as u8), // F1–F12
            }.map(|usage| (0, usage))
        } else {
            match press.key {
                '\x08' => Some((0, keys::BACKSPACE)),
                '\n' => Some((0, keys::ENTER)),
                '\t' => Some((0, keys::TAB)),
                c => keys::for_char(c),
            }
        };
        let Some((modifiers, usage)) = usage else { return };
        let mut modifiers = modifiers | if press.shift { keys::SHIFT } else { 0 };
        if press.ctrl { modifiers |= keys::CTRL; }
        if press.alt { modifiers |= keys::ALT; }
        if press.opt { modifiers |= keys::GUI; }
        if !self.remote.press_key(modifiers, usage) { self.toast("No computer to type on"); }
    }

    fn light(&mut self) {
        let Some(led) = self.led.as_mut() else { return };
        let Some(view) = self.last.as_ref() else { return };
        let color = view.profile.as_ref().map(|p| p.1).unwrap_or(0x6094ff);
        let flash = GESTURE.lock().unwrap().as_ref().is_some_and(|(_, at)| at.elapsed() < Duration::from_millis(180));
        let (color, brightness) = if view.band == "paused" || view.band == "no-owner" {
            (0, 0.0)
        } else if flash {
            (color, 0.5)
        } else {
            (color, 0.06)
        };
        led.show(color, brightness);
    }

    // ---- drawing ----

    fn show(&mut self, view: &View, bands: std::ops::Range<usize>) -> anyhow::Result<()> {
        self.display.begin((bands.start * BAND) as u16, (bands.end * BAND) as u16)?;
        for band in bands {
            self.frame.top = (band * BAND) as i32;
            self.draw(view);
            self.display.send(&self.frame)?;
        }
        Ok(())
    }

    fn draw(&mut self, view: &View) {
        let accent = view.profile.as_ref().map(|p| p.1).unwrap_or(0x6094ff);
        self.frame.set_accent(accent);
        self.frame.clear(BG);
        self.status_bar(view);
        if view.menu.is_some() { return self.menu(view); }
        match view.screen {
            Screen::Help => return self.help(view),
            Screen::Signal => return self.signal(view),
            Screen::Gestures(page) => return self.gestures(view, page),
            Screen::Typing => self.typing(view),
            Screen::Home => self.home(view),
        }
        self.footer(view);
    }

    fn status_bar(&mut self, view: &View) {
        let f = &mut self.frame;
        let (dot, label) = match view.band {
            "live" => (GREEN, "Band".to_string()),
            "searching" | "connecting" => (AMBER, format!("Looking for band{}", ".".repeat((view.tick % 4) as usize))),
            "paused" => (DIM, "Band released".into()),
            "no-owner" => (RED, "No owner key".into()),
            other => (AMBER, other.to_string()),
        };
        // The live dot breathes (every 2 s).
        let radius = if view.band == "live" && view.tick % 4 >= 2 { 4 } else { 3 };
        if view.band == "live" { f.disc(9, 8, 6, HALO); }
        f.disc(9, 8, radius, dot);
        let mut x = 19;
        x += f.text::<fonts::u8g2_font_helvB10_tr>(&label, x, 13, HorizontalAlignment::Left, TEXT);
        if let (Some(level), "live") = (view.band_battery, view.band) {
            x += f.text::<fonts::u8g2_font_helvR10_tr>(&format!(" {level}%"), x, 13, HorizontalAlignment::Left, if level <= 15 && !view.charging { RED } else { DIM });
            if view.charging {
                f.bolt(x + 3, 5, AMBER);
                x += 8;
            }
        }
        if let Some(rssi) = view.band_rssi {
            f.bars(x + 7, 13, bars(rssi), 1);
            f.text::<fonts::u8g2_font_helvR08_tr>(&rssi.to_string(), x + 22, 13, HorizontalAlignment::Left, DIM);
        }
        // The Cardputer's own battery, at the right.
        if let Some(level) = view.own_battery {
            let (bx, by, bw, bh) = (WIDTH as i32 - 24, 4, 18, 9);
            f.rounded(bx, by, bw, bh, 2, LINE);
            f.fill(bx + bw, by + 3, 2, 3, LINE);
            let inner = ((bw - 4) * i32::from(level) / 100).max(1);
            let low = level <= 15 && !view.own_charging;
            f.fill(bx + 2, by + 2, inner, bh - 4, if low { RED } else { TEXT });
            let mut right = bx - 4;
            if view.own_charging {
                f.bolt(right - 5, 4, AMBER);
                right -= 8;
            }
            f.text::<fonts::u8g2_font_helvR08_tr>(&format!("{level}%"), right, 12, HorizontalAlignment::Right, DIM);
        }
    }

    fn home(&mut self, view: &View) {
        let f = &mut self.frame;
        let (x, y, w, h) = (6, 21, WIDTH as i32 - 12, 80);
        // The glow, then the card.
        f.rounded(x - 3, y - 3, w + 6, h + 6, 14, HALO);
        f.rounded(x, y, w, h, 11, MID);
        f.rounded(x + 1, y + 1, w - 2, h - 2, 10, DEEP);
        if let Some((got, of)) = view.update {
            f.text::<fonts::u8g2_font_helvB08_tr>("UPDATING FIRMWARE", x + 12, y + 16, HorizontalAlignment::Left, LIGHT);
            let percent = (u64::from(got) * 100 / u64::from(of)) as i32;
            f.text::<fonts::u8g2_font_fub20_tr>(&format!("{percent}%"), x + 12, y + 46, HorizontalAlignment::Left, WHITE);
            f.rounded(x + 12, y + 58, w - 24, 8, 4, SHADOW);
            f.rounded(x + 12, y + 58, ((w - 24) * percent / 100).max(8), 8, 4, ACCENT);
            return;
        }
        let (headline, label, detail) = match (&view.profile, &view.host, view.band) {
            (_, _, "no-owner") => ("No owner key".to_string(), "SET UP".to_string(), "Send OWNER over USB (README)".to_string()),
            (_, _, "paused") => ("Band released".to_string(), "PAUSED".to_string(), "P or G0 takes it back".to_string()),
            (Some((name, _, index, count)), Some((host, kind)), _) => {
                let kind = match kind { Kind::Phone => "phone", Kind::Tv => "TV", _ => "computer" };
                (name.clone(), format!("PROFILE {}/{count}", index + 1), format!("on {host}  ({kind})"))
            }
            _ => ("No device".to_string(), "HOSTS".to_string(), "A pairs a computer, I a phone".to_string()),
        };
        f.text::<fonts::u8g2_font_helvB08_tr>(&label, x + 12, y + 16, HorizontalAlignment::Left, LIGHT);
        // The profile's position, as dots at the top right.
        if let Some((_, _, index, count)) = view.profile.as_ref().filter(|_| view.host.is_some()) {
            let count = (*count).min(9) as i32;
            for dot in 0..count {
                let cx = x + w - 14 - (count - 1 - dot) * 9;
                if dot as usize == *index { f.disc(cx, y + 12, 3, ACCENT) } else { f.disc(cx, y + 12, 2, MID) }
            }
        }
        let name = if text_width::<fonts::u8g2_font_fub20_tr>(&headline) <= w - 40 {
            f.text::<fonts::u8g2_font_fub20_tr>(&headline, x + 12, y + 47, HorizontalAlignment::Left, WHITE);
            None
        } else {
            Some(fit::<fonts::u8g2_font_fub14_tr>(&headline, w - 40))
        };
        if let Some(name) = name { f.text::<fonts::u8g2_font_fub14_tr>(&name, x + 12, y + 45, HorizontalAlignment::Left, WHITE); }
        let detail = fit::<fonts::u8g2_font_helvR10_tr>(&detail, w - 24);
        f.text::<fonts::u8g2_font_helvR10_tr>(&detail, x + 12, y + 67, HorizontalAlignment::Left, LIGHT);
        // ‹ › at the card's edge: , and / switch profile.
        if view.host.is_some() && view.profile.is_some() && !matches!(view.band, "paused" | "no-owner") {
            f.arrow(x + w - 14, y + 44, 10, true, LIGHT);
            f.arrow(x + w - 26, y + 44, 10, false, MID);
        }
    }

    fn typing(&mut self, view: &View) {
        let f = &mut self.frame;
        let (x, y, w, h) = (6, 21, WIDTH as i32 - 12, 80);
        f.rounded(x, y, w, h, 11, LINE);
        f.rounded(x + 1, y + 1, w - 2, h - 2, 10, CARD);
        f.text::<fonts::u8g2_font_helvB08_tr>("KEYBOARD", x + 12, y + 16, HorizontalAlignment::Left, ACCENT);
        let (headline, detail) = match &view.host {
            Some((host, kind)) if kind.keyboard() => (format!("Typing on {host}"), "opt is cmd, fn+;,./ are arrows"),
            Some(_) => ("A phone has no keyboard".to_string(), "Tab to a computer first"),
            None => ("No device".to_string(), "Connect a computer first"),
        };
        let headline = fit::<fonts::u8g2_font_fub14_tr>(&headline, w - 24);
        f.text::<fonts::u8g2_font_fub14_tr>(&headline, x + 12, y + 44, HorizontalAlignment::Left, WHITE);
        f.text::<fonts::u8g2_font_helvR10_tr>(detail, x + 12, y + 64, HorizontalAlignment::Left, DIM);
        f.fill(x + w - 20, y + 30, 3, 18, ACCENT);
    }

    fn help(&mut self, view: &View) {
        let f = &mut self.frame;
        // Left of the battery.
        f.text::<fonts::u8g2_font_helvB10_tr>("Keys", WIDTH as i32 - 62, 13, HorizontalAlignment::Right, ACCENT);
        let rows = [
            (", /", "profile", "tab", "device"),
            ("1-9", "go to profile", "space", "play/pause"),
            ("; .", "volume", "[ ]", "track"),
            ("P", "release band", "B", "buzz band"),
            ("A", "pair computer", "I", "pair phone"),
            ("G", "gestures", "S", "signal"),
            ("fn K", "keyboard mode", "esc", "end pairing"),
        ];
        for (i, (k1, a1, k2, a2)) in rows.iter().enumerate() {
            let y = 32 + i as i32 * 14;
            f.text::<fonts::u8g2_font_helvB10_tr>(k1, 8, y, HorizontalAlignment::Left, ACCENT);
            f.text::<fonts::u8g2_font_helvR10_tr>(a1, 40, y, HorizontalAlignment::Left, TEXT);
            f.text::<fonts::u8g2_font_helvB10_tr>(k2, 132, y, HorizontalAlignment::Left, ACCENT);
            f.text::<fonts::u8g2_font_helvR10_tr>(a2, 170, y, HorizontalAlignment::Left, TEXT);
        }
        let footer = match view.volts {
            Some(volts) => format!("any key to close      battery {volts:.2} V"),
            None => "any key to close".to_string(),
        };
        f.text::<fonts::u8g2_font_helvR08_tr>(&footer, WIDTH as i32 / 2, 131, HorizontalAlignment::Center, DIM);
    }

    /// The letter menu, over whatever screen is up: two columns of letters and what they run.
    fn menu(&mut self, view: &View) {
        let Some(rows) = view.menu.as_ref() else { return };
        let f = &mut self.frame;
        f.text::<fonts::u8g2_font_helvB08_tr>("LETTER MENU", 8, 32, HorizontalAlignment::Left, LIGHT);
        if rows.is_empty() {
            f.text::<fonts::u8g2_font_helvR10_tr>("No letters in this profile set", 8, 56, HorizontalAlignment::Left, DIM);
        }
        let per_column = rows.len().div_ceil(2).clamp(1, MENU_ROWS);
        for (i, (letter, action)) in rows.iter().take(2 * MENU_ROWS).enumerate() {
            let (x, y) = (8 + (i / per_column) as i32 * 116, 50 + (i % per_column) as i32 * 16);
            f.text::<fonts::u8g2_font_helvB10_tr>(&letter.to_string(), x, y, HorizontalAlignment::Left, ACCENT);
            f.text::<fonts::u8g2_font_helvR10_tr>(&fit::<fonts::u8g2_font_helvR10_tr>(action, 94), x + 16, y, HorizontalAlignment::Left, TEXT);
        }
        f.text::<fonts::u8g2_font_helvR08_tr>("write a letter in the air", WIDTH as i32 / 2, 133, HorizontalAlignment::Center, DIM);
    }

    fn gestures(&mut self, view: &View, page: usize) {
        let Some(rows) = view.gestures.as_ref() else { return };
        let f = &mut self.frame;
        let name = view.profile.as_ref().map_or(String::new(), |profile| profile.0.to_uppercase());
        f.text::<fonts::u8g2_font_helvB08_tr>(&fit::<fonts::u8g2_font_helvB08_tr>(&format!("GESTURES   {name}"), 180), 8, 32, HorizontalAlignment::Left, LIGHT);
        let pages = rows.len().div_ceil(GESTURE_ROWS).max(1);
        let page = page.min(pages - 1);
        if pages > 1 {
            f.text::<fonts::u8g2_font_helvR08_tr>(&format!("{}/{pages}", page + 1), WIDTH as i32 - 8, 32, HorizontalAlignment::Right, DIM);
        }
        if rows.is_empty() {
            let text = if view.host.is_some() { "Nothing bound here" } else { "No device connected" };
            f.text::<fonts::u8g2_font_helvR10_tr>(text, 8, 56, HorizontalAlignment::Left, DIM);
        }
        for (i, (gesture, action)) in rows.iter().skip(page * GESTURE_ROWS).take(GESTURE_ROWS).enumerate() {
            let y = 48 + i as i32 * 14;
            f.text::<fonts::u8g2_font_helvB10_tr>(&fit::<fonts::u8g2_font_helvB10_tr>(gesture, 96), 8, y, HorizontalAlignment::Left, ACCENT);
            f.text::<fonts::u8g2_font_helvR10_tr>(&fit::<fonts::u8g2_font_helvR10_tr>(action, 126), 108, y, HorizontalAlignment::Left, TEXT);
        }
        let hint = if pages > 1 { "; .  more      any other key closes" } else { "any key closes" };
        f.text::<fonts::u8g2_font_helvR08_tr>(hint, WIDTH as i32 / 2, 133, HorizontalAlignment::Center, DIM);
    }

    fn signal(&mut self, view: &View) {
        let Some(signal) = view.signal.as_ref() else { return };
        let f = &mut self.frame;
        let (x, y, w, h) = (6, 21, WIDTH as i32 - 12, 54);
        f.rounded(x, y, w, h, 10, CARD);
        f.text::<fonts::u8g2_font_helvB08_tr>("BAND SIGNAL", x + 10, y + 14, HorizontalAlignment::Left, DIM);
        match signal.band {
            Some(rssi) => {
                let width = f.text::<fonts::u8g2_font_fub20_tr>(&rssi.to_string(), x + 10, y + 44, HorizontalAlignment::Left, WHITE);
                f.text::<fonts::u8g2_font_helvR10_tr>("dBm", x + 15 + width, y + 44, HorizontalAlignment::Left, DIM);
                let level = bars(rssi);
                f.text::<fonts::u8g2_font_helvB10_tr>(quality(rssi), x + w - 50, y + 30, HorizontalAlignment::Right,
                                                      match level { 3.. => GREEN, 2 => AMBER, _ => RED });
                if let Some(lowest) = signal.lowest {
                    f.text::<fonts::u8g2_font_helvR08_tr>(&format!("lowest {lowest}"), x + w - 50, y + 44, HorizontalAlignment::Right, DIM);
                }
                f.bars(x + w - 43, y + 44, level, 3);
            }
            None => {
                let text = if view.band == "paused" { "Band released" } else { "Band not connected" };
                f.text::<fonts::u8g2_font_fub14_tr>(text, x + 10, y + 42, HorizontalAlignment::Left, DIM);
            }
        }
        if signal.hosts.is_empty() {
            f.text::<fonts::u8g2_font_helvR10_tr>("No devices connected", 10, y + h + 16, HorizontalAlignment::Left, DIM);
        }
        for (i, (name, rssi)) in signal.hosts.iter().take(3).enumerate() {
            let row = y + h + 16 + i as i32 * 15;
            f.text::<fonts::u8g2_font_helvR10_tr>(&fit::<fonts::u8g2_font_helvR10_tr>(name, 130), 10, row, HorizontalAlignment::Left, TEXT);
            match rssi {
                Some(rssi) => {
                    f.text::<fonts::u8g2_font_helvB10_tr>(&format!("{rssi} dBm"), 198, row, HorizontalAlignment::Right, TEXT);
                    f.bars(207, row, bars(*rssi), 1);
                }
                None => { f.text::<fonts::u8g2_font_helvR10_tr>("-", 198, row, HorizontalAlignment::Right, DIM); }
            }
        }
        f.text::<fonts::u8g2_font_helvR08_tr>("any key closes", WIDTH as i32 / 2, 133, HorizontalAlignment::Center, DIM);
    }

    fn footer(&mut self, view: &View) {
        let f = &mut self.frame;
        let y = 118;
        // A pairing window (one is open for 2 minutes after power-up) says so here, under a note.
        let pairing = (view.pairing > 0 && view.screen == Screen::Home)
            .then(|| format!("Pairing open {} s    esc closes", view.pairing));
        match (&view.note, pairing) {
            (None, Some(pairing)) => {
                f.rounded(6, y - 12, WIDTH as i32 - 12, 24, 8, CARD);
                f.fill(12, y - 6, 3, 12, AMBER);
                let pairing = fit::<fonts::u8g2_font_helvB10_tr>(&pairing, WIDTH as i32 - 34);
                f.text::<fonts::u8g2_font_helvB10_tr>(&pairing, 22, y + 4, HorizontalAlignment::Left, AMBER);
            }
            (Some(note), _) => {
                f.rounded(6, y - 12, WIDTH as i32 - 12, 24, 8, CARD);
                f.fill(12, y - 6, 3, 12, ACCENT);
                let note = fit::<fonts::u8g2_font_helvB10_tr>(note, WIDTH as i32 - 34);
                f.text::<fonts::u8g2_font_helvB10_tr>(&note, 22, y + 4, HorizontalAlignment::Left, TEXT);
            }
            (None, None) => {
                let hint = match view.screen {
                    Screen::Typing => "fn K stops typing",
                    _ if view.hosts > 1 => ", /  profile   tab  device   G  gestures   H  keys",
                    _ => ", /  profile    G  gestures    H  keys",
                };
                let hint = fit::<fonts::u8g2_font_helvR08_tr>(hint, WIDTH as i32 - 8);
                f.text::<fonts::u8g2_font_helvR08_tr>(&hint, WIDTH as i32 / 2, y + 4, HorizontalAlignment::Center, DIM);
            }
        }
    }
}
