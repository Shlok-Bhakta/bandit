//! What each gesture does: the bindable gestures, the band controls above the profiles,
//! the profiles, which one is active and the call layer on top.

use std::collections::BTreeMap;

use super::palm::{Palm, Palms};
use super::pinch::Drag;
use crate::gestures::{Recognized, Swipe, Tap};

/// The gestures an action can go on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Gesture {
    SwipeLeft,
    SwipeRight,
    SwipeUp,
    SwipeDown,
    IndexTap,
    IndexDouble,
    IndexTriple,
    IndexHold,
    MiddleTap,
    MiddleDouble,
    MiddleTriple,
    MiddleHold,
    IndexDragLeft,
    IndexDragRight,
    IndexDragToward,
    IndexDragAway,
    IndexDragUp,
    IndexDragDown,
    MiddleDragLeft,
    MiddleDragRight,
    MiddleDragToward,
    MiddleDragAway,
    MiddleDragUp,
    MiddleDragDown,
}

impl Gesture {
    pub const ALL: [Gesture; 24] = [
        Gesture::SwipeLeft,
        Gesture::SwipeRight,
        Gesture::SwipeUp,
        Gesture::SwipeDown,
        Gesture::IndexTap,
        Gesture::IndexDouble,
        Gesture::IndexTriple,
        Gesture::IndexHold,
        Gesture::MiddleTap,
        Gesture::MiddleDouble,
        Gesture::MiddleTriple,
        Gesture::MiddleHold,
        Gesture::IndexDragLeft,
        Gesture::IndexDragRight,
        Gesture::IndexDragToward,
        Gesture::IndexDragAway,
        Gesture::IndexDragUp,
        Gesture::IndexDragDown,
        Gesture::MiddleDragLeft,
        Gesture::MiddleDragRight,
        Gesture::MiddleDragToward,
        Gesture::MiddleDragAway,
        Gesture::MiddleDragUp,
        Gesture::MiddleDragDown,
    ];

