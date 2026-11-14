//! Band events in, host input out: what each gesture does in the active host's profile
//! (../np-profiles, PROFILES.md), the letter menu, handwriting typing and the air mouse,
//! push-to-talk, and the band's power (wrist motion and handwriting only while something uses them).

use band_core::controls::{draw, palm::RIGHT_PALM_DOWN_ROLL, pinch::{GyroBias, MAX_DT}};
use band_core::events::{Event, Hand};
use band_core::gestures::{GestureRouter, Recognized, Swipe, Tap};
use band_core::haptics::HapticsCommand;
use band_core::session::BandSession;
use log::{info, warn};
use np_profiles::{Action as Do, BandEvent, Button, Feedback, Finger, Gesture, HostTarget, Media, Profile, Taps};

use crate::control;
use crate::remote::{buttons, keys, Action, Kind, MediaKey, Remote};

/// Pinch-and-turn → volume steps with a detent: one step per `DETENT` degrees, at most one per
/// `MIN_INTERVAL`, reset when the pinch ends. Replaces band-core's 2° DialRouter, which turned
/// wrist jitter into a stream of volume changes.
struct VolumeKnob {
    accumulated: f64,
    last_step: f64,
}

impl VolumeKnob {
    const DETENT: f64 = 9.0;
    const MIN_INTERVAL: f64 = 0.15;

    fn new() -> Self { Self { accumulated: 0.0, last_step: f64::NEG_INFINITY } }
    fn reset(&mut self) { self.accumulated = 0.0; }

    fn turn(&mut self, degrees: f64, now: f64) -> i32 {
        if !degrees.is_finite() { return 0; }
        // A reversal drops what was building up the other way (no backlash steps).
        if self.accumulated * degrees < 0.0 { self.accumulated = 0.0; }
        self.accumulated = (self.accumulated + degrees).clamp(-2.0 * Self::DETENT, 2.0 * Self::DETENT);
        if self.accumulated.abs() < Self::DETENT || now - self.last_step < Self::MIN_INTERVAL { return 0; }
        let step = self.accumulated.signum() as i32;
        self.accumulated -= step as f64 * Self::DETENT;
        self.last_step = now;
        step
    }
}

/// A pinch held (the band's own "hold") and let go within this long, without turning the dial,
/// is `index.hold` (usually the letter menu). Needs no wrist motion, unlike the dial.
const SWITCH_HOLD_MAX: f64 = 3.0;
/// Pulses waiting to be sent to the band: four patterns of `PATTERN_MAX_STEPS`.
const HAPTICS_QUEUED: usize = 4 * np_profiles::PATTERN_MAX_STEPS;
/// How long the letter menu waits for a letter once handwriting is asked for (the band takes a
/// moment to start).
const MENU_WINDOW: f64 = 6.0;
/// How long it waits for the band to start writing before giving up.
const MENU_START_MAX: f64 = 6.0;
/// The air mouse ignores turns slower than this (°/s): tremor and drift.
const POINTER_DEADZONE: f64 = 4.0;
/// A pinch hold that moved the pointer this far (degrees) doesn't open the menu on release.
const POINTER_MOVED: f64 = 3.0;
/// Pointer counts per degree of wrist turn, per speed step (speed 1–10).
const POINTER_GAIN: f64 = 4.0;
/// A pinch hold with no word from the band this long (a lost release) no longer moves the pointer.
const HOLD_LOST: f64 = 10.0;
/// In a `pointer` profile the gyro keeps streaming this long after the last pinch, so the next
/// one moves the pointer at once (turning motion on takes the band a moment). The first pinch
/// after a pause still waits for it.
const POINTER_WARM: f64 = 30.0;
/// Seconds between two alerts that come close together, so each pattern can be told apart.
const ALERT_GAP: f64 = 0.5;
/// Seconds between a ringing call's buzzes (or the pattern and a second, if that's longer).
const RING_EVERY: f64 = 3.0;
/// A flick: the wrist turning at least this fast (°/s, the air mouse's frame), mostly one way.
const FLICK_RATE: f64 = 150.0;
/// ... with the main direction at least this many times the other.
const FLICK_DOMINANCE: f64 = 1.8;
/// Below this the wrist is still again and the next flick may come (°/s).
const FLICK_REARM: f64 = 60.0;
/// A turn back the other way this soon after a flick is the hand returning, not a flick.
const FLICK_RETURN: f64 = 0.45;
/// Motion faster than this (°/s) is a swing worth reporting in the gesture lab.
const SWING_RATE: f64 = 40.0;
/// The same raw band event this soon again is the band repeating itself.
const BAND_EVENT_REPEAT: f64 = 0.15;
/// The app switcher lets go of ⌘ by itself after this long (a lost release).
const SWITCHER_MAX: f64 = 15.0;
/// A typing profile's handwriting sleeps after this long with nothing written (the band's model
/// costs battery); any gesture wakes it.
const WRITE_IDLE: f64 = 90.0;

