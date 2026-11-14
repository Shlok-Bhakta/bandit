//! Gesture profiles for the band dongle: what each gesture does, per profile and per kind of
//! host, and what the letter menu's letters do. The format is `np-profiles` JSON, version 1
//! (PROFILES.md); the Neural Playground Dongle app edits it and sends it to the dongle, which
//! checks it again here before saving it.
//!
//! Pure Rust (serde), so the dongle, its host tests and the app's test vectors share one reading.

use std::collections::BTreeMap;
use std::fmt;

use serde::Deserialize;
use serde_json::Value;

pub const FORMAT: &str = "np-profiles";
pub const VERSION: u64 = 1;
/// The largest file the dongle keeps (it lives in NVS beside the Bluetooth bonds), minified.
pub const MAX_BYTES: usize = 6144;
pub const MAX_PROFILES: usize = 12;
/// `write` with no time: handwriting stops after this many seconds with nothing written.
pub const WRITE_SECONDS: u8 = 10;
/// Apps one profile may list.
pub const MAX_APPS: usize = 16;
/// The built-in profiles: what the dongle does with no file of yours (and what `profiles reset` restores).
pub const DEFAULT_JSON: &str = include_str!("../profiles/default.json");
/// Taps of one finger closer together than this count as one double or triple tap.
pub const TAP_WINDOW: f64 = 0.4;

/// What kind of host gestures are going to (the dongle's `Kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HostKind { Phone, Mac, Windows, Linux, Tv }

impl HostKind {
    pub fn is_computer(self) -> bool { matches!(self, HostKind::Mac | HostKind::Windows | HostKind::Linux) }
}

/// A set of hosts named in a file: `phone`, `computer` (any of the three), `mac`, `windows`, `linux`, `tv`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Hosts { Phone, Computer, Mac, Windows, Linux, Tv }

impl Hosts {
    pub const ALL: [Hosts; 6] = [Hosts::Phone, Hosts::Computer, Hosts::Mac, Hosts::Windows, Hosts::Linux, Hosts::Tv];

    pub fn name(self) -> &'static str {
        match self {
            Hosts::Phone => "phone", Hosts::Computer => "computer", Hosts::Mac => "mac",
            Hosts::Windows => "windows", Hosts::Linux => "linux", Hosts::Tv => "tv",
        }
    }

    pub fn from_name(name: &str) -> Option<Hosts> { Hosts::ALL.into_iter().find(|h| h.name() == name) }

    pub fn matches(self, kind: HostKind) -> bool {
        match self {
            Hosts::Phone => kind == HostKind::Phone,
            Hosts::Computer => kind.is_computer(),
            Hosts::Mac => kind == HostKind::Mac,
            Hosts::Windows => kind == HostKind::Windows,
            Hosts::Linux => kind == HostKind::Linux,
            Hosts::Tv => kind == HostKind::Tv,
        }
    }

    /// Exact kinds win over `computer` when one binding names both.
    fn specific(self) -> bool { self != Hosts::Computer }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Finger { Index, Middle }

/// Everything a profile can bind.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Gesture {
    IndexTap, IndexDoubleTap, IndexTripleTap,
    /// Pinch, hold and let go without turning (or moving the pointer).
    IndexHold,
    MiddleTap, MiddleDoubleTap, MiddleTripleTap,
    /// Held as long as the middle finger is (a `hold:` chord is released with it).
    MiddleHold,
    SwipeUp, SwipeDown, SwipeLeft, SwipeRight,
    /// Pinch and turn the wrist, one detent clockwise / anticlockwise (as seen looking at the back of the hand).
    DialCw, DialCcw,
}

