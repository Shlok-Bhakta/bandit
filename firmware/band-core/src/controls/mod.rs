//! The gesture layer shared by both apps: band events in, what to do out.
//!
//! It makes single, double and triple taps out of the band's taps, reads each pinch (a hold,
//! a dial, a drag gesture or a slider; see [`pinch`]), keeps the band controls (on/off,
//! next/previous profile) above the profiles, follows profiles (an app's own, the picked one,
//! the call layer) and asks the band for the configured hand. Pure like the rest of
//! band-core: no clock and no I/O; the caller passes `now` in seconds.

pub mod draw;
mod profiles;
pub mod palm;
pub mod pinch;
mod session;

pub use pinch::{Class, Drag};
pub use profiles::{
    BandControl, BandControls, Binding, Builtin, CallBinding, Dial, DragMode, Finger, FingerSetup, Gesture, Invalid, PalmSet,
    Paused, PausedSlider, Place, Profile, Profiles, Use, Warning,
};

pub use palm::{Palm, PalmCalibration, Palms};
use pinch::{GyroBias, Pinch, Prototypes, State, Step};
use profiles::{DragUse, Resolved, Runtime};
pub use session::{DRAW_DONE, DRAW_IDLE};
use session::{Ended, Session};

use crate::events::{Event, GestureMessage, Hand};
use crate::gestures::{ActionGate, DialRouter, GestureRouter};

/// How long a single tap waits for its double tap. On the band the second tap follows
/// 0.25–0.33 s after the first, and the double tap arrives with it.
pub const DOUBLE_TAP_WAIT: f64 = 0.4;
/// The most time between the taps of a triple tap (a little slower than a double).
pub const TRIPLE_TAP_GAP: f64 = 0.45;
/// A held single tap's second tap: its double tap comes right with it.
const DOUBLE_EXTEND: f64 = 0.08;
/// The band repeats a hold's message while it lasts (every ~0.3 s): one action per hold. A
/// hold message this long after the previous one is a new hold.
const HOLD_REPEAT: f64 = 1.0;
/// The third tap of a triple also reports a double tap, this soon.
const TRIPLE_ECHO: f64 = 0.15;
/// Index taps this soon after a dial or slider step, or after letting go of a pinch that
/// moved, was used (a drag gesture, an unknown move) or was lost, belong to that pinch.
const DIAL_STEP_QUIET: f64 = 0.6;
const DIAL_RELEASE_QUIET: f64 = 0.7;
/// No orientation this recent: assume the palm is down.
const ORIENTATION_STALE: f64 = 0.5;
/// Motion stopped this long: the pinch is lost.
const MOTION_LOST: f64 = 0.35;
/// A pinch shorter than this is a tap, never a hold (nor a stroke).
const HOLD_MIN: f64 = 0.3;
/// A pinch this old (since its press) is dropped, like the old dial's.
const PINCH_MAX_AGE: f64 = 10.0;
/// A finger's press this recent gives its tap's palm position (else the palm now). A live
/// pinch keeps its press's palm however long it lasts.
const PRESS_PALM_FRESH: f64 = 2.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum HandSetting {
    /// Whatever the band is set to.
    #[default]
    Band,
    Left,
    Right,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Options {
    pub hand: HandSetting,
    /// The controls start on.
    pub autostart: bool,
    /// 0.5–4 (see `DialRouter::turn`).
    pub dial_sensitivity: f64,
    /// Taught drag directions for the hand in use: the app passes the set taught on this band
    /// for that hand (per band and hand). `None`: the right hand's measured ones, or turns only
    /// for the left hand. A taught turn's + is the user's own, so the left hand's dial isn't
    /// reversed then.
    pub drags: Option<Prototypes>,
    /// Where palm down and up are; `None`: the right hand's measured ones, or no palm
    /// positions (always down) for the left hand.
    pub palm: Option<PalmCalibration>,
}

impl Default for Options {
    fn default() -> Self {
        Self { hand: HandSetting::Band, autostart: true, dial_sensitivity: 1.0, drags: None, palm: None }
    }
}

/// What the caller does next.
#[derive(Debug, Clone, PartialEq)]
pub enum Output<A> {
    /// A gesture was recognized (also while the controls are off, and in practice), with the
    /// palm position it was resolved in: a pinch's or a tap's press palm, a swipe's palm then
    /// (palm down without a fresh orientation or a calibration: see `Controls::palm`). What it
    /// did follows (`Run`, `Practiced`, `Controls`, `Profile`, `DrawStarted`, …), or `Unused`
    /// (at most one, never with an action). Teaching drags nothing acts (`Unused::Teaching`);
    /// in a draw session only the Draw gesture does, cancelling it (else `Unused::Drawing`).
    /// Writing in a text field only the Controls on/off band control does: the field edits
    /// with a gesture followed by `Unused::Writing` (with the controls off: `ControlsOff`).
    Gesture { gesture: Gesture, palm: Palm },
    /// The gesture just reported did nothing, and why.
    Unused { gesture: Gesture, why: Unused },
    /// A pinch that stepped a dial or a slider ended (let go, or dropped: too old, the
    /// controls paused, a draw session or drag teaching started): its finger, what it was
    /// (`Turn`, or the `Drag` whose pair's slider it moved), the palm at its press and how
    /// many steps it made each way. Each step also came as its own `Run`, or, `practiced`,
    /// `Practiced`.
    PinchEnded { finger: Finger, class: Class, palm: Palm, up: u32, down: u32, practiced: bool },
    /// Run this action.
    Run(A),
    /// The controls went on or off, by a gesture or a call to `pause` / `resume` / `toggle`.
    Controls { enabled: bool },
    /// The active profile changed: +1 next, −1 previous, 0 anything else.
    Profile { index: usize, step: i8 },
    /// Next/previous refused: the app in front has its own profile.
    ProfileHeld { app: String },
    /// Write this hand to the band.
    SetHand(Hand),
    /// Practice only: what would have run. Never execute it.
    Practiced(A),
    /// A drawing session started (the Draw band control, or `Controls::start_drawing`).
    DrawStarted,
    /// A point of the stroke being drawn (for the pad): stroke number from 0, degrees. Its
    /// first point is where the stroke starts (the strokes keep their places against each
    /// other). A stroke that's dropped (a tap, a pinch the band lost) isn't kept: the next
    /// stroke comes with its number again, and the pad draws it afresh.
    DrawPoint { stroke: usize, x: f64, y: f64 },
    /// The pad's pen went down or up. Down: a press that starts a stroke, just before the
    /// stroke's first `DrawPoint`. Up: the pen let go, or its stroke dropped (a tap, the band's
    /// synthetic release, a gap in the motion, down for `PINCH_MAX_AGE`); the other finger's
    /// press while the pen is down takes it over: up, then down. A session closed with the
    /// pen down (the Draw gesture, `cancel_drawing`, `pause`, `set_drag_teaching`) sends none:
    /// `DrawCancelled`, and the pad closes as it is. A pen dropped for its age does send one,
    /// and when that ends the session too it comes right before `DrawCancelled` in the same
    /// `poll`.
    Pen { down: bool },
    /// The session ended with these strokes. Then the match (`Drawn` or `NotDrawn`), except
    /// when teaching, or with the controls off outside practice (nothing would run).
    DrawFinished { strokes: Vec<draw::Stroke> },
    /// It matched this drawing, at this $P distance (its action follows as `Run`, or
    /// `Practiced` in practice). Only while the controls are on or in practice, not teaching.
    Drawn { name: String, distance: f64 },
    /// It matched nothing (the apps buzz twice).
    NotDrawn,
    /// Teaching drags: where this pinch moved (forearm frame, unit, at the decision
    /// distance). Nothing acts while teaching.
    DragSample { finger: Finger, direction: [f64; 3] },
    /// The Draw gesture again, `Controls::cancel_drawing`, `pause`, `set_drag_teaching`, or
    /// nothing drawn for `DRAW_IDLE`: no result. `on_disconnect` ends an open session too but
    /// can't report it: the apps also close the pad on a disconnect (and on
    /// `Controls { enabled: false }`).
    DrawCancelled,
}

/// Why a recognized gesture did nothing (see `Output::Unused`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unused {
    /// Nothing is bound to it here (this profile, the call layer and palm position).
    Unbound,
    /// The controls are off.
    ControlsOff,
    /// A band control is on it here, so the profile's action (if any) is paused, and the band
    /// control did nothing now (next or previous with one profile, or in practice).
    Paused(Builtin),
    /// The band only just connected, or another action ran a moment ago (the action gate).
    TooSoon,
    /// Drags are being taught (`Controls::set_drag_teaching`): nothing acts.
    Teaching,
    /// A draw session is open: only the Draw gesture acts there (it cancels).
    Drawing,
    /// Writing in a text field (`Controls::set_writing`): the gesture is the field's, only the
    /// Controls on/off band control acts.
    Writing,
}