/// The air mouse: the wrist's turn, while a pinch is held, as pointer moves.
#[derive(Default)]
struct Pointer {
    bias: GyroBias,
    last_us: Option<u64>,
    /// Fractions of a count not sent yet.
    carry: [f64; 2],
    /// Degrees moved during this pinch hold.
    moved: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Direction { Up, Down, Left, Right }

impl Direction {
    fn name(self) -> &'static str { match self { Direction::Up => "up", Direction::Down => "down", Direction::Left => "left", Direction::Right => "right" } }
    fn opposite(self) -> Direction { match self { Direction::Up => Direction::Down, Direction::Down => Direction::Up, Direction::Left => Direction::Right, Direction::Right => Direction::Left } }
    fn gesture(self) -> Gesture { match self { Direction::Up => Gesture::FlickUp, Direction::Down => Gesture::FlickDown, Direction::Left => Gesture::FlickLeft, Direction::Right => Gesture::FlickRight } }
    fn of(x: f64, y: f64) -> Direction {
        if x.abs() >= y.abs() { if x > 0.0 { Direction::Right } else { Direction::Left } } else if y > 0.0 { Direction::Up } else { Direction::Down }
    }
}

/// Flicks during a pinch hold, from the wrist's turn rate.
#[derive(Default)]
struct Flicks {
    /// Still enough for the next flick.
    armed: bool,
    last: Option<(Direction, f64)>,
    /// The fastest moment of the swing going on (°/s, x, y), and whether it flicked.
    swing: Option<(f64, f64, f64, bool)>,
}

/// `write`: the band's handwriting on, typed on the host, until nothing is written for a while.
struct Burst {
    /// Off after this long with nothing typed.
    seconds: f64,
    asked: f64,
    /// When it turns off (set once the band is writing; each typed letter pushes it back).
    until: Option<f64>,
    /// The host and profile it was for (`Remote::generation`): it ends when they change.
    generation: u32,
}

/// The letter menu, opened by a pinch hold: the band's handwriting on for one letter.
struct Menu {
    opened: f64,
    /// When handwriting was on (asked for), so the window starts.
    writing_since: Option<f64>,
}

pub struct Controller<'a> {
    remote: &'a Remote,
    router: GestureRouter,
    knob: VolumeKnob,
    haptics: std::collections::VecDeque<(f64, HapticsCommand)>,
    /// When the last alert's pattern ends: the next one plays after it, not over it.
    alerts_until: f64,
    /// When a ringing call buzzes next.
    next_ring: f64,
    pub gestures: usize,
    /// The detail of the battery answer being handled (band-core keeps it beside the event).
    pub battery_detail: Option<band_core::events::BatteryDetail>,
    pub motion: usize,
    /// When the band reported the current index hold, and whether it turned the volume (or moved
    /// the pointer) since.
    hold: Option<(f64, bool)>,
    /// The band's last word about that hold (it may repeat the hold message while it lasts).
    hold_seen: f64,
    pointer: Pointer,
    last_writing_request: f64,
    /// A `hold:` chord (push-to-talk): the host holding it, since when.
    talking: Option<(u16, f64)>,
    /// Single, double and triple taps, from the band's taps.
    taps: Taps,
    /// The host and profile the taps being counted were for (`Remote::generation`): a tap still
    /// waiting for a second one when that changes is dropped, not acted on somewhere else.
    taps_for: u32,
    menu: Option<Menu>,
    /// When the menu last closed: what the band writes just after is the rest of that letter.
    menu_closed: f64,
    /// Turn handwriting off without a buzz (the menu had it on, not write mode).
    quiet_off: bool,
    /// A new pinch hold whose dial band-core should arm once motion flows (`poll`).
    arm_dial: bool,
    /// Flick detection for the pinch held now.
    flicks: Flicks,
    /// The index finger is down (the band's `press`), since when: flicks count from then.
    pinch_down: Option<f64>,
    /// The app switcher holding ⌘ (or Alt) on a host, since when (`apps:` on a flick).
    switcher: Option<(u16, f64)>,
    /// Raw band events lately fired, for the band's repeats (`BAND_EVENT_REPEAT`).
    band_fired: Vec<(BandEvent, f64)>,
    /// Band messages already looked at (sequence, timestamp).
    band_seen: std::collections::VecDeque<(u64, u64)>,
    /// A typing profile's handwriting stays on until then (see `WRITE_IDLE`).
    write_awake_until: f64,
    /// Whether the profile wanted typing at the last poll (switching to it wakes the handwriting).
    was_typing: bool,
    burst: Option<Burst>,
    /// The gyro stays on until then in a pointer profile (`POINTER_WARM`).
    pointer_warm_until: f64,
}

/// The active host's profile, as the controller needs it.
struct Active {
    set: std::sync::Arc<np_profiles::ProfileSet>,
    index: usize,
    kind: Kind,
}

impl Active {
    fn profile(&self) -> &Profile { &self.set.profiles[self.index] }
    fn action(&self, gesture: Gesture) -> Option<&Do> { self.profile().action(gesture, self.kind.host_kind()) }
    fn types(&self, remote: &Remote) -> bool { self.profile().types(self.kind.host_kind()) && remote.mouse_settings().typing }
    fn points(&self) -> bool { self.profile().points(self.kind.host_kind()) }
}