    /// The name in config files and stored profiles (`index_double`).
    pub fn key(self) -> &'static str {
        match self {
            Gesture::SwipeLeft => "swipe_left",
            Gesture::SwipeRight => "swipe_right",
            Gesture::SwipeUp => "swipe_up",
            Gesture::SwipeDown => "swipe_down",
            Gesture::IndexTap => "index_tap",
            Gesture::IndexDouble => "index_double",
            Gesture::IndexTriple => "index_triple",
            Gesture::IndexHold => "index_hold",
            Gesture::MiddleTap => "middle_tap",
            Gesture::MiddleDouble => "middle_double",
            Gesture::MiddleTriple => "middle_triple",
            Gesture::MiddleHold => "middle_hold",
            Gesture::IndexDragLeft => "index_drag_left",
            Gesture::IndexDragRight => "index_drag_right",
            Gesture::IndexDragToward => "index_drag_toward",
            Gesture::IndexDragAway => "index_drag_away",
            Gesture::IndexDragUp => "index_drag_up",
            Gesture::IndexDragDown => "index_drag_down",
            Gesture::MiddleDragLeft => "middle_drag_left",
            Gesture::MiddleDragRight => "middle_drag_right",
            Gesture::MiddleDragToward => "middle_drag_toward",
            Gesture::MiddleDragAway => "middle_drag_away",
            Gesture::MiddleDragUp => "middle_drag_up",
            Gesture::MiddleDragDown => "middle_drag_down",
        }
    }

    /// What status and lessons show (`index double tap`). The Android lessons match these.
    pub fn label(self) -> &'static str {
        match self {
            Gesture::SwipeLeft => "swipe left",
            Gesture::SwipeRight => "swipe right",
            Gesture::SwipeUp => "swipe up",
            Gesture::SwipeDown => "swipe down",
            Gesture::IndexTap => "index tap",
            Gesture::IndexDouble => "index double tap",
            Gesture::IndexTriple => "index triple tap",
            Gesture::IndexHold => "index hold",
            Gesture::MiddleTap => "middle tap",
            Gesture::MiddleDouble => "middle double tap",
            Gesture::MiddleTriple => "middle triple tap",
            Gesture::MiddleHold => "middle hold",
            Gesture::IndexDragLeft => "index drag left",
            Gesture::IndexDragRight => "index drag right",
            Gesture::IndexDragToward => "index drag toward",
            Gesture::IndexDragAway => "index drag away",
            Gesture::IndexDragUp => "index drag up",
            Gesture::IndexDragDown => "index drag down",
            Gesture::MiddleDragLeft => "middle drag left",
            Gesture::MiddleDragRight => "middle drag right",
            Gesture::MiddleDragToward => "middle drag toward",
            Gesture::MiddleDragAway => "middle drag away",
            Gesture::MiddleDragUp => "middle drag up",
            Gesture::MiddleDragDown => "middle drag down",
        }
    }

    pub fn from_key(key: &str) -> Option<Gesture> {
        Gesture::ALL.into_iter().find(|gesture| gesture.key() == key)
    }

    /// The finger of a tap, double or triple tap (the hold has its own rules).
    pub(crate) fn finger(self) -> Option<Finger> {
        match self {
            Gesture::IndexTap | Gesture::IndexDouble | Gesture::IndexTriple => Some(Finger::Index),
            Gesture::MiddleTap | Gesture::MiddleDouble | Gesture::MiddleTriple => Some(Finger::Middle),
            _ => None,
        }
    }

    pub(crate) fn of(recognized: Recognized) -> Gesture {
        match recognized {
            Recognized::Swipe(Swipe::Left) => Gesture::SwipeLeft,
            Recognized::Swipe(Swipe::Right) => Gesture::SwipeRight,
            Recognized::Swipe(Swipe::Up) => Gesture::SwipeUp,
            Recognized::Swipe(Swipe::Down) => Gesture::SwipeDown,
            Recognized::Tap(Tap::IndexTap) => Gesture::IndexTap,
            Recognized::Tap(Tap::IndexDoubleTap) => Gesture::IndexDouble,
            Recognized::Tap(Tap::IndexHold) => Gesture::IndexHold,
            Recognized::Tap(Tap::MiddleTap) => Gesture::MiddleTap,
            Recognized::Tap(Tap::MiddleDoubleTap) => Gesture::MiddleDouble,
            Recognized::Tap(Tap::MiddleHold) => Gesture::MiddleHold,
        }
    }

    /// This finger's drag gesture.
    pub fn drag(finger: Finger, drag: Drag) -> Gesture {
        match (finger, drag) {
            (Finger::Index, Drag::Left) => Gesture::IndexDragLeft,
            (Finger::Index, Drag::Right) => Gesture::IndexDragRight,
            (Finger::Index, Drag::Toward) => Gesture::IndexDragToward,
            (Finger::Index, Drag::Away) => Gesture::IndexDragAway,
            (Finger::Index, Drag::Up) => Gesture::IndexDragUp,
            (Finger::Index, Drag::Down) => Gesture::IndexDragDown,
            (Finger::Middle, Drag::Left) => Gesture::MiddleDragLeft,
            (Finger::Middle, Drag::Right) => Gesture::MiddleDragRight,
            (Finger::Middle, Drag::Toward) => Gesture::MiddleDragToward,
            (Finger::Middle, Drag::Away) => Gesture::MiddleDragAway,
            (Finger::Middle, Drag::Up) => Gesture::MiddleDragUp,
            (Finger::Middle, Drag::Down) => Gesture::MiddleDragDown,
        }
    }

    /// This finger's hold.
    pub fn hold(finger: Finger) -> Gesture {
        match finger {
            Finger::Index => Gesture::IndexHold,
            Finger::Middle => Gesture::MiddleHold,
        }
    }

    /// The finger and drag of a drag gesture.
    pub fn drag_of(self) -> Option<(Finger, Drag)> {
        Drag::ALL
            .into_iter()
            .flat_map(|drag| [(Finger::Index, drag), (Finger::Middle, drag)])
            .find(|&(finger, drag)| Gesture::drag(finger, drag) == self)
    }

    /// Whether Draw on this gesture can also cancel its session: not a hold (in a session
    /// it's the pen's), a triple tap or a drag (neither is made during a session).
    pub fn can_cancel_drawing(self) -> bool {
        !matches!(self, Gesture::IndexHold | Gesture::MiddleHold | Gesture::IndexTriple | Gesture::MiddleTriple)
            && self.drag_of().is_none()
    }
}

