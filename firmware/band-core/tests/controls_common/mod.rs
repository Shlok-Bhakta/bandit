#![allow(dead_code)] // each test file uses some of these

use std::collections::BTreeMap;

use band_core::controls::palm::{RIGHT_PALM_DOWN_ROLL, RIGHT_PALM_UP_ROLL};
use band_core::controls::pinch::{GYRO_SCALE, Prototypes, from_forearm, to_forearm};
use band_core::controls::{BandControl, BandControls, Binding, Controls, Dial, Drag, Gesture, Options, Output, Palm, Profile, Profiles};
use band_core::events::{Event, GestureMessage, Hand};

pub fn run(command: &str) -> String {
    command.into()
}

pub fn profile(name: &str, bindings: &[(Gesture, String)]) -> Profile<String> {
    let mut profile = Profile::new(name);
    profile.gestures.extend(bindings.iter().cloned().map(|(g, a)| (g, Binding::from(a))));
    profile
}

/// `normal`, and `up` with the palm up.
pub fn up_override(normal: &str, up: &str) -> Binding<String> {
    Binding::from(run(normal)).with(Palm::Up, Some(run(up)))
}

pub fn dial(up: &str, down: &str) -> Option<Dial<String>> {
    Some(Dial { up: up.into(), down: down.into() })
}

/// No band controls (as the Linux default).
pub fn profiles(list: Vec<Profile<String>>) -> Profiles<String> {
    Profiles { band: BandControls::default(), list, picked: 0, apps: BTreeMap::new(), calls: BTreeMap::new(), drawings: BTreeMap::new() }
}

/// These band controls: (controls on/off, next, previous).
pub fn band(controls: Option<Gesture>, next: Option<Gesture>, previous: Option<Gesture>) -> BandControls {
    BandControls {
        controls: controls.map(BandControl::on),
        next: next.map(BandControl::on),
        previous: previous.map(BandControl::on),
        draw: None,
    }
}

pub fn with_band(mut list: Profiles<String>, band: BandControls) -> Profiles<String> {
    list.band = band;
    list
}

/// Controls with these profiles, the band live (connected) at t = 0.
pub fn live(profiles: Profiles<String>) -> Controls<String> {
    live_with(Options::default(), profiles)
}

pub fn live_with(options: Options, profiles: Profiles<String>) -> Controls<String> {
    let mut controls = Controls::new(options, profiles);
    controls.on_event(&Event::Connected, 0.0);
    controls
}

/// Live, the band's hand confirmed at 0.1 s and still motion 0.2–0.7 s (the gyro bias).
pub fn ready(profiles: Profiles<String>, hand: Hand) -> Controls<String> {
    ready_with(Options::default(), profiles, hand)
}

pub fn ready_with(options: Options, profiles: Profiles<String>, hand: Hand) -> Controls<String> {
    let mut controls = live_with(options, profiles);
    controls.on_event(&Event::Handedness(hand), 0.1);
    still(&mut controls, 0.2, 0.5);
    controls
}

pub fn message(finger: &str, action: &str, sequence: u64, t: f64) -> GestureMessage {
    GestureMessage {
        sequence,
        timestamp_us: sequence * 1_000,
        finger: finger.into(),
        action: action.into(),
        derived_action: String::new(),
        synthetic: false,
        received_at: t,
    }
}

/// A fresh band gesture (`action`: tap, doubletap, hold; or left/right/up/down for the thumb).
pub fn gesture(c: &mut Controls<String>, finger: &str, action: &str, sequence: u64, t: f64) -> Vec<Output<String>> {
    c.on_event(&Event::Gesture(message(finger, action, sequence, t)), t)
}

/// Three taps the way the band reports them: the 2nd and 3rd also come with a double tap.
pub fn triple(c: &mut Controls<String>, finger: &str, at: f64) -> Vec<Output<String>> {
    let mut out = Vec::new();
    out.extend(gesture(c, finger, "tap", 1, at));
    out.extend(gesture(c, finger, "tap", 2, at + 0.2));
    out.extend(gesture(c, finger, "doubletap", 3, at + 0.2));
    out.extend(gesture(c, finger, "tap", 4, at + 0.4));
    out.extend(gesture(c, finger, "doubletap", 5, at + 0.4));
    out.extend(c.poll(at + 1.5));
    out
}

pub fn runs(out: &[Output<String>]) -> Vec<String> {
    out.iter().filter_map(|o| match o { Output::Run(a) => Some(a.clone()), _ => None }).collect()
}

pub fn switches(out: &[Output<String>]) -> Vec<(usize, i8)> {
    out.iter().filter_map(|o| match o { Output::Profile { index, step } => Some((*index, *step)), _ => None }).collect()
}

pub fn toggles(out: &[Output<String>]) -> Vec<bool> {
    out.iter().filter_map(|o| match o { Output::Controls { enabled } => Some(*enabled), _ => None }).collect()
}