impl<'a> Controller<'a> {
    pub fn new(remote: &'a Remote) -> Self {
        // A switch while the band was away buzzes nothing: it isn't news now.
        remote.take_switched();
        Self {
            remote, router: GestureRouter::default(), knob: VolumeKnob::new(), haptics: Default::default(), alerts_until: f64::NEG_INFINITY, next_ring: f64::NEG_INFINITY,
            gestures: 0, battery_detail: None, motion: 0, hold: None, last_writing_request: f64::NEG_INFINITY, talking: None, taps: Taps::default(), taps_for: remote.generation(),
            menu: None, menu_closed: f64::NEG_INFINITY, quiet_off: false,
            hold_seen: f64::NEG_INFINITY, pointer: Pointer::default(),
            write_awake_until: f64::NEG_INFINITY, was_typing: false, burst: None, pointer_warm_until: f64::NEG_INFINITY, arm_dial: false,
            flicks: Flicks::default(), pinch_down: None, switcher: None, band_fired: Vec::new(), band_seen: Default::default(),
        }
    }

    /// Plays a pattern from `start`, its pulses in time order among what's queued.
    fn play(&mut self, start: f64, pattern: &[np_profiles::Pulse]) {
        for pulse in pattern {
            // A band that stops taking haptics mustn't let a ringing call queue them forever.
            if self.haptics.len() >= HAPTICS_QUEUED { break; }
            let at = start + f64::from(pulse.at_ms) / 1000.0;
            let command = HapticsCommand::Vibrate { duration_ms: u64::from(pulse.ms), amplitude: pulse.amplitude() };
            let index = self.haptics.iter().position(|(due, _)| *due > at).unwrap_or(self.haptics.len());
            self.haptics.insert(index, (at, command));
        }
    }

    /// The set's pattern for one of the band's own moments (nothing if it's `none`).
    fn feedback(&mut self, now: f64, moment: Feedback) {
        if let Some(pattern) = crate::profiles::current().feedback(moment).cloned() { self.play(now, &pattern); }
    }

    /// A built-in (or redefined) pattern by name.
    fn named(&mut self, now: f64, name: &str) {
        if let Some(pattern) = crate::profiles::current().pattern(name) { self.play(now, &pattern); }
    }

    /// An alert from a computer's helper, after any alert still playing (so each can be told apart).
    fn buzz_alert(&mut self, now: f64, alert: crate::remote::Alert) {
        use crate::remote::Alert;
        let moment = match alert { Alert::Done => Feedback::AlertDone, Alert::Question => Feedback::AlertQuestion, Alert::Error => Feedback::AlertError };
        let Some(pattern) = crate::profiles::current().feedback(moment).cloned() else { return };
        let start = now.max(self.alerts_until + ALERT_GAP);
        self.play(start, &pattern);
        self.alerts_until = self.alerts_until.max(start + f64::from(np_profiles::pattern_ms(&pattern)) / 1000.0);
    }

    /// Something didn't work.
    fn buzz_long(&mut self, now: f64) { self.feedback(now, Feedback::Refused); }

    fn close_menu(&mut self, now: f64) {
        if self.menu.take().is_some() {
            self.menu_closed = now;
            self.quiet_off = true;
        }
    }

    fn active(&self) -> Option<Active> {
        self.remote.active_profile().map(|(set, index, kind)| Active { set, index, kind })
    }

    /// The menu's letter: what the profile set's `menu` says it does.
    fn menu_letter(&mut self, letter: Option<char>, now: f64) {
        self.close_menu(now);
        let set = crate::profiles::current();
        match letter.and_then(|letter| set.menu.get(&letter).map(|action| (letter, action.clone()))) {
            Some((letter, action)) => {
                info!("MENU: {letter}: {action:?}");
                // Switches buzz for themselves (`poll`); anything else gets one buzz.
                let switches = matches!(action, Do::Profile(_) | Do::Host(_));
                if self.perform(&action, Gesture::IndexHold, &set, now) && !switches && !matches!(action, Do::Buzz(_)) { self.named(now, "tap"); }
            }
            None => {
                info!("MENU: {letter:?} isn't a menu letter");
                self.buzz_long(now);
            }
        }
    }