/// A pinching or tapping finger.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Finger {
    Index,
    Middle,
}

impl Finger {
    /// Its place in a per-finger array: 0 index, 1 middle.
    pub(crate) fn slot(self) -> usize {
        match self {
            Finger::Index => 0,
            Finger::Middle => 1,
        }
    }

    pub(crate) fn single(self) -> Gesture {
        match self {
            Finger::Index => Gesture::IndexTap,
            Finger::Middle => Gesture::MiddleTap,
        }
    }

    pub(crate) fn double(self) -> Gesture {
        match self {
            Finger::Index => Gesture::IndexDouble,
            Finger::Middle => Gesture::MiddleDouble,
        }
    }

    pub(crate) fn triple(self) -> Gesture {
        match self {
            Finger::Index => Gesture::IndexTriple,
            Finger::Middle => Gesture::MiddleTriple,
        }
    }
}

/// The band controls: what band-core does itself, on the gesture the user picks for each.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Builtin {
    /// Controls on/off (the lock). Works while the controls are off.
    Controls,
    NextProfile,
    PreviousProfile,
    /// Open a drawing session; again, cancel it.
    Draw,
}

impl Builtin {
    pub const ALL: [Builtin; 4] = [Builtin::Controls, Builtin::NextProfile, Builtin::PreviousProfile, Builtin::Draw];

    /// The name in config files.
    pub fn key(self) -> &'static str {
        match self {
            Builtin::Controls => "controls",
            Builtin::NextProfile => "next-profile",
            Builtin::PreviousProfile => "previous-profile",
            Builtin::Draw => "draw",
        }
    }

    pub fn from_key(key: &str) -> Option<Builtin> {
        Builtin::ALL.into_iter().find(|builtin| builtin.key() == key)
    }
}

/// Pinch and turn: one action per step each way.
#[derive(Debug, Clone, PartialEq)]
pub struct Dial<A> {
    pub up: A,
    pub down: A,
}

/// What a finger's pinch-and-move does in a profile.
#[derive(Debug, Clone, PartialEq)]
pub struct FingerSetup<A> {
    /// The turn. `None`: nothing.
    pub dial: Option<Dial<A>>,
    pub drags: DragMode<A>,
}

impl<A> Default for FingerSetup<A> {
    fn default() -> Self {
        Self { dial: None, drags: DragMode::Gestures }
    }
}

/// A finger's six drags: gestures (their actions are in `Profile::gestures`), or three sliders.
#[derive(Debug, Clone, PartialEq)]
pub enum DragMode<A> {
    Gestures,
    /// `[left/right, toward/away, up/down]`, each stepping like a dial (up = right / away / up).
    Sliders([Option<Dial<A>>; 3]),
}

/// A gesture's action: the normal one, and up to two palm positions that do something else
/// (`None` there: nothing in that position).
#[derive(Debug, Clone, PartialEq)]
pub struct Binding<A> {
    pub normal: Option<A>,
    pub overrides: BTreeMap<Palm, Option<A>>,
}

impl<A> Binding<A> {
    /// The most overrides a gesture can have (one position keeps the normal action).
    pub const MAX_OVERRIDES: usize = 2;

    /// What runs with the palm this way.
    pub fn action(&self, palm: Palm) -> Option<&A> {
        match self.overrides.get(&palm) {
            Some(over) => over.as_ref(),
            None => self.normal.as_ref(),
        }
    }

    /// With this palm position doing `action` instead (`None`: nothing there).
    pub fn with(mut self, palm: Palm, action: Option<A>) -> Self {
        self.overrides.insert(palm, action);
        self
    }

    pub fn valid(&self) -> bool {
        self.overrides.len() <= Self::MAX_OVERRIDES
    }
}

impl<A> From<A> for Binding<A> {
    fn from(normal: A) -> Self {
        Self { normal: Some(normal), overrides: BTreeMap::new() }
    }
}