pub fn gestures(out: &[Output<String>]) -> Vec<Gesture> {
    out.iter().filter_map(|o| match o { Output::Gesture { gesture, .. } => Some(*gesture), _ => None }).collect()
}

/// The band's press and release messages for `finger`.
pub fn press(c: &mut Controls<String>, finger: &str, sequence: u64, t: f64) -> Vec<Output<String>> {
    c.on_event(&Event::Gesture(message(finger, "press", sequence, t)), t)
}
pub fn release(c: &mut Controls<String>, finger: &str, sequence: u64, t: f64) -> Vec<Output<String>> {
    c.on_event(&Event::Gesture(message(finger, "release", sequence, t)), t)
}

/// Gyro samples every 10 ms from `from` for `secs`, moving `degrees` in total along
/// `direction` (forearm frame, palm down, no orientation known). The band clock is `t × 1e6`.
pub fn motion(c: &mut Controls<String>, direction: [f64; 3], degrees: f64, from: f64, secs: f64) -> Vec<Output<String>> {
    motion_at(c, direction, degrees, from, secs, Prototypes::right_hand().palm_down_roll)
}

/// [`motion`] with the band rolled this way (degrees) about the forearm.
pub fn motion_at(c: &mut Controls<String>, direction: [f64; 3], degrees: f64, from: f64, secs: f64, roll: f64) -> Vec<Output<String>> {
    let samples = (secs / 0.01).round() as usize;
    let per_second = degrees / secs;
    let band = from_forearm(direction.map(|v| v * per_second / GYRO_SCALE), roll);
    let mut out = Vec::new();
    for i in 0..=samples {
        let t = from + i as f64 * 0.01;
        let raw = if i == 0 { [0.0; 3] } else { band };
        out.extend(c.on_event(&Event::Motion { timestamp_us: (t * 1e6).round() as u64, gyro: raw }, t));
    }
    out
}

/// Still motion (zero rate) from `from` for `secs`.
pub fn still(c: &mut Controls<String>, from: f64, secs: f64) -> Vec<Output<String>> {
    motion(c, [0.0, 1.0, 0.0], 0.0, from, secs)
}

/// A whole pinch: press at `at`, still 0.25 s, then `degrees` along `direction` in 0.5 s,
/// release. The band's own hold message comes at +0.3 s when `hold_message`. Its messages'
/// sequence numbers come from `at`, so the router never takes a later pinch's for a repeat.
/// The 60 ms between the still samples and the move is a gap the engine skips (the move's
/// first sample isn't added up; its rate is zero anyway).
pub fn pinch(c: &mut Controls<String>, finger: &str, direction: [f64; 3], degrees: f64, at: f64, hold_message: bool) -> Vec<Output<String>> {
    let sequence = 10_000 + (at * 1000.0).round() as u64 * 10;
    let mut out = press(c, finger, sequence, at);
    out.extend(still(c, at + 0.01, 0.24));
    if hold_message {
        out.extend(c.on_event(&Event::Gesture(message(finger, "hold", sequence + 1, at + 0.3)), at + 0.3));
    }
    out.extend(motion(c, direction, degrees, at + 0.31, 0.5));
    out.extend(release(c, finger, sequence + 2, at + 0.85));
    out
}

/// The forearm-frame unit direction that draws `[dx, dy]` (see `draw::project`): the band's
/// step at the drawing frame's roll is x = −dy, z = dx. Any roll the motion is made at.
pub fn drawing_dir([dx, dy]: [f64; 2]) -> [f64; 3] {
    let v = to_forearm([-dy, 0.0, dx], band_core::controls::draw::FRAME_ROLL);
    let n = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    v.map(|c| c / n)
}

pub fn turn_dir() -> [f64; 3] {
    Prototypes::right_hand().turn
}
pub fn drag_dir(drag: Drag) -> [f64; 3] {
    Prototypes::right_hand().drags.expect("right hand")[drag.index()].expect("measured")
}

/// Some actions ran, and all were this one.
pub fn assert_only(ran: &[String], action: &str) {
    assert!(!ran.is_empty() && ran.iter().all(|a| a == action), "{ran:?}");
}

/// An orientation with this roll (degrees) about the forearm, every 20 ms from `from` for `secs`.
pub fn facing(c: &mut Controls<String>, roll: f64, from: f64, secs: f64) {
    let half = (-roll).to_radians() / 2.0;
    let q = [half.cos() as f32, 0.0, half.sin() as f32, 0.0];
    let samples = (secs / 0.02).round() as usize;
    for i in 0..=samples {
        let t = from + i as f64 * 0.02;
        c.on_event(&Event::Orientation(q), t);
    }
}

pub const PALM_DOWN: f64 = RIGHT_PALM_DOWN_ROLL;
pub const PALM_SIDE: f64 = -71.2;
pub const PALM_UP: f64 = RIGHT_PALM_UP_ROLL;