    /// Runs an action on the active host. False (and a long buzz) when it can't happen there.
    /// `set` is the profile set the action came from (its `profile:` index means a profile there).
    fn perform(&mut self, action: &Do, gesture: Gesture, set: &np_profiles::ProfileSet, now: f64) -> bool {
        let media = |key: Media| Action::Media(match key {
            Media::PlayPause => MediaKey::PlayPause, Media::Next => MediaKey::Next, Media::Previous => MediaKey::Previous,
            Media::VolumeUp => MediaKey::VolumeUp, Media::VolumeDown => MediaKey::VolumeDown, Media::Mute => MediaKey::Mute,
            Media::Voice => MediaKey::Voice,
        });
        match action {
            Do::None => {}
            Do::Media(key) => self.remote.send(media(*key)),
            Do::PhoneMute => self.remote.send(Action::PhoneMute),
            Do::Call(call) => {
                let done = match call { np_profiles::Call::Answer => crate::ancs::answer(), np_profiles::Call::End => crate::ancs::end() };
                if !done { self.buzz_long(now); return false; }
            }
            Do::Key(chord) => self.remote.send(Action::Key { modifiers: chord.modifiers, usage: chord.usage }),
            // Only `middle.hold` holds (`event`); elsewhere the check refused it.
            Do::Hold(chord) => self.remote.send(Action::Key { modifiers: chord.modifiers, usage: chord.usage }),
            Do::Type(text) => self.remote.type_text(text),
            Do::Click(button) => self.remote.click(match button { Button::Left => buttons::LEFT, Button::Right => buttons::RIGHT, Button::Middle => buttons::MIDDLE }),
            Do::Scroll(steps) => { self.remote.mouse(0, 0, 0, *steps); }
            Do::Profile(target) => if let Err(error) = match target {
                // By id: a new set may have arrived since this one was read.
                np_profiles::ProfileTarget::Index(index) => self.remote.set_profile_id(None, &set.profiles[*index].id),
                target => self.remote.set_profile(None, *target),
            } {
                info!("PROFILE: {error}");
                self.buzz_long(now);
                return false;
            },
            Do::Host(target) => {
                let switched = match target {
                    HostTarget::Next => self.remote.step(true),
                    HostTarget::Previous => self.remote.step(false),
                    HostTarget::Kind(hosts) => self.remote.target_kind(*hosts),
                };
                // The switch buzzes once for a phone, twice for a computer (`poll`).
                if !switched {
                    info!("{}: no host to switch to", gesture.name());
                    self.buzz_long(now);
                    return false;
                }
            }
            Do::Menu => {
                info!("MENU: open: write one letter");
                self.menu = Some(Menu { opened: now, writing_since: None });
            }
            Do::Buzz(pattern) => self.play(now, pattern),
            Do::Apps(forward) => {
                let Some(active) = self.active().filter(|a| a.kind.computer()) else {
                    info!("{}: the app switcher is for computers", gesture.name());
                    self.buzz_long(now);
                    return false;
                };
                let shift = if *forward { 0 } else { keys::SHIFT };
                // ⌘Tab on a Mac; Alt+Tab elsewhere (⌘ would be sent as Ctrl there).
                let modifier = if active.kind == Kind::Mac { keys::GUI } else { keys::ALT };
                let in_pinch = gesture.is_flick() && (self.hold.is_some() || self.pinch_down.is_some());
                if in_pinch && self.switcher.is_none() && self.talking.is_none() {
                    if let Some(handle) = self.remote.hold(modifier, 0) { self.switcher = Some((handle, now)); }
                }
                if self.switcher.is_some() {
                    self.remote.send(Action::Key { modifiers: shift, usage: keys::TAB });
                } else {
                    self.remote.send(Action::Key { modifiers: modifier | shift, usage: keys::TAB });
                }
            }
            Do::Write(seconds) => {
                if self.burst.take().is_some() {
                    info!("WRITE: off ({})", gesture.name());
                } else if self.active().is_some_and(|a| a.kind == Kind::Phone) {
                    info!("WRITE: a phone isn't typed on");
                    self.buzz_long(now);
                    return false;
                } else {
                    info!("WRITE: on until {seconds} s pass with nothing written");
                    self.burst = Some(Burst { seconds: f64::from(*seconds), asked: now, until: None, generation: self.remote.generation() });
                }
            }
        }
        true
    }

    /// Forgets taps counted for another host or profile.
    fn check_taps(&mut self) {
        let generation = self.remote.generation();
        if generation != self.taps_for {
            self.taps = Taps::default();
            self.taps_for = generation;
        }
    }

    /// A gesture of the active profile, if it binds one.
    fn gesture(&mut self, gesture: Gesture, now: f64) {
        let Some(active) = self.active() else { return };
        let Some(action) = active.action(gesture).cloned() else { return };
        info!("GESTURE: {} in {}: {action:?}", gesture.name(), active.profile().id);
        if !self.perform(&action, gesture, &active.set, now) { return; }
        // Its own buzz, else the set's `gesture` one (switches and buzzes say enough by themselves).
        match active.profile().buzz(gesture).cloned() {
            Some(pattern) => self.play(now, &pattern),
            None if !matches!(action, Do::Profile(_) | Do::Host(_) | Do::Buzz(_)) => self.feedback(now, Feedback::Gesture),
            None => {}
        }
    }

    /// The band's message as raw `band.` events, for those the profile binds.
    fn band_events(&mut self, message: &band_core::events::GestureMessage, active: &Active, now: f64) {
        let age = now - message.received_at;
        if message.synthetic || !(-0.1..=0.35).contains(&age) { return; }
        let identity = (message.sequence, message.timestamp_us);
        if self.band_seen.contains(&identity) { return; }
        self.band_seen.push_back(identity);
        if self.band_seen.len() > 32 { self.band_seen.pop_front(); }
        let bound: Vec<BandEvent> = active.profile().band_events().collect();
        if bound.is_empty() { return; }
        self.band_fired.retain(|(_, at)| now - at < BAND_EVENT_REPEAT);
        for event in BandEvent::of_message(&message.finger, &message.action, &message.derived_action) {
            if !bound.contains(&event) || self.band_fired.iter().any(|(e, _)| *e == event) { continue; }
            self.band_fired.push((event, now));
            self.gesture(Gesture::Band(event), now);
        }
    }

    /// Lets go of the app switcher's ⌘: the app it reached comes to the front.
    fn end_switcher(&mut self) {
        if let Some((handle, _)) = self.switcher.take() { self.remote.release(handle); }
    }