impl Gesture {
    pub const ALL: [Gesture; 14] = [
        Gesture::IndexTap, Gesture::IndexDoubleTap, Gesture::IndexTripleTap, Gesture::IndexHold,
        Gesture::MiddleTap, Gesture::MiddleDoubleTap, Gesture::MiddleTripleTap, Gesture::MiddleHold,
        Gesture::SwipeUp, Gesture::SwipeDown, Gesture::SwipeLeft, Gesture::SwipeRight,
        Gesture::DialCw, Gesture::DialCcw,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Gesture::IndexTap => "index.tap", Gesture::IndexDoubleTap => "index.doubleTap",
            Gesture::IndexTripleTap => "index.tripleTap", Gesture::IndexHold => "index.hold",
            Gesture::MiddleTap => "middle.tap", Gesture::MiddleDoubleTap => "middle.doubleTap",
            Gesture::MiddleTripleTap => "middle.tripleTap", Gesture::MiddleHold => "middle.hold",
            Gesture::SwipeUp => "swipe.up", Gesture::SwipeDown => "swipe.down",
            Gesture::SwipeLeft => "swipe.left", Gesture::SwipeRight => "swipe.right",
            Gesture::DialCw => "dial.cw", Gesture::DialCcw => "dial.ccw",
        }
    }

    pub fn from_name(name: &str) -> Option<Gesture> { Gesture::ALL.into_iter().find(|g| g.name() == name) }

    /// A finger's tap count as a gesture (1–3).
    pub fn taps(finger: Finger, count: u8) -> Option<Gesture> {
        Some(match (finger, count) {
            (Finger::Index, 1) => Gesture::IndexTap, (Finger::Index, 2) => Gesture::IndexDoubleTap,
            (Finger::Index, 3) => Gesture::IndexTripleTap, (Finger::Middle, 1) => Gesture::MiddleTap,
            (Finger::Middle, 2) => Gesture::MiddleDoubleTap, (Finger::Middle, 3) => Gesture::MiddleTripleTap,
            _ => return None,
        })
    }

    fn tap_count(self) -> Option<(Finger, u8)> {
        Some(match self {
            Gesture::IndexTap => (Finger::Index, 1), Gesture::IndexDoubleTap => (Finger::Index, 2),
            Gesture::IndexTripleTap => (Finger::Index, 3), Gesture::MiddleTap => (Finger::Middle, 1),
            Gesture::MiddleDoubleTap => (Finger::Middle, 2), Gesture::MiddleTripleTap => (Finger::Middle, 3),
            _ => return None,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Media { PlayPause, Next, Previous, VolumeUp, VolumeDown, Mute, Voice }

impl Media {
    const NAMES: [(&'static str, Media); 7] = [
        ("playPause", Media::PlayPause), ("next", Media::Next), ("previous", Media::Previous),
        ("volumeUp", Media::VolumeUp), ("volumeDown", Media::VolumeDown), ("mute", Media::Mute), ("voice", Media::Voice),
    ];
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button { Left, Right, Middle }

/// A phone call on an iPhone (its notifications' actions, through ANCS).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Call {
    /// Answers the ringing call.
    Answer,
    /// Declines the ringing call, else hangs up the one in progress.
    End,
}

/// A key with modifiers, as HID usages (keyboard page 0x07). `cmd` is GUI: the dongle sends it as
/// Ctrl to Windows and Linux.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Chord { pub modifiers: u8, pub usage: u8 }

pub mod modifiers {
    pub const CTRL: u8 = 0x01;
    pub const SHIFT: u8 = 0x02;
    pub const ALT: u8 = 0x04;
    pub const GUI: u8 = 0x08;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProfileTarget { Index(usize), Next, Previous }

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostTarget { Next, Previous, Kind(Hosts) }

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    /// Explicitly nothing (a host-specific "none" beats the profile's default).
    None,
    Media(Media),
    /// The headset phone-mute button (phones).
    PhoneMute,
    /// A call on an iPhone.
    Call(Call),
    Key(Chord),
    /// Pressed while the gesture is held (`middle.hold` only), released with it.
    Hold(Chord),
    /// Typed text (ASCII, US layout).
    Type(String),
    Click(Button),
    /// Wheel steps, up positive.
    Scroll(i8),
    Profile(ProfileTarget),
    Host(HostTarget),
    /// The letter menu: write one letter next.
    Menu,
    /// Handwriting on, typed on the host, until nothing is written for this many seconds.
    Write(u8),
}

/// What one gesture does: a default, and variants for kinds of host.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Binding {
    pub default: Option<Action>,
    pub variants: Vec<(Hosts, Action)>,
}

impl Binding {
    /// The action for `kind`: an exact kind's variant, then `computer`'s, then the default.
    pub fn resolve(&self, kind: HostKind) -> Option<&Action> {
        let pick = |specific: bool| self.variants.iter()
            .find(|(hosts, _)| hosts.specific() == specific && hosts.matches(kind)).map(|(_, a)| a);
        pick(true).or_else(|| pick(false)).or(self.default.as_ref()).filter(|a| **a != Action::None)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Profile {
    pub id: String,
    pub name: String,
    /// Short buzzes when switching to it (1–4), so you can tell where you landed.
    pub buzz: u8,
    /// Who may use it (empty: everyone).
    pub hosts: Vec<Hosts>,
    /// The band's handwriting is typed (computers).
    pub typing: bool,
    /// A pinch held and moved is the mouse pointer (computers); the dial is off.
    pub pointer: bool,
    pub gestures: BTreeMap<Gesture, Binding>,
    /// Computer apps (Mac bundle ids) that switch a computer to this profile while in front.
    pub apps: Vec<String>,
}

impl Profile {
    pub fn allows(&self, kind: HostKind) -> bool { self.hosts.is_empty() || self.hosts.iter().any(|h| h.matches(kind)) }

    pub fn action(&self, gesture: Gesture, kind: HostKind) -> Option<&Action> {
        self.gestures.get(&gesture).and_then(|binding| binding.resolve(kind))
    }

    /// The highest tap count bound for `finger` on `kind` (0: none), which decides how long a tap waits.
    pub fn max_taps(&self, finger: Finger, kind: HostKind) -> u8 {
        self.gestures.iter()
            .filter_map(|(gesture, binding)| gesture.tap_count().filter(|(f, _)| *f == finger).map(|(_, n)| (n, binding)))
            .filter(|(_, binding)| binding.resolve(kind).is_some())
            .map(|(n, _)| n).max().unwrap_or(0)
    }

    /// Whether a pinch hold needs wrist motion here (the pointer, or a bound dial).
    pub fn uses_motion(&self, kind: HostKind) -> bool {
        (self.pointer && kind.is_computer()) || self.action(Gesture::DialCw, kind).is_some() || self.action(Gesture::DialCcw, kind).is_some()
    }

    pub fn types(&self, kind: HostKind) -> bool { self.typing && kind.is_computer() }
    pub fn points(&self, kind: HostKind) -> bool { self.pointer && kind.is_computer() }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProfileSet {
    pub name: String,
    pub profiles: Vec<Profile>,
    /// The letter menu: letter → action.
    pub menu: BTreeMap<char, Action>,
    /// The profile a host starts with, by kind: phone, computer, tv.
    pub start: [usize; 3],
}

impl ProfileSet {
    pub fn builtin() -> ProfileSet { ProfileSet::parse(DEFAULT_JSON).expect("the built-in profiles are valid") }

    pub fn index_of(&self, id: &str) -> Option<usize> { self.profiles.iter().position(|p| p.id == id) }

    /// The profile that lists `app` (ignoring case), if this kind of host may use it.
    pub fn for_app(&self, app: &str, kind: HostKind) -> Option<usize> {
        self.profiles.iter().position(|p| p.apps.iter().any(|a| a.eq_ignore_ascii_case(app))).filter(|&i| self.profiles[i].allows(kind))
    }

    /// The profile a new host of this kind starts with.
    pub fn start_for(&self, kind: HostKind) -> usize {
        self.start[match kind { HostKind::Phone => 0, HostKind::Tv => 2, _ => 1 }]
    }

    /// `next`/`previous` from `current`, skipping profiles this host can't use.
    pub fn step(&self, current: usize, forward: bool, kind: HostKind) -> Option<usize> {
        let n = self.profiles.len();
        (1..n).map(|i| if forward { (current + i) % n } else { (current + n - i) % n })
            .find(|&i| self.profiles[i].allows(kind))
    }

    pub fn parse(text: &str) -> Result<ProfileSet, Error> {
        if text.len() > MAX_BYTES {
            return Err(Error::new("", format!("{} bytes is too big (at most {MAX_BYTES}, minified)", text.len())));
        }
        let raw: RawFile = serde_json::from_str(text).map_err(|e| Error::new("", format!("not np-profiles JSON: {e}")))?;
        raw.check()
    }
}

/// A problem with a file, and where (`profiles[2].gestures.swipe.up`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error { pub path: String, pub message: String }

impl Error {
    fn new(path: impl Into<String>, message: impl Into<String>) -> Error { Error { path: path.into(), message: message.into() } }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.path.is_empty() { write!(f, "{}", self.message) } else { write!(f, "{}: {}", self.path, self.message) }
    }
}

impl std::error::Error for Error {}

#[derive(Deserialize)]
struct RawFile {
    format: String,
    version: u64,
    #[serde(default)]
    name: String,
    #[serde(default)]
    menu: BTreeMap<String, String>,
    #[serde(default)]
    start: BTreeMap<String, String>,
    profiles: Vec<RawProfile>,
}

#[derive(Deserialize)]
struct RawProfile {
    id: String,
    name: String,
    #[serde(default = "one")]
    buzz: u8,
    #[serde(default)]
    hosts: Vec<String>,
    #[serde(default)]
    typing: bool,
    #[serde(default)]
    pointer: bool,
    #[serde(default)]
    gestures: BTreeMap<String, Value>,
    #[serde(default)]
    apps: Vec<String>,
}

fn one() -> u8 { 1 }

impl RawFile {
    fn check(self) -> Result<ProfileSet, Error> {
        if self.format != FORMAT { return Err(Error::new("format", format!("must be \"{FORMAT}\""))); }
        if self.version != VERSION { return Err(Error::new("version", format!("{} isn't supported (this dongle reads version {VERSION})", self.version))); }
        if self.name.chars().count() > 40 { return Err(Error::new("name", "at most 40 characters")); }
        if self.profiles.is_empty() || self.profiles.len() > MAX_PROFILES {
            return Err(Error::new("profiles", format!("1 to {MAX_PROFILES} profiles")));
        }
        let ids: Vec<&str> = self.profiles.iter().map(|p| p.id.as_str()).collect();
        let mut profiles = Vec::new();
        for (i, raw) in self.profiles.iter().enumerate() {
            let at = format!("profiles[{i}]");
            if !valid_id(&raw.id) { return Err(Error::new(format!("{at}.id"), "1–16 of a–z, 0–9 and -")); }
            if ids[..i].contains(&raw.id.as_str()) { return Err(Error::new(format!("{at}.id"), format!("\"{}\" is used twice", raw.id))); }
            let name_len = raw.name.chars().count();
            if name_len == 0 || name_len > 24 { return Err(Error::new(format!("{at}.name"), "1–24 characters")); }
            if !(1..=4).contains(&raw.buzz) { return Err(Error::new(format!("{at}.buzz"), "1–4 buzzes")); }
            let mut hosts = Vec::new();
            for (j, name) in raw.hosts.iter().enumerate() {
                let host = Hosts::from_name(name).ok_or_else(|| Error::new(format!("{at}.hosts[{j}]"), unknown_hosts(name)))?;
                hosts.push(host);
            }
            if raw.apps.len() > MAX_APPS { return Err(Error::new(format!("{at}.apps"), format!("at most {MAX_APPS} apps"))); }
            for (j, app) in raw.apps.iter().enumerate() {
                let path = format!("{at}.apps[{j}]");
                if !valid_app(app) { return Err(Error::new(path, "an app is 1–64 of A–Z, a–z, 0–9, . _ and - (a Mac bundle id, like com.google.Chrome)")); }
                let earlier = self.profiles[..i].iter().flat_map(|p| &p.apps).chain(&raw.apps[..j]);
                if earlier.into_iter().any(|a| a.eq_ignore_ascii_case(app)) { return Err(Error::new(path, format!("\"{app}\" is listed twice"))); }
            }
            let computer = hosts.is_empty() || hosts.iter().any(|h| [HostKind::Mac, HostKind::Windows, HostKind::Linux].iter().any(|k| h.matches(*k)));
            if !raw.apps.is_empty() && !computer { return Err(Error::new(format!("{at}.apps"), "apps are for computers, and this profile isn't")); }
            let mut gestures = BTreeMap::new();
            for (name, value) in &raw.gestures {
                let path = format!("{at}.gestures.{name}");
                let gesture = Gesture::from_name(name).ok_or_else(|| Error::new(&path, format!(
                    "unknown gesture (one of {})", Gesture::ALL.map(Gesture::name).join(", "))))?;
                gestures.insert(gesture, parse_binding(value, gesture, &ids, &path)?);
            }
            profiles.push(Profile {
                id: raw.id.clone(), name: raw.name.clone(), buzz: raw.buzz, hosts,
                typing: raw.typing, pointer: raw.pointer, gestures, apps: raw.apps.clone(),
            });
        }
        let mut menu = BTreeMap::new();
        for (key, text) in &self.menu {
            let path = format!("menu.{key}");
            let mut chars = key.chars();
            let (Some(letter), None) = (chars.next(), chars.next()) else { return Err(Error::new(path, "a menu key is one letter or digit")) };
            if !(letter.is_ascii_lowercase() || letter.is_ascii_digit()) { return Err(Error::new(path, "a menu key is a–z or 0–9")); }
            let action = parse_action(text, &ids, &path)?;
            if matches!(action, Action::Hold(_) | Action::Menu) { return Err(Error::new(path, "the menu can't hold a key or open itself")); }
            menu.insert(letter, action);
        }
        let mut start = [0usize; 3];
        for (slot, kind, group) in [(0, HostKind::Phone, "phone"), (1, HostKind::Mac, "computer"), (2, HostKind::Tv, "tv")] {
            let path = format!("start.{group}");
            start[slot] = match self.start.get(group) {
                Some(id) => ids.iter().position(|i| i == id).ok_or_else(|| Error::new(&path, format!("no profile \"{id}\"")))?,
                None => profiles.iter().position(|p| p.allows(kind)).ok_or_else(|| Error::new(&path, format!("no profile allows a {group}")))?,
            };
            let allowed = if group == "computer" { [HostKind::Mac, HostKind::Windows, HostKind::Linux].iter().all(|k| profiles[start[slot]].allows(*k)) }
                          else { profiles[start[slot]].allows(kind) };
            if !allowed { return Err(Error::new(path, format!("\"{}\" isn't for a {group}", profiles[start[slot]].id))); }
        }
        for key in self.start.keys() {
            if !["phone", "computer", "tv"].contains(&key.as_str()) { return Err(Error::new(format!("start.{key}"), "start is for phone, computer and tv")); }
        }
        Ok(ProfileSet { name: self.name, profiles, menu, start })
    }
}

fn valid_app(app: &str) -> bool {
    (1..=64).contains(&app.len()) && app.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

fn valid_id(id: &str) -> bool {
    (1..=16).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

fn unknown_hosts(name: &str) -> String {
    format!("unknown host kind \"{name}\" (one of {})", Hosts::ALL.map(Hosts::name).join(", "))
}

fn parse_binding(value: &Value, gesture: Gesture, ids: &[&str], path: &str) -> Result<Binding, Error> {
    let action = |text: &Value, path: &str| -> Result<Action, Error> {
        let text = text.as_str().ok_or_else(|| Error::new(path, "an action is a string, like \"media:playPause\""))?;
        let action = parse_action(text, ids, path)?;
        if matches!(action, Action::Hold(_)) && gesture != Gesture::MiddleHold {
            return Err(Error::new(path, "hold: only works on middle.hold (it's released with the finger)"));
        }
        Ok(action)
    };
    match value {
        Value::String(_) => Ok(Binding { default: Some(action(value, path)?), variants: Vec::new() }),
        Value::Object(map) => {
            let mut binding = Binding::default();
            for (key, value) in map {
                let path = format!("{path}.{key}");
                if key == "default" {
                    binding.default = Some(action(value, &path)?);
                } else {
                    let hosts = Hosts::from_name(key).ok_or_else(|| Error::new(&path, unknown_hosts(key)))?;
                    binding.variants.push((hosts, action(value, &path)?));
                }
            }
            Ok(binding)
        }
        _ => Err(Error::new(path, "an action string, or an object of them by host kind (\"phone\", \"computer\", \"tv\", …, \"default\")")),
    }
}

/// One action, like `media:playPause`, `key:cmd+shift+m`, `profile:write` (PROFILES.md lists them).
pub fn parse_action(text: &str, ids: &[&str], path: &str) -> Result<Action, Error> {
    let fail = |message: String| Error::new(path, message);
    let (kind, arg) = text.split_once(':').unwrap_or((text, ""));
    Ok(match kind {
        "none" if arg.is_empty() => Action::None,
        "menu" if arg.is_empty() => Action::Menu,
        "write" => Action::Write(if arg.is_empty() { WRITE_SECONDS } else {
            arg.parse::<u8>().ok().filter(|n| (3..=60).contains(n)).ok_or_else(|| fail("write: stops after 3–60 s with nothing written".into()))?
        }),
        "phoneMute" if arg.is_empty() => Action::PhoneMute,
        "call" => match arg {
            "answer" => Action::Call(Call::Answer),
            "end" => Action::Call(Call::End),
            _ => return Err(fail(format!("unknown call action \"{arg}\" (call:answer, call:end)"))),
        },
        "media" => Action::Media(Media::NAMES.iter().find(|(n, _)| *n == arg).map(|(_, m)| *m).ok_or_else(|| fail(format!(
            "unknown media key \"{arg}\" (one of {})", Media::NAMES.map(|(n, _)| n).join(", "))))?),
        "key" => Action::Key(parse_chord(arg).map_err(fail)?),
        "hold" => Action::Hold(parse_chord(arg).map_err(fail)?),
        "type" => {
            if arg.is_empty() || arg.len() > 64 || !arg.bytes().all(|b| (0x20..0x7f).contains(&b)) {
                return Err(fail("type: is 1–64 printable ASCII characters".into()));
            }
            Action::Type(arg.to_string())
        }
        "mouse" => {
            let (what, count) = arg.split_once(':').unwrap_or((arg, ""));
            let steps = if count.is_empty() { 4 } else {
                count.parse::<i8>().ok().filter(|n| (1..=20).contains(n)).ok_or_else(|| fail("scroll steps are 1–20".into()))?
            };
            match what {
                "click" if count.is_empty() => Action::Click(Button::Left),
                "rightClick" if count.is_empty() => Action::Click(Button::Right),
                "middleClick" if count.is_empty() => Action::Click(Button::Middle),
                "scrollUp" => Action::Scroll(steps),
                "scrollDown" => Action::Scroll(-steps),
                _ => return Err(fail(format!("unknown mouse action \"{arg}\" (click, rightClick, middleClick, scrollUp[:n], scrollDown[:n])"))),
            }
        }
        "profile" => Action::Profile(match arg {
            "next" => ProfileTarget::Next,
            "previous" => ProfileTarget::Previous,
            id => ProfileTarget::Index(ids.iter().position(|i| *i == id).ok_or_else(|| fail(format!("no profile \"{id}\"")))?),
        }),
        "host" => Action::Host(match arg {
            "next" => HostTarget::Next,
            "previous" => HostTarget::Previous,
            kind => HostTarget::Kind(Hosts::from_name(kind).ok_or_else(|| fail(format!("host:next, host:previous or a kind ({})", Hosts::ALL.map(Hosts::name).join(", "))))?),
        }),
        _ => return Err(fail(format!("unknown action \"{text}\" (none, menu, write, phoneMute, call:, media:, key:, hold:, type:, mouse:, profile:, host:)"))),
    })
}

/// `cmd+shift+m`, `ctrl+alt+delete`, `f5`, `]`: modifiers, then one key.
pub fn parse_chord(text: &str) -> Result<Chord, String> {
    if text.is_empty() { return Err("a key, like key:enter or key:cmd+shift+m".into()); }
    // "+" alone is the plus key; "cmd++" is ⌘ and plus.
    let (mods_text, key) = match text.strip_suffix("++") {
        Some(rest) => (rest, "+"),
        None => match text.rsplit_once('+') { Some((m, k)) if !k.is_empty() => (m, k), _ => ("", text) },
    };
    let mut modifiers = 0u8;
    if !mods_text.is_empty() {
        for name in mods_text.split('+') {
            modifiers |= match name.to_ascii_lowercase().as_str() {
                "cmd" | "command" | "gui" | "win" | "super" | "meta" => modifiers::GUI,
                "ctrl" | "control" => modifiers::CTRL,
                "alt" | "option" | "opt" => modifiers::ALT,
                "shift" => modifiers::SHIFT,
                other => return Err(format!("unknown modifier \"{other}\" (cmd, ctrl, alt, shift)")),
            };
        }
    }
    let (shift, usage) = key_usage(key).ok_or_else(|| format!("unknown key \"{key}\" (PROFILES.md lists the names)"))?;
    Ok(Chord { modifiers: modifiers | if shift { modifiers::SHIFT } else { 0 }, usage })
}

/// A key name or character → (needs shift, HID usage), US layout.
pub fn key_usage(name: &str) -> Option<(bool, u8)> {
    let lower = name.to_ascii_lowercase();
    let named = match lower.as_str() {
        "enter" | "return" => 0x28, "escape" | "esc" => 0x29, "backspace" => 0x2A, "tab" => 0x2B,
        "space" => 0x2C, "minus" => 0x2D, "equal" | "equals" => 0x2E, "capslock" => 0x39,
        "right" => 0x4F, "left" => 0x50, "down" => 0x51, "up" => 0x52,
        "home" => 0x4A, "pageup" => 0x4B, "delete" | "forwarddelete" => 0x4C, "end" => 0x4D, "pagedown" => 0x4E,
        "insert" => 0x49, "printscreen" => 0x46, "menu" | "application" => 0x65,
        _ => 0,
    };
    if named != 0 { return Some((false, named)); }
    if let Some(n) = lower.strip_prefix('f').and_then(|n| n.parse::<u8>().ok()).filter(|n| (1..=12).contains(n)) {
        return Some((false, 0x3A + n - 1));
    }
    let mut chars = name.chars();
    let (Some(c), None) = (chars.next(), chars.next()) else { return None };
    char_usage(c)
}

/// One character → (needs shift, HID usage), US layout.
pub fn char_usage(c: char) -> Option<(bool, u8)> {
    Some(match c {
        'a'..='z' => (false, 0x04 + (c as u8 - b'a')),
        'A'..='Z' => (true, 0x04 + (c as u8 - b'A')),
        '1'..='9' => (false, 0x1E + (c as u8 - b'1')),
        '0' => (false, 0x27),
        ' ' => (false, 0x2C),
        '-' => (false, 0x2D), '_' => (true, 0x2D), '=' => (false, 0x2E), '+' => (true, 0x2E),
        '[' => (false, 0x2F), '{' => (true, 0x2F), ']' => (false, 0x30), '}' => (true, 0x30),
        '\\' => (false, 0x31), '|' => (true, 0x31), ';' => (false, 0x33), ':' => (true, 0x33),
        '\'' => (false, 0x34), '"' => (true, 0x34), '`' => (false, 0x35), '~' => (true, 0x35),
        ',' => (false, 0x36), '<' => (true, 0x36), '.' => (false, 0x37), '>' => (true, 0x37),
        '/' => (false, 0x38), '?' => (true, 0x38),
        '!' => (true, 0x1E), '@' => (true, 0x1F), '#' => (true, 0x20), '$' => (true, 0x21), '%' => (true, 0x22),
        '^' => (true, 0x23), '&' => (true, 0x24), '*' => (true, 0x25), '(' => (true, 0x26), ')' => (true, 0x27),
        _ => return None,
    })
}

/// Counts one finger's taps into single, double and triple taps. The band reports every tap
/// (`singleTap`) and a `doubleTap` with the second; a tap waits `TAP_WINDOW` for another only if
/// the profile binds more taps of that finger, so double taps alone have no delay.
#[derive(Debug, Default)]
pub struct Taps {
    fingers: [FingerTaps; 2],
}

#[derive(Debug, Default)]
struct FingerTaps {
    count: u8,
    last: f64,
    /// The last count emitted, and when (the band's doubleTap arrives with the tap that made it).
    emitted: Option<(u8, f64)>,
    /// A hold of this finger is on: its taps aren't taps.
    holding: bool,
    /// Taps are ignored until then (a hold was just let go).
    quiet_until: f64,
}

impl Taps {
    fn finger(&mut self, finger: Finger) -> &mut FingerTaps { &mut self.fingers[finger as usize] }

    /// A single tap (`double`: the band's doubleTap). `max` is the profile's highest bound count for
    /// this finger. Returns a count to act on now.
    pub fn tap(&mut self, finger: Finger, double: bool, now: f64, max: u8) -> Option<u8> {
        let f = self.finger(finger);
        if max == 0 || f.holding || now < f.quiet_until { return None; }
        if f.count > 0 && now - f.last > TAP_WINDOW { f.count = 0; }
        if double {
            let counted = f.count >= 2 || f.emitted.is_some_and(|(n, at)| n >= 2 && now - at < TAP_WINDOW / 2.0);
            if counted || max < 2 { return None; }
            f.count = 2;
        } else {
            f.count += 1;
        }
        f.last = now;
        if f.count >= max {
            let count = f.count.min(max);
            f.count = 0;
            f.emitted = Some((count, now));
            return Some(count);
        }
        None
    }

    /// Counts whose window has passed.
    pub fn poll(&mut self, now: f64) -> Vec<(Finger, u8)> {
        let mut done = Vec::new();
        for finger in [Finger::Index, Finger::Middle] {
            let f = self.finger(finger);
            if f.count > 0 && now - f.last > TAP_WINDOW {
                done.push((finger, f.count));
                f.emitted = Some((f.count, now));
                f.count = 0;
            }
        }
        done
    }

    /// A hold of this finger began: what it tapped just before isn't a tap.
    pub fn hold(&mut self, finger: Finger) {
        let f = self.finger(finger);
        f.count = 0;
        f.holding = true;
    }

    /// The hold ended: nor is what the band reports as it lets go.
    pub fn release(&mut self, finger: Finger, now: f64) {
        let f = self.finger(finger);
        if std::mem::take(&mut f.holding) { f.quiet_until = now + 0.3; }
    }
}

#[cfg(test)]
mod tests;
