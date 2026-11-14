//! Band events in, host input out: what each gesture does in the active host's profile
//! (../np-profiles, PROFILES.md), the letter menu, handwriting typing and the air mouse,
//! push-to-talk, and the band's power (wrist motion and handwriting only while something uses them).

use band_core::controls::{draw, palm::RIGHT_PALM_DOWN_ROLL, pinch::{GyroBias, MAX_DT}};
use band_core::events::{Event, Hand};
use band_core::gestures::{GestureRouter, Recognized, Swipe, Tap};
use band_core::haptics::HapticsCommand;
use band_core::session::BandSession;
use log::{info, warn};
use np_profiles::{Action as Do, Button, Finger, Gesture, HostTarget, Media, Profile, Taps};

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
/// Seconds between a ringing call's buzzes (`buzz_ring`).
const RING_EVERY: f64 = 3.0;
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
        }
    }

    fn buzz(&mut self, now: f64, count: usize) {
        for i in 0..count {
            self.haptics.push_back((now + i as f64 * 0.25, HapticsCommand::Vibrate { duration_ms: 60, amplitude: 160 }));
        }
    }

    /// One long buzz: the menu didn't get a letter it knows.
    /// Unlike the short counts of a switch and the long buzz of a refusal: done is two firm
    /// pulses, a question two taps and a long one (rising, like a question), an error one very long.
    fn buzz_alert(&mut self, now: f64, alert: crate::remote::Alert) {
        use crate::remote::Alert;
        let pattern: &[(f64, u32, u8)] = match alert {
            Alert::Done => &[(0.0, 250, 200), (0.45, 250, 200)],
            Alert::Question => &[(0.0, 70, 170), (0.2, 70, 170), (0.4, 380, 220)],
            Alert::Error => &[(0.0, 900, 230)],
        };
        let start = now.max(self.alerts_until + ALERT_GAP);
        for &(at, duration_ms, amplitude) in pattern {
            self.haptics.push_back((start + at, HapticsCommand::Vibrate { duration_ms: duration_ms as _, amplitude: amplitude as _ }));
            self.alerts_until = self.alerts_until.max(start + at + duration_ms as f64 / 1000.0);
        }
    }

    /// A phone ringing: two long pulses, like a phone's (again every `RING_EVERY` while it rings).
    fn buzz_ring(&mut self, now: f64) {
        for at in [0.0, 0.9] {
            self.haptics.push_back((now + at, HapticsCommand::Vibrate { duration_ms: 600, amplitude: 230 }));
        }
    }

    fn buzz_long(&mut self, now: f64) {
        self.haptics.push_back((now, HapticsCommand::Vibrate { duration_ms: 400, amplitude: 200 }));
    }

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
                if self.perform(&action, Gesture::IndexHold, &set, now) && !switches { self.buzz(now, 1); }
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
                    self.buzz(now, 3);
                    return false;
                }
            }
            Do::Menu => {
                info!("MENU: open: write one letter");
                self.menu = Some(Menu { opened: now, writing_since: None });
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
        self.perform(&action, gesture, &active.set, now);
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
                // One short buzz: the band is connected to the dongle.
                self.buzz(now, 1);
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
                if message.finger == "index" && !message.synthetic {
                    if message.derived_action == "buttonHold" {
                        // A repeat of the same hold keeps its start (and whether it moved).
                        self.pointer_warm_until = now + POINTER_WARM;
                        if self.hold.is_none() || now - self.hold_seen > HOLD_LOST {
                            self.hold = Some((now, false));
                            self.pointer.moved = 0.0;
                            self.arm_dial = true;
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
                        self.haptics.push_back((now, HapticsCommand::Vibrate { duration_ms: 40, amplitude: 140 }));
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
                self.point(timestamp_us, gyro, now, active.as_ref().is_some_and(Active::points), hand);
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
            self.buzz(now, if kind == Kind::Phone { 1 } else { 2 });
        }
        if let Some(count) = self.remote.take_profile_switched() { self.buzz(now, count as usize); }
        if let Some(alert) = self.remote.take_alert() { self.buzz_alert(now, alert); }
        if crate::ancs::ringing() && now >= self.next_ring {
            self.buzz_ring(now);
            self.next_ring = now + RING_EVERY;
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
        let warm = active.as_ref().is_some_and(Active::points) && now < self.pointer_warm_until;
        let want_motion = (uses_motion && (warm || self.hold.is_some() && now - self.hold_seen < HOLD_LOST) && self.menu.is_none())
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
                    // Two buzzes: start writing; one: stopped. (The menu buzzes for itself.)
                    if !for_menu { self.buzz(now, if want { 2 } else { 1 }); }
                    return bytes;
                }
                Err(error) => {
                    warn!("handwriting: {error}");
                    if self.menu.is_some() {
                        // No handwriting now: a pinch hold switches host, as it did before the menu.
                        self.close_menu(now);
                        if !self.remote.step(true) { self.buzz(now, 3); }
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
                // Two buzzes: write the letter.
                self.buzz(now, 2);
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

impl Drop for Controller<'_> {
    /// The band went away mid push-to-talk: don't leave ⌥Space held on the computer.
    fn drop(&mut self) {
        if let Some((handle, _)) = self.talking.take() { self.remote.release(handle); }
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