    /// Gestures go through the active host's profile (`gesture`). The pinch is special: held, it
    /// arms the dial (or the pointer in a `pointer` profile); let go without turning, it is
    /// `index.hold`. `middle.hold` with a `hold:` chord keeps the chord pressed until the finger
    /// lets go (push-to-talk).
    pub fn event(&mut self, event: Event, now: f64, hand: Option<Hand>) {
        let active = self.active();
        match event {
            Event::Connected => {
                info!("RESULT: owner trust accepted and streams subscribed: the band is live");
                control::set_band_state("live");
                self.feedback(now, Feedback::Connected);
            }
            Event::Gesture(message) => {
                self.gestures += 1;
                let typing = active.as_ref().is_some_and(|a| a.types(self.remote));
                if typing && now >= self.write_awake_until { info!("handwriting: waking (a gesture)"); }
                if typing { self.write_awake_until = now + WRITE_IDLE; }
                info!("gesture #{}: {} {} {}", message.sequence, message.finger, message.action, message.derived_action);
                let released = message.action == "release" || message.derived_action.ends_with("Release");
                let finger = match message.finger.as_str() { "index" => Some(Finger::Index), "middle" => Some(Finger::Middle), _ => None };
                if let Some(finger) = finger.filter(|_| !message.synthetic) {
                    if message.derived_action == "buttonHold" { self.taps.hold(finger); } else if released { self.taps.release(finger, now); }
                }
                if message.finger == "middle" && released {
                    if let Some((handle, _)) = self.talking.take() { self.remote.release(handle); }
                }
                if self.menu.is_some() {
                    // Writing the letter makes the band see pinches and taps: none of them count.
                    let _ = self.router.gesture(&message, now);
                    return;
                }
                if let Some(active) = &active { self.band_events(&message, active, now); }
                if message.finger == "index" && !message.synthetic {
                    if message.action == "press" || message.derived_action == "buttonPress" {
                        if self.pinch_down.is_none() { self.flicks = Flicks::default(); }
                        self.pinch_down.get_or_insert(now);
                    } else if released {
                        self.pinch_down = None;
                        self.end_switcher();
                    }
                }
                if message.finger == "index" && !message.synthetic {
                    if message.derived_action == "buttonHold" {
                        // A repeat of the same hold keeps its start (and whether it moved).
                        self.pointer_warm_until = now + POINTER_WARM;
                        if self.hold.is_none() || now - self.hold_seen > HOLD_LOST {
                            // A flick between the press and the band's hold message counts for the hold.
                            let flicked = self.pinch_down.is_some() && self.flicks.last.is_some();
                            self.hold = Some((now, flicked));
                            self.pointer.moved = 0.0;
                            self.arm_dial = true;
                            if !flicked { self.flicks = Flicks::default(); }
                        }
                        self.hold_seen = now;
                    } else if released {
                        if let Some((since, turned)) = self.hold.take() {
                            if !turned && now - since <= SWITCH_HOLD_MAX {
                                let _ = self.router.gesture(&message, now);
                                return self.gesture(Gesture::IndexHold, now);
                            }
                        }
                    }
                }
                let Some(recognized) = self.router.gesture(&message, now) else { return };
                info!("RECOGNIZED: {recognized:?}");
                let Some(active) = active else { return };
                let taps = |finger| active.profile().max_taps(finger, active.kind.host_kind());
                match recognized {
                    Recognized::Tap(tap @ (Tap::IndexTap | Tap::IndexDoubleTap | Tap::MiddleTap | Tap::MiddleDoubleTap)) => {
                        let finger = if matches!(tap, Tap::IndexTap | Tap::IndexDoubleTap) { Finger::Index } else { Finger::Middle };
                        let double = matches!(tap, Tap::IndexDoubleTap | Tap::MiddleDoubleTap);
                        self.check_taps();
                        if let Some(count) = self.taps.tap(finger, double, now, taps(finger)) {
                            if let Some(gesture) = Gesture::taps(finger, count) { self.gesture(gesture, now); }
                        }
                    }
                    // The pinch: the dial, the pointer or index.hold (above).
                    Recognized::Tap(Tap::IndexHold) => {}
                    Recognized::Tap(Tap::MiddleHold) => {
                        let Some(action) = active.action(Gesture::MiddleHold).cloned() else { return };
                        // A buzz: it started (speak now, for voice and push-to-talk).
                        match active.profile().buzz(Gesture::MiddleHold).cloned() {
                            Some(pattern) => self.play(now, &pattern),
                            None => self.feedback(now, Feedback::HoldStart),
                        }
                        match action {
                            Do::Hold(chord) if self.talking.is_none() => {
                                info!("GESTURE: middle.hold: holding {chord:?}");
                                if let Some(handle) = self.remote.hold(chord.modifiers, chord.usage) { self.talking = Some((handle, now)); }
                            }
                            Do::Hold(_) => {}
                            action => { info!("GESTURE: middle.hold: {action:?}"); self.perform(&action, Gesture::MiddleHold, &active.set, now); }
                        }
                    }
                    Recognized::Swipe(swipe) => self.gesture(match swipe {
                        Swipe::Up => Gesture::SwipeUp, Swipe::Down => Gesture::SwipeDown,
                        Swipe::Left => Gesture::SwipeLeft, Swipe::Right => Gesture::SwipeRight,
                    }, now),
                }
            }
            Event::Motion { timestamp_us, gyro } => {
                self.motion += 1;
                let flicks = active.as_ref().is_some_and(|a| a.profile().flicks(a.kind.host_kind()));
                self.point(timestamp_us, gyro, now, active.as_ref().is_some_and(Active::points), hand);
                if let Some(direction) = self.flick(gyro, now, flicks, hand) { self.gesture(direction.gesture(), now); }
            }
            Event::DialState(on) => {
                info!("pinch dial {}", if on { "engaged" } else { "released" });
                self.knob.reset();
            }
            // A pointer profile: a pinch's turn moves the pointer (`point`), not the dial.
            Event::DialTurn(_) if self.menu.is_some() || active.as_ref().is_some_and(Active::points) => {}
            Event::DialTurn(delta) => {
                // kinesis: on the left wrist the gyro-derived rotation is reversed.
                let delta = if hand == Some(Hand::Left) { -delta } else { delta };
                let step = self.knob.turn(delta, now);
                if step != 0 { if let Some(hold) = self.hold.as_mut() { hold.1 = true; } }
                match step {
                    1 => self.gesture(Gesture::DialCw, now),
                    -1 => self.gesture(Gesture::DialCcw, now),
                    _ => {}
                }
            }
            Event::BatteryStatus(Some(status)) => {
                let detail = self.battery_detail.take();
                let shown = |value: Option<String>| value.unwrap_or_else(|| "?".into());
                match detail {
                    Some(d) => info!("battery {}% charging {:?} · {} mV, {} mA, {} °C, counter {}", status.level, status.charging,
                                     shown(d.millivolts.map(|v| v.to_string())), shown(d.milliamps.map(|v| v.to_string())),
                                     shown(d.temperature_c.map(|v| format!("{v:.1}"))), shown(d.counter.map(|v| v.to_string()))),
                    None => info!("battery {}% charging {:?}", status.level, status.charging),
                }
                control::set_band_battery(status.level, status.charging, detail);
                self.remote.set_battery(status.level);
            }
            Event::Handedness(hand) => {
                info!("band hand setting: {hand:?}");
                control::set_band_hand(Some(match hand { Hand::Left => "left", Hand::Right => "right" }));
            }
            Event::HandednessFailure(message) => warn!("hand: {message}"),
            Event::HapticsFinished { rpc_success, .. } if !rpc_success => warn!("haptics not confirmed by the band"),
            _ => {}
        }
    }