/// What the pinch now down has stepped (see `Output::PinchEnded`).
#[derive(Debug, Clone, Copy)]
struct Stepped {
    class: Class,
    up: u32,
    down: u32,
    practiced: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ControlStatus<A> {
    /// The controls are off (the link can still be up).
    pub paused: bool,
    pub battery: Option<u8>,
    pub charging: Option<bool>,
    /// As the band confirmed it.
    pub hand: Option<Hand>,
    pub last_gesture: Option<&'static str>,
    /// The palm `last_gesture` was made with (a dial's or slider's: its pinch's press).
    pub last_palm: Option<Palm>,
    pub last_action: Option<A>,
    /// Gestures recognized since the controls were made.
    pub gestures: u64,
    /// The active profile.
    pub profile: usize,
    pub practice: bool,
}

impl<A> Default for ControlStatus<A> {
    fn default() -> Self {
        Self {
            paused: false,
            battery: None,
            charging: None,
            hand: None,
            last_gesture: None,
            last_palm: None,
            last_action: None,
            gestures: 0,
            profile: 0,
            practice: false,
        }
    }
}

/// A gesture held back while a longer one (its double or triple tap) may still come.
#[derive(Debug, Clone, Copy)]
struct Held {
    gesture: Gesture,
    fire_at: f64,
    received_at: f64,
    /// The profile active when it was made: it runs there.
    profile: usize,
    /// The palm position it was made with.
    palm: Palm,
}

/// Recent single taps of one finger, for its triple tap.
#[derive(Debug, Clone)]
struct Taps {
    at: Vec<f64>,
    finger: Option<Finger>,
    /// The palm of the sequence's first tap (its triple's palm).
    palm: Palm,
}

impl Taps {
    fn new() -> Self {
        Self { at: Vec::new(), finger: None, palm: Palm::Down }
    }
}

/// A press or release of the pen during a draw session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PenEvent {
    Press,
    /// `synthetic`: the band's own, when it lost the pinch.
    Release { synthetic: bool },
}

/// Whether `next`, held back, carries on what `old` held: the same finger's single tap again,
/// or its double tap.
fn continues(old: Gesture, next: Gesture) -> bool {
    old.finger().is_some_and(|finger| old == finger.single() && (next == finger.single() || next == finger.double()))
}

/// `Output::Pen { down: false }` when a session step put the pen up (it was down before).
fn pen_up<A>(was_down: bool, session: &Session) -> Option<Output<A>> {
    (was_down && !session.pen_down()).then_some(Output::Pen { down: false })
}

pub struct Controls<A> {
    options: Options,
    profiles: Profiles<A>,
    /// A runtime dial instead of the active profile's (`set_dial`), until `clear_dial` or a
    /// change of the active profile.
    dial_override: Option<Option<Dial<A>>>,
    foreground: Option<String>,
    in_call: bool,
    practice: bool,
    /// Writing in a text field (see `set_writing`).
    writing: bool,
    /// While writing: the gestures the field takes (the others act as usual), and whether dials
    /// and sliders step (see `set_writing_layer`).
    writing_takes: Vec<Gesture>,
    writing_dials: bool,
    router: GestureRouter,
    gate: ActionGate,
    dial_gate: ActionGate,
    dial_router: DialRouter,
    /// The controls are on.
    enabled: bool,
    /// The band's input subscription is up.
    live: bool,
    hand: Option<Hand>,
    hand_confirmed: bool,
    hand_requested: bool,
    /// The one automatic retry of a hand request has been used.
    hand_retry_used: bool,
    /// A runtime hand (`request_hand`) that wins over the options until they change.
    hand_override: Option<Hand>,
    bias: GyroBias,
    /// The drag directions for the hand in use (see `refresh_hand`).
    prototypes: Prototypes,
    /// Palm positions for the hand in use (see `refresh_hand`; `None`: always palm down).
    calibration: Option<PalmCalibration>,
    /// The band clock of the last gyro sample, and when it came.
    last_motion: Option<(u64, f64)>,
    /// The latest orientation and when it came.
    orientation: Option<([f32; 4], f64)>,
    pinch: Option<Pinch>,
    /// The palm position, tracked from the orientation (see `Controls::palm`).
    palm: Palm,
    /// The palm at each finger's last press, and when (see `Finger::slot`).
    press_palms: [Option<(Palm, f64)>; 2],
    /// What the pinch now down has stepped: its class, steps up and down (see
    /// `Output::PinchEnded`).
    pinch_steps: Option<Stepped>,
    dial_ended_at: f64,
    last_dial_action: f64,
    held: Option<Held>,
    taps: Taps,
    /// When a triple tap last fired, and whose (its third tap may also report a double).
    tripled_at: f64,
    tripled_finger: Option<Finger>,
    /// The last hold message per finger, `[index, middle]` (the band repeats them while a
    /// hold lasts).
    last_hold_message: [f64; 2],
    /// The taught drawings.
    library: draw::Library,
    /// Draw sessions report their strokes only (no match, nothing runs).
    teaching: bool,
    /// Every pinch reports where it moved; nothing acts.
    drag_teaching: bool,
    session: Option<Session>,
    status: ControlStatus<A>,
}

impl<A: Clone> Controls<A> {
    pub fn new(options: Options, mut profiles: Profiles<A>) -> Self {
        profiles.normalize();
        let enabled = options.autostart;
        let mut controls = Self {
            options,
            profiles,
            dial_override: None,
            foreground: None,
            in_call: false,
            practice: false,
            writing: false,
            writing_takes: Gesture::ALL.to_vec(),
            writing_dials: false,
            router: GestureRouter::default(),
            gate: ActionGate::default(),
            dial_gate: ActionGate::new(0.0),
            dial_router: DialRouter::default(),
            enabled,
            live: false,
            hand: None,
            hand_confirmed: false,
            hand_requested: false,
            hand_retry_used: false,
            hand_override: None,
            bias: GyroBias::default(),
            prototypes: Prototypes::right_hand(),
            calibration: None,
            last_motion: None,
            orientation: None,
            pinch: None,
            palm: Palm::Down,
            press_palms: [None; 2],
            pinch_steps: None,
            dial_ended_at: f64::NEG_INFINITY,
            last_dial_action: f64::NEG_INFINITY,
            held: None,
            taps: Taps::new(),
            tripled_at: f64::NEG_INFINITY,
            tripled_finger: None,
            last_hold_message: [f64::NEG_INFINITY; 2],
            library: draw::Library::default(),
            teaching: false,
            drag_teaching: false,
            session: None,
            status: ControlStatus { paused: !enabled, ..ControlStatus::default() },
        };
        controls.status.profile = controls.active();
        controls.refresh_hand();
        controls
    }