/// Where a band control acts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PalmSet {
    #[default]
    All,
    /// One or two positions.
    Only(Palms),
}

impl PalmSet {
    /// The most positions `Only` can hold (all three is `All`).
    pub const MAX_ONLY: usize = 2;

    /// `All`, or `Only` with 1–2 positions.
    pub fn valid(&self) -> bool {
        match self {
            PalmSet::All => true,
            PalmSet::Only(set) => (1..=Self::MAX_ONLY).contains(&set.len()),
        }
    }

    pub fn contains(&self, palm: Palm) -> bool {
        match self {
            PalmSet::All => true,
            PalmSet::Only(set) => set.contains(palm),
        }
    }
}

/// A band control's gesture and where it acts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BandControl {
    pub gesture: Gesture,
    pub palm: PalmSet,
}

impl BandControl {
    /// On this gesture in every position.
    pub fn on(gesture: Gesture) -> Self {
        Self { gesture, palm: PalmSet::All }
    }
}

/// A named set of gesture actions.
#[derive(Debug, Clone, PartialEq)]
pub struct Profile<A> {
    pub name: String,
    /// Gestures without an entry do nothing. An entry on a band-control gesture is kept but
    /// doesn't run (it's "paused") where that band control acts.
    pub gestures: BTreeMap<Gesture, Binding<A>>,
    pub index: FingerSetup<A>,
    pub middle: FingerSetup<A>,
    /// Drawing name → this profile's own action (wins over `Profiles::drawings`).
    pub drawings: BTreeMap<String, A>,
}

impl<A> Profile<A> {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.into(),
            gestures: BTreeMap::new(),
            index: FingerSetup::default(),
            middle: FingerSetup::default(),
            drawings: BTreeMap::new(),
        }
    }

    pub fn finger(&self, finger: Finger) -> &FingerSetup<A> {
        match finger {
            Finger::Index => &self.index,
            Finger::Middle => &self.middle,
        }
    }
}

/// During a call, per gesture, on top of the active profile.
#[derive(Debug, Clone, PartialEq)]
pub enum CallBinding<A> {
    AsUsual,
    Nothing,
    Do(Binding<A>),
}

impl<A> CallBinding<A> {
    /// Its binding (`Do` only).
    pub fn binding(&self) -> Option<&Binding<A>> {
        match self {
            CallBinding::Do(binding) => Some(binding),
            CallBinding::AsUsual | CallBinding::Nothing => None,
        }
    }
}

/// Controls on/off, next and previous profile, draw: one gesture each (in some or all palm
/// positions), above every profile, the call layer and an app's own profile. `Default` is no
/// band controls; see [`Self::standard`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BandControls {
    pub controls: Option<BandControl>,
    pub next: Option<BandControl>,
    pub previous: Option<BandControl>,
    pub draw: Option<BandControl>,
}

impl BandControls {
    /// Today's gestures, in every position: middle hold, index triple tap, middle triple tap;
    /// Draw on the index hold.
    pub fn standard() -> Self {
        Self {
            controls: Some(BandControl::on(Gesture::MiddleHold)),
            next: Some(BandControl::on(Gesture::IndexTriple)),
            previous: Some(BandControl::on(Gesture::MiddleTriple)),
            draw: Some(BandControl::on(Gesture::IndexHold)),
        }
    }

    /// The band control on this gesture in this position (Controls wins, then Next, then
    /// Previous, then Draw, if two share it).
    pub fn on(&self, gesture: Gesture, palm: Palm) -> Option<Builtin> {
        Builtin::ALL.into_iter().find(|&builtin| {
            self.control(builtin).is_some_and(|c| c.gesture == gesture && c.palm.contains(palm))
        })
    }

    /// Where this band control is.
    pub fn control(&self, builtin: Builtin) -> Option<&BandControl> {
        match builtin {
            Builtin::Controls => self.controls.as_ref(),
            Builtin::NextProfile => self.next.as_ref(),
            Builtin::PreviousProfile => self.previous.as_ref(),
            Builtin::Draw => self.draw.as_ref(),
        }
    }