    /// Handwriting on or off as the mode asks, what it wrote typed, queued haptics. Returns bytes
    /// for the band.
    pub fn poll(&mut self, session: &mut BandSession, now: f64) -> Vec<u8> {
        // A lost release would leave ⌥Space held: let go after a minute whatever happens.
        if let Some((handle, since)) = self.talking {
            if now - since > 60.0 {
                warn!("push-to-talk held 60 s without a release from the band: letting go");
                self.remote.release(handle);
                self.talking = None;
            }
        }
        if let Some(kind) = self.remote.take_switched() {
            self.feedback(now, if kind == Kind::Phone { Feedback::HostPhone } else { Feedback::HostComputer });
        }
        if let Some(pattern) = self.remote.take_profile_switched() { self.play(now, &pattern); }
        if let Some(alert) = self.remote.take_alert() { self.buzz_alert(now, alert); }
        if let Some(pattern) = self.remote.take_play() { self.play(now, &pattern); }
        if self.switcher.is_some_and(|(_, since)| now - since > SWITCHER_MAX) {
            warn!("app switcher held {SWITCHER_MAX} s without the pinch letting go: letting go");
            self.end_switcher();
        }
        if crate::ancs::ringing() && now >= self.next_ring {
            let pattern = crate::profiles::current().feedback(Feedback::CallRinging).cloned().unwrap_or_default();
            self.play(now, &pattern);
            self.next_ring = now + RING_EVERY.max(f64::from(np_profiles::pattern_ms(&pattern)) / 1000.0 + 1.0);
        }
        self.check_taps();
        for (finger, count) in self.taps.poll(now) {
            // The first may switch host or profile: the other finger's taps were for the old one.
            if self.remote.generation() != self.taps_for { break; }
            if let Some(gesture) = Gesture::taps(finger, count) { self.gesture(gesture, now); }
        }
        let active = self.active();
        // Wrist motion streams ~70 messages a second: only while a pinch hold can use it, in a
        // profile that has a use for it (the dial, or the pointer).
        let uses_motion = active.as_ref().is_some_and(|a| a.profile().uses_motion(a.kind.host_kind()));
        let warm = active.as_ref().is_some_and(|a| a.points() || a.profile().flicks(a.kind.host_kind())) && now < self.pointer_warm_until;
        let pinching = self.hold.is_some() && now - self.hold_seen < HOLD_LOST || self.pinch_down.is_some_and(|at| now - at < HOLD_LOST);
        // The gesture lab shows every pinch's swings, flicks bound or not.
        let want_motion = ((uses_motion || control::lab_on()) && (warm || pinching) && self.menu.is_none())
            || control::FORCE_MOTION.load(std::sync::atomic::Ordering::Relaxed);
        // Motion was off when the pinch began, so band-core's dial wouldn't arm by itself.
        if std::mem::take(&mut self.arm_dial) && want_motion { session.arm_dial(now); }
        if want_motion != session.motion_on() && session.streams_enabled() {
            match session.set_motion(want_motion) {
                Ok(bytes) if !bytes.is_empty() => return bytes,
                Ok(_) => {}
                Err(error) => warn!("motion: {error}"),
            }
        }
        // The band's handwriting model costs battery: only while a typing profile is active on a
        // computer and writing isn't idle (`WRITE_IDLE`), or the letter menu is open.
        let write_mode = active.as_ref().is_some_and(|a| a.types(self.remote));
        if write_mode && !self.was_typing { self.write_awake_until = now + WRITE_IDLE; }
        self.was_typing = write_mode;
        let write_awake = write_mode && now < self.write_awake_until;
        if let Some(burst) = &mut self.burst {
            if burst.until.is_none() && session.band_writing() { burst.until = Some(now + burst.seconds); }
            let over = match burst.until {
                Some(until) => now >= until,
                None => now - burst.asked > MENU_START_MAX,
            };
            if over || burst.generation != self.remote.generation() {
                info!("WRITE: off ({})", if burst.generation != self.remote.generation() { "the host or profile changed" }
                                          else if burst.until.is_some() { "nothing written for a while" } else { "the band didn't start writing" });
                self.burst = None;
            }
        }
        let bursting = self.burst.is_some();
        let forced = control::FORCE_WRITING.load(std::sync::atomic::Ordering::Relaxed);
        let want = session.streams_enabled() && (write_awake || bursting || self.menu.is_some() || forced);
        if want == session.band_writing() { self.quiet_off = false; }
        if want != session.band_writing() && now - self.last_writing_request >= 3.0 {
            self.last_writing_request = now;
            match session.set_band_handwriting(want) {
                Ok(bytes) => {
                    let for_menu = self.menu.is_some() || std::mem::take(&mut self.quiet_off);
                    info!("handwriting {}", match (want, for_menu) {
                        (true, true) => "ON for the letter menu",
                        (true, false) if bursting => "ON: write on any surface until you stop for a while",
                        (true, false) => "ON: write on any surface, letters are typed on the computer",
                        (false, _) if write_mode => "asleep (nothing written for a while; any write-mode gesture wakes it)",
                        (false, _) => "off",
                    });
                    // Write now, or stopped. (The menu buzzes for itself.)
                    if !for_menu { self.feedback(now, if want { Feedback::WriteOn } else { Feedback::WriteOff }); }
                    return bytes;
                }
                Err(error) => {
                    warn!("handwriting: {error}");
                    if self.menu.is_some() {
                        // No handwriting now: a pinch hold switches host, as it did before the menu.
                        self.close_menu(now);
                        if !self.remote.step(true) { self.buzz_long(now); }
                    }
                }
            }
        }
        if let Some(menu) = &mut self.menu {
            let started = menu.writing_since.is_none() && session.band_writing();
            if started { menu.writing_since = Some(now); }
            let expired = match menu.writing_since {
                Some(since) => now - since > MENU_WINDOW,
                None => now - menu.opened > MENU_START_MAX,
            };
            if started {
                // What the band wrote before the menu opened isn't the menu's letter.
                session.take_written();
                // Write the letter now.
                self.feedback(now, Feedback::MenuReady);
            } else if expired {
                info!("MENU: no letter written");
                self.close_menu(now);
                self.buzz_long(now);
            }
        }
        for written in session.take_written() {
            if self.menu.as_ref().is_some_and(|menu| menu.writing_since.is_some()) {
                use band_core::handwriting::{group, PAUSE, SPACE};
                if written.index == PAUSE || group(written.index) == SPACE { continue; }
                let letter = menu_letter(&written);
                self.menu_letter(letter, now);
            } else if self.menu.is_none() && (write_mode || self.burst.is_some()) && now - self.menu_closed > 1.0 {
                // Pauses and symbols that type nothing don't keep the model awake.
                if self.type_symbol(written.index) {
                    self.write_awake_until = now + WRITE_IDLE;
                    if let Some(burst) = &mut self.burst { burst.until = Some(now + burst.seconds); }
                }
            }
        }
        if let Some(&(due, command)) = self.haptics.front() {
            if now >= due && session.haptics_ready() {
                self.haptics.pop_front();
                return session.send_haptics(command, now).unwrap_or_default();
            }
        }
        Vec::new()
    }
}