    pub fn status(&self) -> &ControlStatus<A> {
        &self.status
    }

    pub fn options(&self) -> &Options {
        &self.options
    }

    pub fn profiles(&self) -> &Profiles<A> {
        &self.profiles
    }

    /// The active profile's index.
    pub fn active(&self) -> usize {
        self.profiles.active(self.foreground.as_deref())
    }

    /// The index dial (the index finger's turn): the runtime override (`set_dial`), else the
    /// active profile's. `None`: the dial does nothing.
    pub fn dial(&self) -> Option<&Dial<A>> {
        match &self.dial_override {
            Some(dial) => dial.as_ref(),
            None => self.active_profile().index.dial.as_ref(),
        }
    }

    /// A runtime dial (`set_dial`) is in place of the active profile's.
    pub fn dial_overridden(&self) -> bool {
        self.dial_override.is_some()
    }

    pub fn in_call(&self) -> bool {
        self.in_call
    }

    /// The app in front, as last set.
    pub fn foreground(&self) -> Option<&str> {
        self.foreground.as_deref()
    }

    pub fn practice(&self) -> bool {
        self.practice
    }

    /// The band's input is up (connected, not yet disconnected).
    pub fn live(&self) -> bool {
        self.live
    }

    /// The controls are on.
    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// The drag directions in use (their palm-down roll follows `Options::palm`).
    pub fn prototypes(&self) -> &Prototypes {
        &self.prototypes
    }

    /// The palm position now: down without an orientation in the last 0.5 s, or without a
    /// calibration for the hand in use (the left hand's until calibrated).
    pub fn palm(&self, now: f64) -> Palm {
        match self.orientation {
            Some((_, at)) if now - at < ORIENTATION_STALE => self.palm,
            _ => Palm::Down,
        }
    }

    /// The taught drawings a draw session matches against.
    pub fn set_library(&mut self, library: draw::Library) {
        self.library = library;
    }

    /// Teaching: draw sessions report their strokes (`Output::DrawFinished`) without matching
    /// or running anything.
    pub fn set_teaching(&mut self, on: bool) {
        self.teaching = on;
    }

    /// Teach drags: a pinch that moved `pinch::DECIDE_AT` after `pinch::DECIDE_AFTER` reports
    /// `DragSample` (once), and nothing acts (holds, dials, drags, band controls, and no draw
    /// session opens); gestures are still reported. A pinch whose motion stops gives no
    /// sample and no hold. Either way, what was in progress (a pinch, a held tap, a tap
    /// sequence) is dropped; turning it on cancels an open draw session
    /// (`Output::DrawCancelled`).
    pub fn set_drag_teaching(&mut self, on: bool) -> Vec<Output<A>> {
        self.drag_teaching = on;
        let mut out = self.drop_pinch();
        self.held = None;
        self.taps.at.clear();
        self.reset_dial();
        if on {
            out.extend(self.cancel_drawing());
        }
        out
    }

    /// Drags are being taught (see `set_drag_teaching`).
    pub fn drag_teaching(&self) -> bool {
        self.drag_teaching
    }

    /// A draw session is open.
    pub fn drawing(&self) -> bool {
        self.session.is_some()
    }

    /// Open a draw session, as the Draw band control does (for the apps' teach screen): what
    /// was in progress (a pinch, a held tap, a tap sequence) is dropped. Nothing while one is
    /// open. It opens whether or not the controls are on; it's matched only while they are
    /// (its action runs) or in practice (it's practiced), else it reports its strokes only.
    /// Never while teaching drags.
    pub fn start_drawing(&mut self, now: f64) -> Vec<Output<A>> {
        if self.session.is_some() || self.drag_teaching {
            return Vec::new();
        }
        let mut out = self.drop_pinch();
        self.held = None;
        self.taps.at.clear();
        self.reset_dial();
        self.session = Some(Session::new(now));
        out.push(Output::DrawStarted);
        out
    }

    /// Cancel the open draw session (the pad's close button): `Output::DrawCancelled`, or
    /// nothing with none open.
    pub fn cancel_drawing(&mut self) -> Vec<Output<A>> {
        match self.session.take() {
            Some(_) => vec![Output::DrawCancelled],
            None => Vec::new(),
        }
    }

    /// New options (a reloaded config): a runtime hand from `request_hand` is dropped, the
    /// hand is requested afresh, the dial re-arms. When the drag directions or the palm
    /// calibration in effect change, a pinch in progress is lost as if its motion stopped (see
    /// `set_calibration`): a still finger's hold still comes.
    pub fn set_options(&mut self, options: Options) -> Vec<Output<A>> {
        self.options = options;
        self.hand_override = None;
        self.refresh_hand();
        self.hand_requested = false;
        self.hand_retry_used = false;
        self.reset_dial();
        self.maybe_request_hand()
    }

    /// A new palm calibration and taught drags (`Options::palm`, `Options::drags`): the caller
    /// keeps one of each per band and hand, and passes the ones for the band and hand now in
    /// use. Unlike `set_options`, the hand stays (a runtime one from `request_hand` too), as
    /// does any request for it and its retry, and nothing is written to the band. The palm is
    /// read afresh from the last orientation. When the drag directions or the palm
    /// calibration in effect change, a pinch in progress is lost as if its motion stopped (it
    /// was read against the old ones): nothing more comes of it, but a still finger's hold
    /// (one whose moves do nothing) still comes. A held tap and a tap sequence keep the palm
    /// they were made with.
    pub fn set_calibration(&mut self, palm: Option<PalmCalibration>, drags: Option<Prototypes>) {
        self.options.palm = palm;
        self.options.drags = drags;
        self.refresh_hand();
    }

    /// New bindings (a profile edited, added or removed). A pinch, a held tap and a triple
    /// tap in progress carry on. Reports `Output::Profile` (step 0) when the active profile
    /// changed.
    pub fn set_profiles(&mut self, mut profiles: Profiles<A>) -> Vec<Output<A>> {
        let before = self.active();
        profiles.normalize();
        self.profiles = profiles;
        self.switched(before, 0)
    }

    /// Turn the dial with these actions instead of the active profile's (`None`: not at all),
    /// until `clear_dial` or until the active profile changes (the new one's dial then applies).
    pub fn set_dial(&mut self, dial: Option<Dial<A>>) {
        self.dial_override = Some(dial);
        self.reset_dial();
    }

    /// Back to the active profile's dial.
    pub fn clear_dial(&mut self) {
        self.dial_override = None;
        self.reset_dial();
    }

    /// The app in front (its own profile, if it has one, becomes the active one).
    pub fn set_foreground(&mut self, app: Option<String>) -> Vec<Output<A>> {
        let before = self.active();
        self.foreground = app;
        self.switched(before, 0)
    }

    pub fn set_in_call(&mut self, in_call: bool) {
        self.in_call = in_call;
    }

    /// Practice: gestures and what they'd run are reported, nothing runs and band controls
    /// don't act.
    pub fn set_practice(&mut self, practice: bool) {
        self.practice = practice;
        self.status.practice = practice;
    }

    /// Writing in a text field: gestures are reported for editing and no actions run; only the
    /// Controls on/off band control acts. Every other gesture is followed by `Unused::Writing`
    /// (`ControlsOff` while the controls are off: nothing to edit with); no dial or slider
    /// steps, and next, previous and Draw don't act. It wins over practice. Teaching drags and
    /// an open draw session still go by their own rules (`start_drawing` still opens one).
    pub fn set_writing(&mut self, on: bool) {
        self.writing = on;
    }