    /// The positions where this band control wins on its gesture.
    fn reachable(&self, builtin: Builtin) -> Palms {
        let Some(control) = self.control(builtin) else { return Palms::default() };
        Palm::ALL.into_iter().filter(|&palm| self.on(control.gesture, palm) == Some(builtin)).collect()
    }
}

/// Where an action on a gesture sits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Place {
    Profile(usize),
    Calls,
}

/// An action on a gesture, and where (see [`Profiles::uses`]).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Use<'a, A> {
    pub place: Place,
    /// `None`: the normal action; else the override for this position.
    pub palm: Option<Palm>,
    pub action: &'a A,
}

/// An action that doesn't run because a band control wins on its gesture (see
/// [`Profiles::paused`]).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Paused<'a, A> {
    pub builtin: Builtin,
    pub gesture: Gesture,
    pub used: Use<'a, A>,
    /// Where it would have run and the band control wins (for an override, just its palm).
    pub positions: Palms,
}

/// A slider that doesn't move because a band control is on a drag of its pair (see
/// [`Profiles::paused_sliders`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PausedSlider {
    pub builtin: Builtin,
    /// The drag gesture the band control is on.
    pub gesture: Gesture,
    pub profile: usize,
    pub finger: Finger,
    /// The pair: 0 left/right, 1 toward/away, 2 up/down.
    pub pair: usize,
    /// Where the band control wins (a pinch made with the palm there doesn't move the slider).
    pub positions: Palms,
}

/// Something about the band controls the user may want to fix (never blocking).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Warning {
    /// No gesture turns the controls on/off: the band can't lock.
    NoControls,
    /// 2+ profiles, but neither next nor previous wins in any position (one shared with
    /// Controls on/off doesn't count there): the band can't switch.
    NoWayOut,
    /// Draw is on an index or middle single tap: in a session a short pinch is that tap, and
    /// cancels the drawing.
    DrawOnTap,
}

/// Something the apps should show as wrong (the engine still uses it; see [`Profiles::invalid`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Invalid {
    /// A binding with more than `Binding::MAX_OVERRIDES` overrides.
    Binding { place: Place, gesture: Gesture },
    /// A band control limited to no position or to all three.
    BandControl(Builtin),
    /// Draw on a triple tap or a drag: it opens a draw session but can't cancel it (neither is
    /// made during a session). The session still ends by itself or by
    /// `Controls::cancel_drawing`. Not for a hold, the standard Draw: it can't cancel either (a
    /// hold there is the pen's), but nothing else is made with that pinch, so it's fine.
    DrawCantCancel,
}

/// What a gesture does (see [`Profiles::resolve`]).
pub(crate) enum Resolved<'a, A> {
    /// A band control (above everything).
    Band(Builtin),
    /// The call layer's or the profile's action.
    Run(&'a A),
}

/// What a finger's drag does in a profile (see [`Profiles::drag_use`]).
pub(crate) enum DragUse<'a, A> {
    /// Its gesture: a band control's, or the profile's in gestures mode.
    Gesture(Gesture),
    /// Its pair's slider.
    Slider(&'a Dial<A>),
    /// Its pair's slider, paused by a band control on the pair's other drag.
    Paused,
    /// Sliders mode without a slider for its pair.
    Nothing,
}

/// What only a live `Controls` knows on top of the profiles: the live extras for the profile
/// rules (`Profiles::resolve`, `does_something`, `hold_waits_with`). `Controls` fills it in;
/// `Default` is none of them, as [`Profiles::hold_waits`] reads the profiles.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct Runtime {
    /// The index finger's dial: `None`, the profile's; `Some(set)`, the runtime one
    /// (`Controls::set_dial`) in its place, set or not.
    pub dial_override: Option<bool>,
    /// The drag directions in use are turns only (the untaught left hand's): no drag is ever
    /// classified.
    pub turns_only: bool,
    /// In a call: the call layer is on top of the profile.
    pub in_call: bool,
    /// The app in front holds its own profile: next/previous do nothing.
    pub held: bool,
}