impl Controller<'_> {
    /// One gyro sample: in a pointer profile with a pinch held, a pointer move (the drawing
    /// frame's x right, y up, as band-core's drawing reads the wrist). The gyro's resting offset is
    /// learned from every still sample: motion streams only during pinch holds (`poll`).
    fn point(&mut self, timestamp_us: u64, raw: [f64; 3], now: f64, points: bool, hand: Option<Hand>) {
        let pointer = &mut self.pointer;
        let dt = pointer.last_us.replace(timestamp_us).map(|last| timestamp_us.saturating_sub(last) as f64 / 1e6);
        let Some(dt) = dt.filter(|dt| *dt > 0.0 && *dt <= MAX_DT) else { return };
        let clutched = points && self.menu.is_none() && self.hold.is_some() && now - self.hold_seen < HOLD_LOST;
        pointer.bias.learn(raw, dt);
        if !clutched {
            pointer.carry = [0.0; 2];
            return;
        }
        let [x, y] = draw::project(pointer.bias.rate(raw), RIGHT_PALM_DOWN_ROLL);
        // The frame is a right wrist's: on the left the band sits turned over, and up comes out
        // as down (left and right agree; the dial mirrors its turn the same way).
        let y = if hand == Some(Hand::Left) { -y } else { y };
        let rate = x.hypot(y);
        if rate < POINTER_DEADZONE { return; }
        pointer.moved += rate * dt;
        if pointer.moved > POINTER_MOVED {
            if let Some(hold) = self.hold.as_mut() { hold.1 = true; }
        }
        let settings = self.remote.mouse_settings();
        let gain = f64::from(settings.speed) * POINTER_GAIN * dt;
        let sign = |flip: bool| if flip { -1.0 } else { 1.0 };
        // HID y grows downwards.
        let wanted = [pointer.carry[0] + x * gain * sign(settings.flip_x), pointer.carry[1] - y * gain * sign(settings.flip_y)];
        let counts = wanted.map(|v| v.round().clamp(-127.0, 127.0));
        pointer.carry = [wanted[0] - counts[0], wanted[1] - counts[1]];
        if counts != [0.0, 0.0] {
            self.remote.mouse(0, counts[0] as i8, counts[1] as i8, 0);
        }
    }
}