    /// While writing, which gestures are the field's ([`Output::Unused`] `Writing`, as
    /// `set_writing` says) and whether dials and sliders still step; every other gesture does
    /// what it does in the profile. Every gesture and no dials until set.
    pub fn set_writing_layer(&mut self, takes: Vec<Gesture>, dials: bool) {
        self.writing_takes = takes;
        self.writing_dials = dials;
    }

    /// Writing in a text field (see `set_writing`).
    pub fn writing(&self) -> bool {
        self.writing
    }

    /// Handwriting goes into the text field: writing, with the controls on and the band live.
    /// While not, the caller drops what the band wrote (`BandSession::take_written`, taken
    /// anyway so it doesn't type later).
    pub fn writes(&self) -> bool {
        self.writing && self.enabled && self.live
    }

    /// Pick a profile (from the app's UI or IPC).
    pub fn pick(&mut self, index: usize) -> Vec<Output<A>> {
        if index >= self.profiles.list.len() {
            return Vec::new();
        }
        let before = self.active();
        self.profiles.picked = index;
        self.switched(before, 0)
    }

    pub fn pause(&mut self) -> Vec<Output<A>> {
        if !self.enabled {
            return Vec::new();
        }
        self.enabled = false;
        self.status.paused = true;
        let mut out = self.suspend();
        out.push(Output::Controls { enabled: false });
        out
    }

    pub fn resume(&mut self, now: f64) -> Vec<Output<A>> {
        if self.enabled {
            return Vec::new();
        }
        self.enabled = true;
        self.status.paused = false;
        if self.live {
            self.gate.arm(now);
        }
        self.reset_dial();
        vec![Output::Controls { enabled: true }]
    }

    pub fn toggle(&mut self, now: f64) -> Vec<Output<A>> {
        if self.enabled { self.pause() } else { self.resume(now) }
    }

    /// Write this hand now (e.g. from the control socket); wins until the options change.
    /// When that changes the drag directions or the palm calibration in effect (before the
    /// band confirms a hand, the calibration follows the requested one), a pinch in progress
    /// is lost as if its motion stopped (see `set_calibration`): a still finger's hold still
    /// comes.
    pub fn request_hand(&mut self, hand: Hand) -> Vec<Output<A>> {
        self.hand_override = Some(hand);
        self.refresh_hand();
        self.hand_requested = false;
        self.hand_retry_used = false;
        self.maybe_request_hand()
    }

    /// The band is gone. An open draw session ends without a report (see
    /// `Output::DrawCancelled`), and so does a pinch that stepped (no `Output::PinchEnded`).
    pub fn on_disconnect(&mut self) {
        self.live = false;
        self.hand = None;
        self.refresh_hand();
        self.hand_confirmed = false;
        self.hand_requested = false;
        self.hand_retry_used = false;
        // Nowhere to report a cancelled draw session: the apps close the pad on a disconnect
        // (see `Output::DrawCancelled`).
        let _cancelled = self.suspend();
        self.held = None;
        self.taps = Taps::new();
        self.router.reset();
        self.status.charging = None;
    }