/// A binding's actions: the normal one, then each override in `Palm` order.
fn uses_of<A>(place: Place, binding: &Binding<A>) -> impl Iterator<Item = Use<'_, A>> {
    let normal = binding.normal.as_ref().map(|action| Use { place, palm: None, action });
    let overrides = binding.overrides.iter().filter_map(move |(&palm, action)| action.as_ref().map(|action| Use { place, palm: Some(palm), action }));
    normal.into_iter().chain(overrides)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Profiles<A> {
    /// Above every profile and the call layer.
    pub band: BandControls,
    /// Never empty once inside `Controls` (an empty list gets one empty profile).
    pub list: Vec<Profile<A>>,
    pub picked: usize,
    /// App id → that app's own profile, active while the app is in front.
    pub apps: BTreeMap<String, usize>,
    pub calls: BTreeMap<Gesture, CallBinding<A>>,
    /// Drawing name → its action in every profile without its own.
    pub drawings: BTreeMap<String, A>,
}

impl<A> Profiles<A> {
    /// One profile, no band controls, nothing else.
    pub fn single(profile: Profile<A>) -> Self {
        Self {
            band: BandControls::default(),
            list: vec![profile],
            picked: 0,
            apps: BTreeMap::new(),
            calls: BTreeMap::new(),
            drawings: BTreeMap::new(),
        }
    }

    /// The action of this drawing in this profile: its own, else the shared one.
    pub fn drawing_action(&self, profile: usize, name: &str) -> Option<&A> {
        self.list.get(profile).and_then(|p| p.drawings.get(name)).or_else(|| self.drawings.get(name))
    }

    /// The active profile: the app in front's own, else the picked one (else the last).
    pub fn active(&self, foreground: Option<&str>) -> usize {
        self.held_by(foreground)
            .and_then(|app| self.apps.get(app).copied())
            .unwrap_or_else(|| self.picked.min(self.list.len().saturating_sub(1)))
    }