impl Controller<'_> {
    /// One gyro sample during a pinch, in a profile with flicks: a flick's direction, once per
    /// flick. Uses the air mouse's frame and its learned gyro offset (`point` learns it first).
    fn flick(&mut self, raw: [f64; 3], now: f64, enabled: bool, hand: Option<Hand>) -> Option<Direction> {
        let pinching = self.menu.is_none() && (self.hold.is_some() && now - self.hold_seen < HOLD_LOST || self.pinch_down.is_some());
        let lab = control::lab_on();
        if !(enabled || lab) || !pinching {
            self.flicks.armed = false;
            self.flicks.swing = None;
            return None;
        }
        let [x, y] = draw::project(self.pointer.bias.rate(raw), RIGHT_PALM_DOWN_ROLL);
        let y = if hand == Some(Hand::Left) { -y } else { y };
        let rate = x.hypot(y);
        let flicks = &mut self.flicks;
        // The lab: each swing's peak, once it's over.
        if rate >= SWING_RATE {
            if flicks.swing.is_none_or(|(peak, ..)| rate > peak) {
                let fired = flicks.swing.is_some_and(|(.., fired)| fired);
                flicks.swing = Some((rate, x, y, fired));
            }
        } else if let Some((peak, px, py, fired)) = flicks.swing.take() {
            if lab { info!("LAB {} {} {peak:.0}", if fired { "flick" } else { "swing" }, Direction::of(px, py).name()); }
        }
        if rate < FLICK_REARM {
            flicks.armed = true;
            return None;
        }
        let (major, minor) = if x.abs() >= y.abs() { (x.abs(), y.abs()) } else { (y.abs(), x.abs()) };
        if !enabled || !flicks.armed || rate < FLICK_RATE || major < FLICK_DOMINANCE * minor { return None; }
        let direction = Direction::of(x, y);
        flicks.armed = false;
        if flicks.last.is_some_and(|(last, at)| last.opposite() == direction && now - at < FLICK_RETURN) { return None; }
        flicks.last = Some((direction, now));
        if let Some(swing) = flicks.swing.as_mut() { swing.3 = true; }
        // A pinch that flicked isn't index.hold when it lets go.
        if let Some(hold) = self.hold.as_mut() { hold.1 = true; }
        Some(direction)
    }
}

impl Drop for Controller<'_> {
    /// The band went away mid push-to-talk: don't leave ⌥Space held on the computer.
    fn drop(&mut self) {
        if let Some((handle, _)) = self.talking.take() { self.remote.release(handle); }
        self.end_switcher();
    }
}

impl Controller<'_> {
    /// One handwritten symbol, as keys. Letters are typed lowercase and o/0 as "o" (the band
    /// confuses them); the band's pause marker, shift and pinch symbols type nothing.
    /// Whether it typed anything.
    fn type_symbol(&mut self, index: usize) -> bool {
        use band_core::handwriting::{group, symbol, PAUSE, SPACE};
        let key = match index {
            PAUSE => return false,
            94 => (0, keys::BACKSPACE),
            95 => (0, keys::ENTER),
            _ if group(index) == SPACE => (0, keys::SPACE),
            _ => {
                let Some(c) = symbol(group(index)).chars().next() else { return false };
                match keys::for_char(c) { Some(key) => key, None => return false }
            }
        };
        info!("WRITE: {:?}", symbol(index));
        self.remote.send(Action::Key { modifiers: key.0, usage: key.1 });
        true
    }
}

/// The menu letter the band wrote: what it wrote if that's a menu letter ("1", "i" and "|" are
/// "l"), otherwise the menu letter it thought likeliest, if it thought it fairly likely.
fn menu_letter(written: &band_core::handwriting::Written) -> Option<char> {
    use band_core::handwriting::{group, symbol};
    let menu = crate::profiles::current().menu.keys().copied().collect::<Vec<char>>();
    let written_char = symbol(group(written.index)).chars().next()?.to_ascii_lowercase();
    let letter = match written_char { c if menu.contains(&c) => c, '1' | 'i' | '|' if menu.contains(&'l') => 'l', c => c };
    if menu.contains(&letter) {
        return Some(letter);
    }
    menu.into_iter().filter(char::is_ascii_lowercase)
        .map(|c| (c, written.letters[(c as u8 - b'a') as usize]))
        .max_by(|a, b| a.1.total_cmp(&b.1))
        .filter(|(_, odds)| *odds > 0.25)
        .map(|(c, _)| c)
}