    pub fn on_event(&mut self, event: &Event, now: f64) -> Vec<Output<A>> {
        match event {
            Event::Connected => {
                self.live = true;
                if self.enabled {
                    self.gate.arm(now);
                }
                self.maybe_request_hand()
            }
            Event::Handedness(hand) => {
                self.hand = Some(*hand);
                self.refresh_hand();
                self.hand_confirmed = true;
                self.status.hand = Some(*hand);
                // The band still disagrees with an outstanding request: the write may
                // have been lost or refused. Retry once.
                if self.hand_requested
                    && !self.hand_retry_used
                    && self.desired_hand().is_some_and(|wanted| wanted != *hand)
                {
                    self.hand_retry_used = true;
                    self.hand_requested = false;
                }
                self.maybe_request_hand()
            }
            Event::HandednessFailure(_) => {
                self.hand_confirmed = false;
                Vec::new()
            }
            Event::BatteryStatus(Some(battery)) => {
                self.status.battery = Some(battery.level);
                self.status.charging = battery.charging;
                Vec::new()
            }
            Event::BatteryStatus(None) => {
                self.status.charging = None;
                Vec::new()
            }
            Event::Gesture(message) => self.gesture(message, now),
            Event::Motion { timestamp_us, gyro } => self.motion(*timestamp_us, *gyro, now),
            Event::Orientation(q) => {
                self.orientation = Some((*q, now));
                self.read_palm();
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    /// When a held gesture or the draw session is due (then call `poll`). A pinch's timeouts
    /// (its age, its motion stopping) apply on the next `poll` or event.
    pub fn next_deadline(&self) -> Option<f64> {
        let session = self.session.as_ref().map(Session::deadline);
        match (self.held.map(|held| held.fire_at), session) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    /// Run a held gesture whose longer form never came, and end a draw session that's done.
    /// Also drops a pinch older than 10 s and loses one whose motion stopped.
    pub fn poll(&mut self, now: f64) -> Vec<Output<A>> {
        if self.session.is_some() {
            return self.poll_session(now);
        }
        let mut out = self.drop_old_pinch(now);
        if self.motion_stopped_during_pinch(now) {
            self.lose_pinch();
        }
        if let Some(held) = self.held.filter(|held| now >= held.fire_at) {
            self.held = None;
            out.extend(self.fire(held, now));
        }
        out
    }

    /// What this gesture does now, in the active profile.
    fn resolve(&self, gesture: Gesture, palm: Palm) -> Option<Resolved<'_, A>> {
        self.resolve_in(self.active(), gesture, palm)
    }

    /// What this gesture does in this profile (the active one if it is gone): see
    /// `Profiles::resolve`.
    fn resolve_in(&self, profile: usize, gesture: Gesture, palm: Palm) -> Option<Resolved<'_, A>> {
        let profile = if profile < self.profiles.list.len() { profile } else { self.active() };
        self.profiles.resolve(profile, gesture, palm, self.runtime())
    }

    /// Whether this gesture would do anything in the active profile (a profile switch needs
    /// 2+ profiles and no app holding its own).
    fn does_something(&self, gesture: Gesture, palm: Palm) -> bool {
        self.profiles.does_something(self.active(), gesture, palm, self.runtime())
    }

    /// The live extras for the profiles' rules (see `profiles::Runtime`).
    fn runtime(&self) -> Runtime {
        Runtime {
            dial_override: self.dial_override.as_ref().map(Option::is_some),
            turns_only: self.prototypes.drags.is_none(),
            in_call: self.in_call,
            held: self.profiles.held_by(self.foreground.as_deref()).is_some(),
        }
    }

    fn gesture(&mut self, message: &GestureMessage, now: f64) -> Vec<Output<A>> {
        // A held gesture already due goes first: the caller's poll may come late.
        let mut out = self.poll(now);
        out.extend(self.pinch_message(message, now));
        let Some(recognized) = self.router.gesture(message, now) else {
            return out;
        };
        let gesture = Gesture::of(recognized);
        let received = message.received_at;
        let hold_finger = match gesture {
            Gesture::IndexHold => Some(Finger::Index),
            Gesture::MiddleHold => Some(Finger::Middle),
            _ => None,
        };
        // Also in a draw session (the pen's hold): its repeats after the session aren't a new hold.
        let new_hold = hold_finger.is_some_and(|finger| {
            let last = &mut self.last_hold_message[finger.slot()];
            let new_hold = now - *last >= HOLD_REPEAT;
            *last = now;
            new_hold
        });
        if self.session.is_some() {
            out.extend(self.session_gesture(gesture, now));
            return out;
        }
        // Letting go of a wrist turn must not also be an index tap.
        if matches!(gesture, Gesture::IndexTap | Gesture::IndexDouble)
            && (now - self.last_dial_action <= DIAL_STEP_QUIET || now - self.dial_ended_at <= DIAL_RELEASE_QUIET)
        {
            return out;
        }
        if let Some(finger) = hold_finger {
            if new_hold {
                out.extend(self.hold_message(finger, received, now));
            }
            return out;
        }
        if let Some(finger) = gesture.finger() {
            // The third tap's own double tap: part of the triple, whatever the profile it
            // switched to binds.
            if gesture == finger.double() && self.tripled_finger == Some(finger) && now - self.tripled_at < TRIPLE_ECHO {
                return out;
            }
            let palm = self.press_palm(finger, now);
            // A tap sequence's triple has its first tap's palm.
            let new_sequence = self.taps.finger != Some(finger)
                || self.taps.at.is_empty()
                || self.taps.at.last().is_some_and(|&last| now - last > TRIPLE_TAP_GAP);
            let sequence_palm = if new_sequence { palm } else { self.taps.palm };
            if self.does_something(finger.triple(), sequence_palm) {
                if gesture == finger.single() {
                    if new_sequence {
                        self.taps = Taps { at: Vec::new(), finger: Some(finger), palm };
                    }
                    self.taps.at.push(now);
                    if self.taps.at.len() >= 3 {
                        self.taps.at.clear();
                        // This finger's held tap is part of the triple; another finger's runs.
                        if let Some(held) = self.held.take()
                            && held.gesture.finger() != Some(finger)
                        {
                            out.extend(self.fire(held, now));
                        }
                        self.tripled_at = now;
                        self.tripled_finger = Some(finger);
                        out.extend(self.dispatch_now(finger.triple(), received, now, sequence_palm));
                        return out;
                    }
                } else {
                    // This double tap may be the start of a triple tap.
                    let held = Held { gesture, fire_at: now + TRIPLE_TAP_GAP, received_at: received, profile: self.active(), palm };
                    out.extend(self.hold(held, now));
                    return out;
                }
            }
            // A double tap supersedes the single tap(s) it was made of.
            if gesture == finger.double() && self.held.is_some_and(|held| held.gesture == finger.single()) {
                self.held = None;
            }
            // A single tap waits to see whether it is the start of its double tap; with a
            // triple tap in play it waits out the whole triple (slow taps come without the
            // band's double tap), else a triple would also run it.
            if gesture == finger.single() && self.does_something(gesture, palm) {
                let triple = self.does_something(finger.triple(), sequence_palm);
                if triple || self.does_something(finger.double(), palm) {
                    match &mut self.held {
                        Some(held) if held.gesture == gesture => {
                            held.fire_at = held.fire_at.max(now + if triple { TRIPLE_TAP_GAP } else { DOUBLE_EXTEND })
                        }
                        _ => {
                            let fire_at = now + if triple { TRIPLE_TAP_GAP } else { DOUBLE_TAP_WAIT };
                            let held = Held { gesture, fire_at, received_at: received, profile: self.active(), palm };
                            out.extend(self.hold(held, now));
                        }
                    }
                    return out;
                }
            }
            out.extend(self.dispatch_now(gesture, received, now, palm));
            return out;
        }
        // A swipe: the palm now.
        let palm = self.palm(now);
        out.extend(self.dispatch_now(gesture, received, now, palm));
        out
    }

    /// Hold this gesture back. What was held before runs first, unless this continues it
    /// (the same finger's single tap again, or its double tap).
    fn hold(&mut self, held: Held, now: f64) -> Vec<Output<A>> {
        let out = match self.held.take() {
            Some(old) if !continues(old.gesture, held.gesture) => self.fire(old, now),
            _ => Vec::new(),
        };
        self.held = Some(held);
        out
    }

    /// Run a held gesture. The tap sequence it was waiting on is over.
    fn fire(&mut self, held: Held, now: f64) -> Vec<Output<A>> {
        if held.gesture.finger().is_some() && held.gesture.finger() == self.taps.finger {
            self.taps.at.clear();
        }
        self.dispatch(held.gesture, held.received_at, now, true, held.profile, held.palm)
    }

    /// [`Self::dispatch`] of a gesture made just now, in the active profile.
    fn dispatch_now(&mut self, gesture: Gesture, received_at: f64, now: f64, palm: Palm) -> Vec<Output<A>> {
        self.dispatch(gesture, received_at, now, false, self.active(), palm)
    }

    /// A recognized gesture: report it, then do what it does in `profile` with the palm this way
    /// if the rules allow.
    fn dispatch(&mut self, gesture: Gesture, received_at: f64, now: f64, was_held: bool, profile: usize, palm: Palm) -> Vec<Output<A>> {
        self.status.gestures += 1;
        self.status.last_gesture = Some(gesture.label());
        self.status.last_palm = Some(palm);
        let mut out = vec![Output::Gesture { gesture, palm }];
        // Teaching drags: reported only.
        if self.drag_teaching {
            out.push(Output::Unused { gesture, why: Unused::Teaching });
            return out;
        }
        // Writing in a text field: the field's (the ones it takes), unless it's Controls on/off.
        if self.writing && self.writing_takes.contains(&gesture) && !matches!(self.resolve_in(profile, gesture, palm), Some(Resolved::Band(Builtin::Controls))) {
            out.push(Output::Unused { gesture, why: if self.enabled { Unused::Writing } else { Unused::ControlsOff } });
            return out;
        }
        let did = match self.resolve_in(profile, gesture, palm) {
            None => Err(Unused::Unbound),
            Some(Resolved::Band(builtin)) => {
                let did = self.band_control(builtin, now);
                if did.is_empty() { Err(self.band_control_unused(builtin)) } else { Ok(did) }
            }
            Some(Resolved::Run(action)) => {
                let action = action.clone();
                let did = self.run(action, received_at, now, was_held);
                if did.is_empty() { Err(if self.enabled { Unused::TooSoon } else { Unused::ControlsOff }) } else { Ok(did) }
            }
        };
        match did {
            Ok(did) => out.extend(did),
            Err(why) => out.push(Output::Unused { gesture, why }),
        }
        out
    }

    /// Why this band control did nothing (see `band_control`).
    fn band_control_unused(&self, builtin: Builtin) -> Unused {
        if !self.live {
            return Unused::TooSoon;
        }
        match builtin {
            Builtin::Controls => Unused::Paused(builtin),
            _ if !self.enabled && !self.practice => Unused::ControlsOff,
            _ => Unused::Paused(builtin),
        }
    }

    /// A band control: never while the band is down; Draw while the controls are on or in
    /// practice (teaching runs there); the others never in practice (Controls on/off does
    /// while writing), next/previous only while the controls are on.
    fn band_control(&mut self, builtin: Builtin, now: f64) -> Vec<Output<A>> {
        if !self.live {
            return Vec::new();
        }
        match builtin {
            Builtin::Draw if self.enabled || self.practice => self.toggle_draw(now),
            Builtin::Draw => Vec::new(),
            Builtin::Controls if self.writing => self.toggle(now),
            _ if self.practice => Vec::new(),
            Builtin::Controls => self.toggle(now),
            _ if !self.enabled => Vec::new(),
            Builtin::NextProfile => self.step(1),
            Builtin::PreviousProfile => self.step(-1),
        }
    }

    /// The Draw band control: open a draw session, or cancel the open one.
    fn toggle_draw(&mut self, now: f64) -> Vec<Output<A>> {
        if self.session.is_some() { self.cancel_drawing() } else { self.start_drawing(now) }
    }

    /// A recognized gesture during a draw session: reported, and only the Draw band control
    /// acts (it cancels). A hold is the pen itself: nothing.
    fn session_gesture(&mut self, gesture: Gesture, now: f64) -> Vec<Output<A>> {
        if matches!(gesture, Gesture::IndexHold | Gesture::MiddleHold) {
            return Vec::new();
        }
        self.status.gestures += 1;
        self.status.last_gesture = Some(gesture.label());
        let palm = gesture.finger().map_or_else(|| self.palm(now), |finger| self.press_palm(finger, now));
        self.status.last_palm = Some(palm);
        let mut out = vec![Output::Gesture { gesture, palm }];
        if !matches!(self.resolve(gesture, palm), Some(Resolved::Band(Builtin::Draw))) {
            out.push(Output::Unused { gesture, why: Unused::Drawing });
            return out;
        }
        let did = self.band_control(Builtin::Draw, now);
        if did.is_empty() {
            out.push(Output::Unused { gesture, why: self.band_control_unused(Builtin::Draw) });
        }
        out.extend(did);
        out
    }

    /// The pinch frame's roll from a fresh orientation.
    fn fresh_roll(&self, now: f64) -> Option<f64> {
        self.orientation.filter(|(_, at)| now - at < ORIENTATION_STALE).map(|(q, _)| self.prototypes.roll_for(Some(q)))
    }

    /// A press or release during a draw session (see `Session::press` and `Session::release`):
    /// pen down at the cursor (`Output::Pen`), reported as the stroke's first point; pen up.
    /// The pen's finger's synthetic release drops its stroke. The other finger's press while
    /// the pen is down drops it too and is the pen from then on (up, then down): normally the
    /// band sends the pen's synthetic release first, so that's the fallback for a lost release.
    fn pen_message(&mut self, finger: Finger, event: PenEvent, now: f64) -> Vec<Output<A>> {
        let roll = self.fresh_roll(now).unwrap_or(self.prototypes.palm_down_roll);
        let Some(session) = &mut self.session else { return Vec::new() };
        let was_down = session.pen_down();
        match event {
            PenEvent::Release { synthetic } => {
                session.release(finger, synthetic, now);
                pen_up(was_down, session).into_iter().collect()
            }
            PenEvent::Press => match session.press(finger, roll, now) {
                Some([x, y]) => {
                    // `pen_up` can't tell a takeover: the pen is down again by now, so the
                    // other finger's up is the pen having been down before.
                    let mut out: Vec<_> = was_down.then_some(Output::Pen { down: false }).into_iter().collect();
                    out.push(Output::Pen { down: true });
                    out.push(Output::DrawPoint { stroke: session.stroke(), x, y });
                    out
                }
                None => Vec::new(),
            },
        }
    }

    /// A gyro step during a draw session (see `Session::motion`): with the pen down, the next
    /// point of its stroke. The gyro bias isn't learned in a session.
    fn pen_motion(&mut self, raw: [f64; 3], dt: f64, now: f64) -> Vec<Output<A>> {
        let step = self.bias.rate(raw).map(|r| r * dt);
        // The cursor's roll, with the pen up.
        let fresh_roll = match &self.session {
            Some(session) if !session.pen_down() => self.fresh_roll(now),
            _ => None,
        };
        match self.session.as_mut().and_then(|session| session.motion(step, fresh_roll)) {
            Some((stroke, [x, y])) => vec![Output::DrawPoint { stroke, x, y }],
            None => Vec::new(),
        }
    }

    /// The draw session's timeouts (see `Session::expire`): a pen down too long goes up;
    /// with no stroke it's cancelled; with strokes it finishes, and is matched unless
    /// teaching or with the controls off outside practice (nothing would run).
    fn poll_session(&mut self, now: f64) -> Vec<Output<A>> {
        let Some(session) = &mut self.session else { return Vec::new() };
        let was_down = session.pen_down();
        let ended = session.expire(now);
        let mut out: Vec<_> = pen_up(was_down, session).into_iter().collect();
        if let Some(ended) = ended {
            self.session = None;
            out.extend(self.end_session(ended, now));
        }
        out
    }

    /// The session ended by itself (see `poll_session`).
    fn end_session(&mut self, ended: Ended, now: f64) -> Vec<Output<A>> {
        let strokes = match ended {
            Ended::Cancelled => return vec![Output::DrawCancelled],
            Ended::Finished(strokes) => strokes,
        };
        if self.teaching || !(self.enabled || self.practice) {
            return vec![Output::DrawFinished { strokes }];
        }
        let active = self.active();
        let profiles = &self.profiles;
        let drawn = self.library.recognize(&strokes, |name| profiles.drawing_action(active, name).is_some());
        let mut out = vec![Output::DrawFinished { strokes }];
        let Some(drawn) = drawn else {
            out.push(Output::NotDrawn);
            return out;
        };
        let action = self.profiles.drawing_action(active, &drawn.name).cloned().expect("only drawings with an action match");
        out.push(Output::Drawn { name: drawn.name, distance: drawn.distance });
        out.extend(self.run(action, now, now, false));
        out
    }

    /// An action to run: reported only in practice, run while the controls are on and the
    /// gate allows it.
    fn run(&mut self, action: A, received_at: f64, now: f64, was_held: bool) -> Vec<Output<A>> {
        if self.practice {
            return vec![Output::Practiced(action)];
        }
        if !self.enabled {
            return Vec::new();
        }
        let allowed = if was_held {
            self.gate.allows_held(received_at, true, now, self.live)
        } else {
            self.gate.allows(received_at, now, self.live, true)
        };
        if !allowed {
            return Vec::new();
        }
        self.status.last_action = Some(action.clone());
        vec![Output::Run(action)]
    }

    /// Next (+1) or previous (−1) profile, wrapping around.
    fn step(&mut self, step: i8) -> Vec<Output<A>> {
        if let Some(app) = self.profiles.held_by(self.foreground.as_deref()) {
            return vec![Output::ProfileHeld { app: app.to_owned() }];
        }
        let count = self.profiles.list.len();
        if count < 2 {
            return Vec::new();
        }
        let before = self.active();
        self.profiles.picked = (self.profiles.picked as isize + isize::from(step)).rem_euclid(count as isize) as usize;
        self.switched(before, step)
    }

    fn switched(&mut self, before: usize, step: i8) -> Vec<Output<A>> {
        let index = self.active();
        self.status.profile = index;
        if index == before {
            return Vec::new();
        }
        // A runtime dial belonged to the profile it was set in.
        self.dial_override = None;
        vec![Output::Profile { index, step }]
    }

    /// After the hand or the options changed: the options' taught drags, else the measured ones
    /// for the hand in use, read with the calibration's palm down when there is one; the
    /// calibration in effect; and the palm read afresh (down without a calibration). When the
    /// drag directions or the calibration changed, a pinch in progress was read against the
    /// old ones: it's lost as if its motion stopped (see `lose_pinch`).
    fn refresh_hand(&mut self) {
        let mut prototypes = match (&self.options.drags, self.hand) {
            (Some(taught), _) => taught.clone(),
            (None, Some(Hand::Left)) => Prototypes::turns_only(),
            (None, _) => Prototypes::right_hand(),
        };
        if let Some(calibration) = self.options.palm {
            prototypes.palm_down_roll = calibration.down_roll;
        }
        let calibration = self.calibration_for_hand();
        let changed = prototypes != self.prototypes || calibration != self.calibration;
        self.prototypes = prototypes;
        self.calibration = calibration;
        self.read_palm();
        if changed {
            self.lose_pinch();
        }
    }

    /// The palm position from the last orientation (however old: `palm` checks), against the
    /// calibration in effect; down without one. An orientation that doesn't show the roll (a
    /// non-finite one) keeps the previous position.
    fn read_palm(&mut self) {
        let Some(calibration) = self.calibration else {
            self.palm = Palm::Down;
            return;
        };
        if let Some((q, _)) = self.orientation {
            self.palm = calibration.position(pinch::roll_or(pinch::up_in_band(q), f64::NAN), self.palm);
        }
    }

    fn active_profile(&self) -> &Profile<A> {
        &self.profiles.list[self.active()]
    }

    /// This finger's dial: the index one with the runtime override (see [`Self::dial`]).
    fn finger_dial(&self, finger: Finger) -> Option<&Dial<A>> {
        match finger {
            Finger::Index => self.dial(),
            Finger::Middle => self.active_profile().middle.dial.as_ref(),
        }
    }

    /// Palm positions for the hand in use, or the configured one before the band says
    /// (`None`: none known, so every gesture is palm down). `refresh_hand` keeps it in
    /// `calibration`.
    fn calibration_for_hand(&self) -> Option<PalmCalibration> {
        if self.options.palm.is_some() {
            return self.options.palm;
        }
        match self.hand.or_else(|| self.desired_hand()) {
            Some(Hand::Left) => None,
            _ => Some(PalmCalibration::right_hand()),
        }
    }

    /// The palm a gesture of this finger was made with: its live pinch's (at the press), else
    /// its recent press's (a tap), else now.
    fn press_palm(&self, finger: Finger, now: f64) -> Palm {
        if let Some(pinch) = self.pinch.as_ref().filter(|p| p.finger() == finger) {
            return pinch.palm();
        }
        match self.press_palms[finger.slot()] {
            Some((palm, at)) if now - at < PRESS_PALM_FRESH => palm,
            _ => self.palm(now),
        }
    }

    /// The band's press or release of a pinch (before the router, which ignores them).
    fn pinch_message(&mut self, message: &GestureMessage, now: f64) -> Vec<Output<A>> {
        let finger = match message.finger.as_str() {
            "index" => Finger::Index,
            "middle" => Finger::Middle,
            _ => return Vec::new(),
        };
        let press = message.action == "press" || message.derived_action == "buttonPress";
        let released = message.action == "release"
            || message.derived_action == "buttonRelease"
            || message.derived_action == "buttonHoldRelease";
        let palm = self.palm(now);
        // Also in a draw session: the Draw gesture there has its own press's palm.
        if press && !message.synthetic {
            self.press_palms[finger.slot()] = Some((palm, now));
        }
        if self.session.is_some() {
            // The band's synthetic messages end a pinch, never start one.
            let event = match (press, released) {
                (true, _) if !message.synthetic => PenEvent::Press,
                (_, true) => PenEvent::Release { synthetic: message.synthetic },
                _ => return Vec::new(),
            };
            return self.pen_message(finger, event, now);
        }
        if message.synthetic {
            return Vec::new();
        }
        if press && self.pinch.is_none() {
            let roll = self.fresh_roll(now).unwrap_or(self.prototypes.palm_down_roll);
            self.pinch = Some(Pinch::new(finger, now, roll, palm));
            self.pinch_steps = None;
        }
        if !released || !self.pinch.as_ref().is_some_and(|p| p.finger() == finger) {
            return Vec::new();
        }
        let done = self.pinch.take().expect("checked");
        let mut out = self.pinch_ended(&done);
        // Its hold already acted.
        if done.held() {
            return out;
        }
        match done.state() {
            State::Undecided if done.saw_hold() || now - done.pressed_at() >= HOLD_MIN => {
                out.extend(self.dispatch_now(Gesture::hold(finger), message.received_at, now, done.palm()))
            }
            // Let go too soon: a tap, which the band reports itself.
            State::Undecided => {}
            // It moved, was used or was lost: its release is not an index tap.
            State::Decided(_) | State::Done => self.dial_ended_at = now,
        }
        out
    }

    /// What this finger's drag does in the active profile.
    fn drag_use(&self, finger: Finger, drag: Drag, palm: Palm) -> DragUse<'_, A> {
        self.profiles.drag_use(self.active(), finger, drag, palm)
    }

    /// Whether this finger's pinch-and-move does anything with the palm this way (else its
    /// hold acts at once): `Profiles::hold_waits` in the active profile, with the runtime
    /// dial, turns-only drag directions, the call layer and an app holding its profile.
    fn moves_do_something(&self, finger: Finger, palm: Palm) -> bool {
        self.profiles.hold_waits_with(self.active(), finger, palm, self.runtime())
    }

    /// The band's hold message for a finger: at once if nothing else can come of the pinch,
    /// else at the release (see `pinch_message`).
    fn hold_message(&mut self, finger: Finger, received: f64, now: f64) -> Vec<Output<A>> {
        // Teaching drags: the pinch goes on (its hold is reported at the release).
        if self.drag_teaching {
            if let Some(p) = self.pinch.as_mut().filter(|p| p.finger() == finger) {
                p.mark_saw_hold();
            }
            return Vec::new();
        }
        let palm = self.press_palm(finger, now);
        let fast = !self.moves_do_something(finger, palm);
        if let Some(p) = self.pinch.as_mut().filter(|p| p.finger() == finger) {
            p.mark_saw_hold();
            // The fast hold acts whatever the motion did (it's ignored for this finger, and
            // may have gone quiet).
            if !fast || p.held() {
                return Vec::new();
            }
            p.mark_held();
        }
        self.dispatch_now(Gesture::hold(finger), received, now, palm)
    }

    /// No gyro sample for `MOTION_LOST`, the last one after the pinch's press.
    fn motion_stopped_during_pinch(&self, now: f64) -> bool {
        match (&self.pinch, self.last_motion) {
            (Some(p), Some((_, at))) => at >= p.pressed_at() && now - at >= MOTION_LOST,
            _ => false,
        }
    }

    /// The pinch's motion stopped: it's lost, unless its finger's moves do nothing (then motion
    /// never mattered, and its hold still comes at the hold message or the release). Teaching
    /// drags, motion always matters: it's lost.
    fn lose_pinch(&mut self) {
        let Some((finger, palm)) = self.pinch.as_ref().map(|p| (p.finger(), p.palm())) else {
            return;
        };
        if (self.drag_teaching || self.moves_do_something(finger, palm))
            && let Some(p) = &mut self.pinch
        {
            p.finish();
        }
    }

    /// A pinch older than `PINCH_MAX_AGE` is dropped (its release, if it ever comes, is nothing).
    fn drop_old_pinch(&mut self, now: f64) -> Vec<Output<A>> {
        if self.pinch.as_ref().is_some_and(|p| now - p.pressed_at() >= PINCH_MAX_AGE) {
            return self.drop_pinch();
        }
        Vec::new()
    }

    /// The pinch down is dropped: what it stepped, if anything (see `Output::PinchEnded`).
    fn drop_pinch(&mut self) -> Vec<Output<A>> {
        match self.pinch.take() {
            Some(pinch) => self.pinch_ended(&pinch),
            None => Vec::new(),
        }
    }

    /// `Output::PinchEnded` for this pinch, if it stepped (then forgotten).
    fn pinch_ended(&mut self, pinch: &Pinch) -> Vec<Output<A>> {
        match self.pinch_steps.take() {
            Some(Stepped { class, up, down, practiced }) => {
                vec![Output::PinchEnded { finger: pinch.finger(), class, palm: pinch.palm(), up, down, practiced }]
            }
            None => Vec::new(),
        }
    }

    fn motion(&mut self, stamp: u64, raw: [f64; 3], now: f64) -> Vec<Output<A>> {
        let mut out = self.drop_old_pinch(now);
        out.extend(self.motion_sample(stamp, raw, now));
        out
    }

    /// `motion` past an old pinch.
    fn motion_sample(&mut self, stamp: u64, raw: [f64; 3], now: f64) -> Vec<Output<A>> {
        if self.motion_stopped_during_pinch(now) {
            self.lose_pinch();
        }
        let previous = self.last_motion.replace((stamp, now));
        // Seconds since the last sample, by the band's clock.
        let gap = previous.and_then(|(last, _)| stamp.checked_sub(last)).map(|us| us as f64 / 1e6);
        let dt = match gap {
            // The same sample again.
            Some(0.0) => return Vec::new(),
            Some(gap) if gap <= pinch::MAX_DT => gap,
            // The first sample, a gap or the band's clock going back: this one can't be added up.
            _ => {
                // A gap this long in the band's clock after the press: the pinch's motion is
                // unknown, it's lost.
                let after_press = previous.is_some_and(|(_, at)| self.pinch.as_ref().is_some_and(|p| at >= p.pressed_at()));
                let lost = gap.is_some_and(|gap| gap >= MOTION_LOST);
                if after_press && lost {
                    self.lose_pinch();
                }
                // So is the pen's stroke.
                if lost
                    && let (Some(session), Some((_, at))) = (&mut self.session, previous)
                {
                    let was_down = session.pen_down();
                    session.gap(at, now);
                    return pen_up(was_down, session).into_iter().collect();
                }
                return Vec::new();
            }
        };
        if self.session.is_some() {
            return self.pen_motion(raw, dt, now);
        }
        let Some((finger, palm)) = self.pinch.as_ref().map(|p| (p.finger(), p.palm())) else {
            self.bias.learn(raw, dt);
            return Vec::new();
        };
        let rate = self.bias.rate(raw);
        if self.drag_teaching {
            return match self.pinch.as_mut().expect("checked").sample(rate, dt, now) {
                Some(direction) => vec![Output::DragSample { finger, direction }],
                None => Vec::new(),
            };
        }
        // This finger's moves do nothing: its hold is the fast one and motion is ignored.
        if !self.moves_do_something(finger, palm) {
            return Vec::new();
        }
        let step = self.pinch.as_mut().expect("checked").feed(rate, dt, now, &self.prototypes);
        match step {
            Step::None => Vec::new(),
            Step::Decided { class, amount } => self.decided(finger, palm, class, amount, now),
            Step::Moved(amount) => self.moved(amount, now),
        }
    }

    /// The pinch (this finger's, pressed with the palm this way) was just classified.
    fn decided(&mut self, finger: Finger, palm: Palm, class: Class, amount: f64, now: f64) -> Vec<Output<A>> {
        let gesture = match class {
            Class::Turn => return self.start_steps(amount, now),
            // Like the dial, drags wait for a confirmed hand.
            Class::Drag(drag) if self.hand_confirmed => match self.drag_use(finger, drag, palm) {
                DragUse::Gesture(gesture) => Some(gesture),
                DragUse::Slider(_) => return self.start_steps(amount, now),
                DragUse::Paused | DragUse::Nothing => None,
            },
            // No hand yet, or moved like nothing known.
            Class::Drag(_) | Class::Unknown => None,
        };
        // A drag gesture fires once, else the pinch is used up: nothing more comes of it.
        if let Some(p) = &mut self.pinch {
            p.finish();
        }
        match gesture {
            Some(gesture) => self.dispatch_now(gesture, now, now, palm),
            None => Vec::new(),
        }
    }

    /// A turn or a slider: it steps from here on, starting with how far the pinch already went.
    fn start_steps(&mut self, amount: f64, now: f64) -> Vec<Output<A>> {
        self.dial_gate.arm(now);
        self.dial_router.reset();
        self.moved(amount, now)
    }

    /// What the pinch steps as this class: its finger's dial for a turn, its pair's slider for
    /// a drag (by the palm at its press).
    fn pinch_dial(&self, class: Class) -> Option<&Dial<A>> {
        let pinch = self.pinch.as_ref()?;
        let finger = pinch.finger();
        match class {
            Class::Turn => self.finger_dial(finger),
            Class::Drag(drag) => match self.drag_use(finger, drag, pinch.palm()) {
                DragUse::Slider(dial) => Some(dial),
                _ => None,
            },
            Class::Unknown => None,
        }
    }

    /// The decided pinch moved `amount` degrees along its axis: dial or slider steps.
    fn moved(&mut self, amount: f64, now: f64) -> Vec<Output<A>> {
        let Some(State::Decided(class)) = self.pinch.as_ref().map(|p| p.state()) else {
            return Vec::new();
        };
        if self.pinch_dial(class).is_none()
            || !self.live
            || !self.hand_confirmed
            || !(self.enabled || self.practice)
            || (self.writing && !self.writing_dials)
            || !amount.is_finite()
        {
            return Vec::new();
        }
        // The same intended turn gives the opposite gyro sign on the left wrist (not for a
        // taught turn: its + is already the user's own).
        let reversed = class == Class::Turn && self.hand == Some(Hand::Left) && self.options.drags.is_none();
        let delta = if reversed { -amount } else { amount };
        if !self.dial_gate.allows(now, now, self.live, true) {
            return Vec::new();
        }
        let steps = self.dial_router.turn(delta, self.options.dial_sensitivity, now);
        if steps == 0 {
            return Vec::new();
        }
        self.last_dial_action = now;
        let dial = self.pinch_dial(class).expect("checked above");
        let action = if steps > 0 { dial.up.clone() } else { dial.down.clone() };
        let (up, down) = if class == Class::Turn { ("wrist turn +", "wrist turn \u{2212}") } else { ("slide +", "slide \u{2212}") };
        self.status.last_gesture = Some(if steps > 0 { up } else { down });
        self.status.last_palm = self.pinch.as_ref().map(Pinch::palm);
        let counted = self.pinch_steps.get_or_insert(Stepped { class, up: 0, down: 0, practiced: false });
        counted.practiced = self.practice;
        if steps > 0 {
            counted.up += 1;
        } else {
            counted.down += 1;
        }
        if self.practice {
            return vec![Output::Practiced(action)];
        }
        self.status.last_action = Some(action.clone());
        vec![Output::Run(action)]
    }

    fn desired_hand(&self) -> Option<Hand> {
        if let Some(hand) = self.hand_override {
            return Some(hand);
        }
        match self.options.hand {
            HandSetting::Band => None,
            HandSetting::Left => Some(Hand::Left),
            HandSetting::Right => Some(Hand::Right),
        }
    }

    fn maybe_request_hand(&mut self) -> Vec<Output<A>> {
        match (self.desired_hand(), self.hand) {
            (Some(wanted), Some(current))
                if self.live && self.hand_confirmed && wanted != current && !self.hand_requested =>
            {
                self.hand_requested = true;
                vec![Output::SetHand(wanted)]
            }
            _ => Vec::new(),
        }
    }

    fn reset_dial(&mut self) {
        self.dial_gate.pause();
        self.dial_router.reset();
    }

    /// Everything in progress is dropped; an open draw session is cancelled.
    fn suspend(&mut self) -> Vec<Output<A>> {
        self.gate.pause();
        self.reset_dial();
        self.press_palms = [None; 2];
        self.palm = Palm::Down;
        let mut out = self.drop_pinch();
        self.last_motion = None;
        out.extend(self.cancel_drawing());
        out
    }
}