    /// The app in front, when it has a profile of its own (which next/previous then leave alone).
    pub fn held_by<'a>(&self, foreground: Option<&'a str>) -> Option<&'a str> {
        foreground.filter(|app| self.apps.get(*app).is_some_and(|&index| index < self.list.len()))
    }

    pub fn warnings(&self) -> Vec<Warning> {
        let mut warnings = Vec::new();
        if self.band.reachable(Builtin::Controls).is_empty() {
            warnings.push(Warning::NoControls);
        }
        let way_out = [Builtin::NextProfile, Builtin::PreviousProfile]
            .into_iter()
            .any(|builtin| !self.band.reachable(builtin).is_empty());
        if self.list.len() >= 2 && !way_out {
            warnings.push(Warning::NoWayOut);
        }
        if self.band.draw.is_some_and(|c| matches!(c.gesture, Gesture::IndexTap | Gesture::MiddleTap)) {
            warnings.push(Warning::DrawOnTap);
        }
        warnings
    }

    /// Every action on this gesture: each profile's, in order, then the call layer's
    /// (`CallBinding::Do` only; `Nothing` isn't an action); within each, the normal action then
    /// each override in `Palm` order. A drag gesture's entry in a profile whose finger is in
    /// sliders mode never runs, so it isn't a use.
    pub fn uses(&self, gesture: Gesture) -> Vec<Use<'_, A>> {
        self.bindings(gesture).flat_map(|(place, binding)| uses_of(place, binding)).collect()
    }

    /// The bindings of this gesture that can run: each profile's (not a drag of a finger in
    /// sliders mode), in order, then the call layer's (`CallBinding::Do` only).
    fn bindings(&self, gesture: Gesture) -> impl Iterator<Item = (Place, &Binding<A>)> {
        let drag_of = gesture.drag_of();
        let sliders = move |profile: &Profile<A>| {
            drag_of.is_some_and(|(finger, _)| matches!(profile.finger(finger).drags, DragMode::Sliders(_)))
        };
        let profiles = self
            .list
            .iter()
            .enumerate()
            .filter(move |(_, profile)| !sliders(profile))
            .filter_map(move |(index, profile)| profile.gestures.get(&gesture).map(|binding| (Place::Profile(index), binding)));
        let calls = self.calls.get(&gesture).and_then(CallBinding::binding).map(|binding| (Place::Calls, binding));
        profiles.chain(calls)
    }

    /// The actions that don't run because a band control wins on their gesture, per band
    /// control (in `Builtin::ALL` order), each with the positions where that band control wins
    /// over it.
    pub fn paused(&self) -> Vec<Paused<'_, A>> {
        let mut paused = Vec::new();
        for builtin in Builtin::ALL {
            let wins = self.band.reachable(builtin);
            let Some(control) = self.band.control(builtin).filter(|_| !wins.is_empty()) else { continue };
            let gesture = control.gesture;
            for (place, binding) in self.bindings(gesture) {
                for used in uses_of(place, binding) {
                    let positions: Palms = wins
                        .iter()
                        .filter(|palm| match used.palm {
                            Some(own) => own == *palm,
                            None => !binding.overrides.contains_key(palm),
                        })
                        .collect();
                    if !positions.is_empty() {
                        paused.push(Paused { builtin, gesture, used, positions });
                    }
                }
            }
        }
        paused
    }

    /// What the apps show as wrong (the engine still uses it): the bindings with more than
    /// `Binding::MAX_OVERRIDES` overrides, each profile's in order, then the call layer's; then
    /// the band controls limited to no position or all three, in `Builtin::ALL` order; then
    /// Draw on a triple tap or a drag (`Invalid::DrawCantCancel`).
    pub fn invalid(&self) -> Vec<Invalid> {
        let profiles = self.list.iter().enumerate().flat_map(|(index, profile)| {
            profile
                .gestures
                .iter()
                .filter(|(_, binding)| !binding.valid())
                .map(move |(&gesture, _)| Invalid::Binding { place: Place::Profile(index), gesture })
        });
        let calls = self
            .calls
            .iter()
            .filter(|(_, call)| call.binding().is_some_and(|binding| !binding.valid()))
            .map(|(&gesture, _)| Invalid::Binding { place: Place::Calls, gesture });
        let band = Builtin::ALL
            .into_iter()
            .filter(|&builtin| self.band.control(builtin).is_some_and(|c| !c.palm.valid()))
            .map(Invalid::BandControl);
        let draw = self
            .band
            .draw
            .filter(|c| !c.gesture.can_cancel_drawing() && !matches!(c.gesture, Gesture::IndexHold | Gesture::MiddleHold))
            .map(|_| Invalid::DrawCantCancel);
        profiles.chain(calls).chain(band).chain(draw).collect()
    }

    /// The sliders that don't move because a band control wins on a drag of their pair, per
    /// band control (in `Builtin::ALL` order), then per profile; each with the positions where
    /// that band control wins.
    pub fn paused_sliders(&self) -> Vec<PausedSlider> {
        let mut paused = Vec::new();
        for builtin in Builtin::ALL {
            let positions = self.band.reachable(builtin);
            let Some((gesture, (finger, drag))) = self
                .band
                .control(builtin)
                .filter(|_| !positions.is_empty())
                .and_then(|control| control.gesture.drag_of().map(|of| (control.gesture, of)))
            else {
                continue;
            };
            for (profile, setup) in self.list.iter().enumerate() {
                if let DragMode::Sliders(sliders) = &setup.finger(finger).drags
                    && sliders[drag.pair()].is_some()
                {
                    let pair = drag.pair();
                    paused.push(PausedSlider { builtin, gesture, profile, finger, pair, positions });
                }
            }
        }
        paused
    }

    /// Whether this finger's hold, in this profile with the palm this way, waits for the
    /// release (the pinch may still be a turn or a drag) instead of acting at the band's hold
    /// message: the finger's dial is set, or one of its six drags does something there. In
    /// gestures mode that's a binding with an action in that palm; in sliders mode the pair's
    /// slider, set and not paused; in either a band control that wins on the drag gesture
    /// there (next/previous only with 2+ profiles). `Controls` follows the same rule with
    /// what only it knows on top: its runtime dial (`Controls::set_dial`), turns-only drag
    /// directions (the untaught left hand: only the dial waits), the call layer, and an app
    /// in front holding its own profile (next/previous do nothing). `false` for a profile that
    /// doesn't exist.
    pub fn hold_waits(&self, profile: usize, finger: Finger, palm: Palm) -> bool {
        self.hold_waits_with(profile, finger, palm, Runtime::default())
    }

    /// [`Self::hold_waits`] with the live extras: the one rule both it and `Controls` use.
    pub(crate) fn hold_waits_with(&self, profile: usize, finger: Finger, palm: Palm, runtime: Runtime) -> bool {
        let Some(setup) = self.list.get(profile).map(|p| p.finger(finger)) else { return false };
        let dial = match (finger, runtime.dial_override) {
            (Finger::Index, Some(set)) => set,
            _ => setup.dial.is_some(),
        };
        dial || (!runtime.turns_only && Drag::ALL.iter().any(|&drag| self.drag_does_something(profile, finger, drag, palm, runtime)))
    }

    fn drag_does_something(&self, profile: usize, finger: Finger, drag: Drag, palm: Palm, runtime: Runtime) -> bool {
        match self.drag_use(profile, finger, drag, palm) {
            DragUse::Gesture(gesture) => self.does_something(profile, gesture, palm, runtime),
            DragUse::Slider(_) => true,
            DragUse::Paused | DragUse::Nothing => false,
        }
    }

    /// What this finger's drag does in this profile (`Nothing` in one that doesn't exist,
    /// unless a band control is on it). It takes no `Runtime`: none of it changes which use a
    /// drag has; the call layer and an app holding its profile apply when a `Gesture` use is
    /// resolved (`does_something`), the runtime dial and turns-only drags in `hold_waits_with`.
    pub(crate) fn drag_use(&self, profile: usize, finger: Finger, drag: Drag, palm: Palm) -> DragUse<'_, A> {
        let gesture = Gesture::drag(finger, drag);
        if self.band.on(gesture, palm).is_some() {
            return DragUse::Gesture(gesture);
        }
        let Some(profile) = self.list.get(profile) else { return DragUse::Nothing };
        match &profile.finger(finger).drags {
            DragMode::Gestures => DragUse::Gesture(gesture),
            DragMode::Sliders(_) if self.band.on(Gesture::drag(finger, drag.opposite()), palm).is_some() => DragUse::Paused,
            DragMode::Sliders(sliders) => sliders[drag.pair()].as_ref().map_or(DragUse::Nothing, DragUse::Slider),
        }
    }

    /// What this gesture does in this profile: a band control, else the call layer while in
    /// a call, else the profile's action (none in a profile that doesn't exist).
    pub(crate) fn resolve(&self, profile: usize, gesture: Gesture, palm: Palm, runtime: Runtime) -> Option<Resolved<'_, A>> {
        if let Some(builtin) = self.band.on(gesture, palm) {
            return Some(Resolved::Band(builtin));
        }
        if runtime.in_call {
            match self.calls.get(&gesture) {
                Some(CallBinding::Nothing) => return None,
                // A palm override of `None` there: nothing runs.
                Some(CallBinding::Do(binding)) => return binding.action(palm).map(Resolved::Run),
                Some(CallBinding::AsUsual) | None => {}
            }
        }
        self.list.get(profile)?.gestures.get(&gesture)?.action(palm).map(Resolved::Run)
    }

    /// Whether this gesture would do anything in this profile (a profile switch needs 2+
    /// profiles and no app holding its own).
    pub(crate) fn does_something(&self, profile: usize, gesture: Gesture, palm: Palm, runtime: Runtime) -> bool {
        match self.resolve(profile, gesture, palm, runtime) {
            None => false,
            Some(Resolved::Band(Builtin::NextProfile | Builtin::PreviousProfile)) => self.list.len() >= 2 && !runtime.held,
            Some(_) => true,
        }
    }

    /// Inside `Controls`: at least one profile, indexes in range.
    pub(crate) fn normalize(&mut self) {
        if self.list.is_empty() {
            self.list.push(Profile::new("default"));
        }
        self.picked = self.picked.min(self.list.len() - 1);
        let count = self.list.len();
        self.apps.retain(|_, index| *index < count);
    }
}
