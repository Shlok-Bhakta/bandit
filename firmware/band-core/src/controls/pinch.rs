//! One pinch, from the band's press to its release: still (a hold), a turn (the dial) or one
//! of six drags. Directions are read in the forearm frame: the band's frame rolled about the
//! forearm (its y axis) so that "up" lies in the y–z plane with z ≥ 0 (a pitched forearm
//! keeps up's y part), which makes a drag mean the same with the palm down, sideways or up.

use super::Finger;
use super::palm::{Palm, RIGHT_PALM_DOWN_ROLL};

/// Raw gyro units to degrees per second.
pub const GYRO_SCALE: f64 = 0.07;
/// Movement (degrees) at which a pinch is classified.
pub const DECIDE_AT: f64 = 15.0;
/// If the best direction beats the next by less than this (cosine), wait until `DECIDE_LATE`.
pub const MARGIN: f64 = 0.1;
/// Movement (degrees) after which a pinch is classified even when the margin is small.
pub const DECIDE_LATE: f64 = 25.0;
/// A pinch is never classified before it lasted this long (taps are over by then).
pub const DECIDE_AFTER: f64 = 0.2;
/// Turn-only prototypes (no drags taught for this hand): a turn needs this cosine.
pub const TURN_ONLY_COSINE: f64 = 0.8;
/// With drags skipped while teaching, a move must be at least this close (cosine) to the turn
/// or a taught drag; else it's like nothing known (a skipped drag isn't read as another).
pub const SKIPPED_MIN_COSINE: f64 = 0.8;
/// The longest gap between gyro samples (seconds) that still counts as one stream; samples
/// with a longer, zero, negative or non-finite gap are ignored.
pub const MAX_DT: f64 = 0.05;
/// Raw gyro units (≈3 °/s) within which, on every axis, the wrist counts as still for
/// learning the bias.
pub const STILL_RAW: f64 = 45.0;
/// Below this horizontal part of "up" (x, z) the forearm points nearly straight up or down,
/// so its roll can't be read.
pub const ROLL_MIN_HORIZONTAL: f64 = 0.3;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Drag {
    Left,
    Right,
    Toward,
    Away,
    Up,
    Down,
}

impl Drag {
    pub const ALL: [Drag; 6] = [Drag::Left, Drag::Right, Drag::Toward, Drag::Away, Drag::Up, Drag::Down];

    /// The slider of this drag's pair moves this way: +1 right / away / up, −1 the others.
    pub fn sign(self) -> f64 {
        match self {
            Drag::Right | Drag::Away | Drag::Up => 1.0,
            Drag::Left | Drag::Toward | Drag::Down => -1.0,
        }
    }

    /// The position in `Drag::ALL`.
    pub fn index(self) -> usize {
        match self {
            Drag::Left => 0,
            Drag::Right => 1,
            Drag::Toward => 2,
            Drag::Away => 3,
            Drag::Up => 4,
            Drag::Down => 5,
        }
    }

    /// The other drag of this one's pair.
    pub fn opposite(self) -> Drag {
        match self {
            Drag::Left => Drag::Right,
            Drag::Right => Drag::Left,
            Drag::Toward => Drag::Away,
            Drag::Away => Drag::Toward,
            Drag::Up => Drag::Down,
            Drag::Down => Drag::Up,
        }
    }

    /// The pair: 0 left/right, 1 toward/away, 2 up/down.
    pub fn pair(self) -> usize {
        match self {
            Drag::Left | Drag::Right => 0,
            Drag::Toward | Drag::Away => 1,
            Drag::Up | Drag::Down => 2,
        }
    }
}

/// What a pinch's movement turned out to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Class {
    Turn,
    Drag(Drag),
    /// Moved, but like nothing known (turn-only prototypes): the pinch is used up.
    Unknown,
}

/// Where each movement points, in the forearm frame (unit vectors), and the roll to assume
/// when no orientation is known.
#[derive(Debug, Clone, PartialEq)]
pub struct Prototypes {
    /// Palm down's roll: a pinch's (and a pen's) roll when no orientation is known. It doesn't
    /// change how a pinch with a known roll is read (the directions are in the forearm frame),
    /// nor the drawing frame (`draw::FRAME_ROLL`).
    pub palm_down_roll: f64,
    pub turn: [f64; 3],
    /// In `Drag::ALL` order; a drag skipped while teaching is `None` (never read). `None`:
    /// this hand's drags aren't known (turns only).
    pub drags: Option<[Option<[f64; 3]>; 6]>,
}

impl Prototypes {
    /// Measured on the owner's right wrist (2026-10-25). The numbers are rounded, so each is
    /// made unit length again (amounts along an axis are then in degrees).
    pub fn right_hand() -> Self {
        Self {
            palm_down_roll: RIGHT_PALM_DOWN_ROLL,
            turn: unit([0.050, 0.978, 0.204]),
            drags: Some([
                Some(unit([-0.060, 0.446, 0.893])),  // left
                Some(unit([0.123, -0.144, -0.982])), // right
                Some(unit([0.505, 0.070, 0.860])),   // toward
                Some(unit([-0.693, 0.062, -0.719])), // away
                Some(unit([0.615, -0.680, 0.400])),  // up
                Some(unit([-0.354, 0.800, 0.484])),  // down
            ]),
        }
    }

    /// The left hand until its drags are taught: the turn only (about the forearm).
    pub fn turns_only() -> Self {
        Self { palm_down_roll: 0.0, turn: [0.0, 1.0, 0.0], drags: None }
    }

    /// The nearest direction to `v` (any length) and how much it beats the next (cosine).
    /// Turns-only prototypes return a margin of 1.0 (there's nothing to beat); a zero or
    /// non-finite `v` is `(Class::Unknown, 0.0)`.
    pub fn classify(&self, v: [f64; 3]) -> (Class, f64) {
        if !has_length(v) {
            return (Class::Unknown, 0.0);
        }
        let u = unit(v);
        let turn = dot(u, self.turn).abs();
        let Some(drags) = &self.drags else {
            return (if turn >= TURN_ONLY_COSINE { Class::Turn } else { Class::Unknown }, 1.0);
        };
        let mut scored: Vec<(f64, Class)> = std::iter::once((turn, Class::Turn))
            .chain(Drag::ALL.iter().zip(drags).filter_map(|(drag, p)| p.map(|p| (dot(u, p), Class::Drag(*drag)))))
            .collect();
        scored.sort_by(|a, b| b.0.total_cmp(&a.0));
        let next = scored.get(1).map_or(0.0, |s| s.0);
        if drags.iter().any(Option::is_none) && scored[0].0 < SKIPPED_MIN_COSINE {
            return (Class::Unknown, scored[0].0 - next);
        }
        (scored[0].1, scored[0].0 - next)
    }

    /// The unit vector a slider of this drag's pair moves along (towards the positive end).
    /// `None`: this hand's drags aren't known, or this one was skipped.
    pub fn slider_axis(&self, drag: Drag) -> Option<[f64; 3]> {
        let p = self.drags.as_ref()?[drag.index()]?;
        Some(if drag.sign() > 0.0 { p } else { [-p[0], -p[1], -p[2]] })
    }

    /// The roll to read a pinch in: from the orientation when there is one and it shows the
    /// roll, else `palm_down_roll`.
    pub fn roll_for(&self, q: Option<[f32; 4]>) -> f64 {
        match q {
            Some(q) => roll_or(up_in_band(q), self.palm_down_roll),
            None => self.palm_down_roll,
        }
    }
}

/// Two taught directions closer than this (cosine) can't be told apart.
pub const TAUGHT_DISTINCT: f64 = 0.9;

/// Why taught samples can't make a hand's prototypes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaughtError {
    /// The turn sample has no length.
    NoTurn,
    /// This drag sample has no length.
    NoDrag(Drag),
    /// These two drags were taught (nearly) the same way.
    TooAlike(Drag, Drag),
    /// This drag was taught like the turn.
    LikeTheTurn(Drag),
    /// The palm-down roll isn't a number.
    NoRoll,
}

impl Prototypes {
    /// From taught samples (any length; forearm frame): the turn and the six drags in
    /// `Drag::ALL` order, `None` for a drag skipped (never read; nothing is checked against it). `palm_down_roll` is the roll the samples were read in:
    /// `Controls::prototypes().palm_down_roll` while they were taught (a non-finite one is
    /// `NoRoll`). Each is made unit length; a drag within `TAUGHT_DISTINCT` of another drag,
    /// or of the turn either way, is refused. A sample with no (or a non-finite) length is
    /// refused too.
    pub fn taught(turn: [f64; 3], drags: [Option<[f64; 3]>; 6], palm_down_roll: f64) -> Result<Self, TaughtError> {
        if !palm_down_roll.is_finite() {
            return Err(TaughtError::NoRoll);
        }
        if !has_length(turn) {
            return Err(TaughtError::NoTurn);
        }
        let turn = unit(turn);
        let mut units = [None; 6];
        for (i, drag) in Drag::ALL.into_iter().enumerate() {
            let Some(sample) = drags[i] else { continue };
            if !has_length(sample) {
                return Err(TaughtError::NoDrag(drag));
            }
            let u = unit(sample);
            if dot(u, turn).abs() >= TAUGHT_DISTINCT {
                return Err(TaughtError::LikeTheTurn(drag));
            }
            if let Some(j) = units[..i].iter().position(|other| other.is_some_and(|other| dot(u, other) >= TAUGHT_DISTINCT)) {
                return Err(TaughtError::TooAlike(Drag::ALL[j], drag));
            }
            units[i] = Some(u);
        }
        Ok(Self { palm_down_roll, turn, drags: Some(units) })
    }
}

fn has_length(v: [f64; 3]) -> bool {
    let n = norm(v);
    n > 0.0 && n.is_finite()
}

pub(crate) fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

pub(crate) fn norm(v: [f64; 3]) -> f64 {
    dot(v, v).sqrt()
}

pub(crate) fn unit(v: [f64; 3]) -> [f64; 3] {
    let n = norm(v);
    if n == 0.0 { v } else { [v[0] / n, v[1] / n, v[2] / n] }
}

/// "Up" (against gravity) in the band's frame, from an orientation (w, x, y, z).
pub fn up_in_band(q: [f32; 4]) -> [f64; 3] {
    let [w, x, y, z] = q.map(f64::from);
    [2.0 * (x * z - w * y), 2.0 * (y * z + w * x), 1.0 - 2.0 * (x * x + y * y)]
}

/// How the band is rolled about the forearm: where "up" points around its y axis (degrees).
pub fn roll(up: [f64; 3]) -> f64 {
    up[0].atan2(up[2]).to_degrees()
}

/// [`roll`], or `fallback` when the forearm points nearly straight up or down (or `up` isn't
/// finite) and the roll can't be read.
pub fn roll_or(up: [f64; 3], fallback: f64) -> f64 {
    let horizontal = up[0].hypot(up[2]);
    if horizontal >= ROLL_MIN_HORIZONTAL { roll(up) } else { fallback }
}

/// Band frame → forearm frame for this roll (degrees): "up" moves into the y–z plane with
/// z ≥ 0 (a pitched forearm keeps up's y part).
pub fn to_forearm(v: [f64; 3], roll: f64) -> [f64; 3] {
    let (s, c) = roll.to_radians().sin_cos();
    [c * v[0] - s * v[2], v[1], s * v[0] + c * v[2]]
}

/// Forearm frame → band frame (the inverse of [`to_forearm`]).
pub fn from_forearm(v: [f64; 3], roll: f64) -> [f64; 3] {
    let (s, c) = roll.to_radians().sin_cos();
    [c * v[0] + s * v[2], v[1], -s * v[0] + c * v[2]]
}

/// The gyro's resting offset, learned while no finger is pinched and the wrist is nearly still.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct GyroBias {
    bias: [f64; 3],
}

impl GyroBias {
    pub fn learn(&mut self, raw: [f64; 3], dt: f64) {
        if !(dt > 0.0 && dt <= MAX_DT && raw.iter().all(|v| v.is_finite())) {
            return;
        }
        if (0..3).all(|i| (raw[i] - self.bias[i]).abs() < STILL_RAW) {
            let k = 1.0 - (-dt / 2.0).exp();
            for (bias, value) in self.bias.iter_mut().zip(raw) {
                *bias += (value - *bias) * k;
            }
        }
    }

    /// Degrees per second in the band's frame.
    pub fn rate(&self, raw: [f64; 3]) -> [f64; 3] {
        std::array::from_fn(|i| (raw[i] - self.bias[i]) * GYRO_SCALE)
    }
}

/// What a pinch is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Undecided,
    Decided(Class),
    /// Lost (motion stopped) or already used: nothing more from it.
    Done,
}

/// What one gyro sample changed.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Step {
    None,
    /// Just classified; `amount` is how far it already went along the class's axis (degrees,
    /// signed: + along the turn / towards the slider's positive end).
    Decided { class: Class, amount: f64 },
    /// Moved this far along the decided class's axis (degrees, signed as above).
    Moved(f64),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Pinch {
    finger: Finger,
    pressed_at: f64,
    /// Roll at the press (degrees).
    roll: f64,
    /// The palm position at the press: what the pinch's gestures are made with.
    palm: Palm,
    /// The band sent its hold message during this pinch.
    saw_hold: bool,
    /// The hold already acted (the fast hold).
    held: bool,
    state: State,
    moved: [f64; 3],
}

impl Pinch {
    pub fn new(finger: Finger, pressed_at: f64, roll: f64, palm: Palm) -> Self {
        Self { finger, pressed_at, roll, palm, saw_hold: false, held: false, state: State::Undecided, moved: [0.0; 3] }
    }

    pub fn finger(&self) -> Finger {
        self.finger
    }

    /// The band sent its hold message during this pinch.
    pub fn saw_hold(&self) -> bool {
        self.saw_hold
    }

    /// The hold already acted (the fast hold).
    pub fn held(&self) -> bool {
        self.held
    }

    /// Nothing more comes of this pinch (lost, used, or its hold acted).
    pub fn finish(&mut self) {
        self.state = State::Done;
    }

    /// The band's hold message came.
    pub fn mark_saw_hold(&mut self) {
        self.saw_hold = true;
    }

    /// The hold acted: nothing else comes of this pinch.
    pub fn mark_held(&mut self) {
        self.held = true;
        self.finish();
    }

    pub fn pressed_at(&self) -> f64 {
        self.pressed_at
    }

    /// Roll at the press (degrees).
    pub fn roll(&self) -> f64 {
        self.roll
    }

    /// The palm position at the press.
    pub fn palm(&self) -> Palm {
        self.palm
    }

    pub fn state(&self) -> State {
        self.state
    }

    /// Total movement so far in the forearm frame (degrees per axis).
    pub fn moved(&self) -> [f64; 3] {
        self.moved
    }

    /// Teaching drags: one gyro sample (as [`Self::feed`]) that only adds up the movement.
    /// Once the pinch lasted `DECIDE_AFTER` and moved `DECIDE_AT`, it's done and gives where
    /// it moved (unit, forearm frame); nothing before or after.
    pub fn sample(&mut self, rate: [f64; 3], dt: f64, now: f64) -> Option<[f64; 3]> {
        if self.state != State::Undecided {
            return None;
        }
        self.add(rate, dt)?;
        if !self.may_decide(now) {
            return None;
        }
        self.finish();
        Some(unit(self.moved))
    }

    /// Adds a sample's movement (forearm frame) and returns it; `None` for a bad `dt` (see
    /// [`MAX_DT`]) or a non-finite rate, which is ignored.
    fn add(&mut self, rate: [f64; 3], dt: f64) -> Option<[f64; 3]> {
        if !(dt > 0.0 && dt <= MAX_DT && rate.iter().all(|r| r.is_finite())) {
            return None;
        }
        let delta = to_forearm(rate.map(|r| r * dt), self.roll);
        for (moved, d) in self.moved.iter_mut().zip(delta) {
            *moved += d;
        }
        Some(delta)
    }

    /// It lasted `DECIDE_AFTER` and moved `DECIDE_AT`. Written so that a NaN fails closed.
    fn may_decide(&self, now: f64) -> bool {
        now - self.pressed_at >= DECIDE_AFTER && norm(self.moved) >= DECIDE_AT
    }

    /// One gyro sample: `rate` in °/s in the band's frame, `dt` seconds, at `now`. A sample
    /// with a bad `dt` (see [`MAX_DT`]) or a non-finite rate is ignored.
    pub fn feed(&mut self, rate: [f64; 3], dt: f64, now: f64, prototypes: &Prototypes) -> Step {
        let Some(delta) = self.add(rate, dt) else { return Step::None };
        match self.state {
            State::Done => Step::None,
            State::Decided(Class::Turn) => Step::Moved(dot(delta, prototypes.turn)),
            State::Decided(Class::Drag(drag)) => match prototypes.slider_axis(drag) {
                Some(axis) => Step::Moved(dot(delta, axis)),
                None => Step::None,
            },
            State::Decided(Class::Unknown) => Step::None,
            State::Undecided => {
                if !self.may_decide(now) {
                    return Step::None;
                }
                let distance = norm(self.moved);
                let (class, margin) = prototypes.classify(self.moved);
                if !(margin >= MARGIN || distance >= DECIDE_LATE) {
                    return Step::None;
                }
                self.state = State::Decided(class);
                let amount = match class {
                    Class::Turn => dot(self.moved, prototypes.turn),
                    Class::Drag(drag) => prototypes.slider_axis(drag).map_or(0.0, |axis| dot(self.moved, axis)),
                    Class::Unknown => 0.0,
                };
                Step::Decided { class, amount }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: [f64; 3], b: [f64; 3]) -> bool {
        (0..3).all(|i| (a[i] - b[i]).abs() < 1e-9)
    }

    #[test]
    fn the_forearm_frame_puts_up_on_z_and_round_trips() {
        let up = [-0.455, 0.0, -0.588];
        let r = roll(up);
        let f = to_forearm(up, r);
        assert!(f[0].abs() < 1e-9 && f[2] > 0.0);
        let v = [0.3, -0.2, 0.9];
        assert!(close(from_forearm(to_forearm(v, 37.0), 37.0), v));
    }

    #[test]
    fn a_pitched_forearm_keeps_ups_y_part() {
        let up = [-0.3, 0.6, -0.4];
        let f = to_forearm(up, roll(up));
        assert!(f[0].abs() < 1e-9, "{f:?}");
        assert!((f[1] - 0.6).abs() < 1e-12, "{f:?}");
        assert!(f[2] > 0.0, "{f:?}");
    }

    #[test]
    fn the_roll_falls_back_when_the_forearm_is_nearly_vertical() {
        assert_eq!(roll_or([0.1, 0.99, 0.1], -142.3), -142.3);
        assert_eq!(roll_or([0.0, -1.0, 0.0], 7.0), 7.0);
        assert_eq!(roll_or([f64::NAN, 0.0, 1.0], 7.0), 7.0);
        let up = [-0.455, 0.0, -0.588];
        assert_eq!(roll_or(up, 7.0), roll(up));
        let p = Prototypes::right_hand();
        assert_eq!(p.roll_for(None), p.palm_down_roll);
        assert!(p.roll_for(Some([1.0, 0.0, 0.0, 0.0])).abs() < 1e-12, "identity: up on z, roll 0");
        // 90° about x: up along the band's y (the forearm points straight up).
        let h = std::f32::consts::FRAC_1_SQRT_2;
        assert_eq!(p.roll_for(Some([h, h, 0.0, 0.0])), p.palm_down_roll);
    }

    #[test]
    fn identity_orientation_has_up_on_the_bands_z() {
        assert!(close(up_in_band([1.0, 0.0, 0.0, 0.0]), [0.0, 0.0, 1.0]));
    }

    #[test]
    fn every_prototype_has_unit_length() {
        let p = Prototypes::right_hand();
        for v in std::iter::once(p.turn).chain(p.drags.unwrap().map(Option::unwrap)) {
            assert!((norm(v) - 1.0).abs() < 1e-12, "{v:?}");
        }
    }

    #[test]
    fn each_prototype_classifies_as_itself() {
        let p = Prototypes::right_hand();
        assert_eq!(p.classify(p.turn).0, Class::Turn);
        assert_eq!(p.classify(p.turn.map(|v| -v)).0, Class::Turn);
        for (drag, v) in Drag::ALL.iter().zip(p.drags.unwrap().map(Option::unwrap)) {
            assert_eq!(p.classify(v).0, Class::Drag(*drag));
        }
    }

    #[test]
    fn taught_prototypes_are_unit_and_refuse_lookalikes() {
        let p = Prototypes::right_hand();
        let drags = p.drags.unwrap().map(|v| v.map(|v| v.map(|x| x * 20.0)));
        let taught = Prototypes::taught(p.turn.map(|x| x * 30.0), drags, -140.0).expect("distinct");
        assert!((norm(taught.turn) - 1.0).abs() < 1e-12);
        assert_eq!(taught.palm_down_roll, -140.0);
        for (drag, v) in Drag::ALL.iter().zip(taught.drags.unwrap().map(Option::unwrap)) {
            assert_eq!(taught.classify(v).0, Class::Drag(*drag));
        }
        // Two drags taught the same way can't be told apart.
        let mut same = drags;
        same[1] = same[0];
        assert_eq!(Prototypes::taught(p.turn, same, -140.0), Err(TaughtError::TooAlike(Drag::Left, Drag::Right)));
        // A drag taught like the turn neither.
        let mut turnish = drags;
        turnish[2] = Some(p.turn);
        assert_eq!(Prototypes::taught(p.turn, turnish, -140.0), Err(TaughtError::LikeTheTurn(Drag::Toward)));
        // …nor one taught the turn's other way.
        let mut turnish = drags;
        turnish[3] = Some(p.turn.map(|x| -x));
        assert_eq!(Prototypes::taught(p.turn, turnish, -140.0), Err(TaughtError::LikeTheTurn(Drag::Away)));
        assert_eq!(Prototypes::taught([0.0; 3], drags, -140.0), Err(TaughtError::NoTurn));
        for broken in [f64::NAN, f64::INFINITY] {
            let mut bad = drags;
            bad[4] = Some([broken, 0.0, 0.0]);
            assert_eq!(Prototypes::taught(p.turn, bad, -140.0), Err(TaughtError::NoDrag(Drag::Up)), "{broken}");
        }
        assert_eq!(Prototypes::taught(p.turn, drags, f64::NAN), Err(TaughtError::NoRoll));
    }

    #[test]
    fn a_skipped_drag_is_never_read_nor_read_as_another() {
        let p = Prototypes::right_hand();
        let mut drags = p.drags.unwrap();
        drags[2] = None;
        drags[3] = None;
        let taught = Prototypes::taught(p.turn, drags, -140.0).expect("the rest are distinct");
        for (drag, v) in Drag::ALL.iter().zip(drags) {
            match v {
                Some(v) => assert_eq!(taught.classify(v).0, Class::Drag(*drag)),
                None => assert_eq!(taught.slider_axis(*drag), None),
            }
        }
        // A toward move, with toward and away skipped: like nothing known.
        let toward = p.drags.unwrap()[2].unwrap();
        assert_eq!(taught.classify(toward).0, Class::Unknown);
        // A skipped drag isn't checked against the others.
        let mut same = drags;
        same[2] = drags[0];
        assert!(Prototypes::taught(p.turn, drags, -140.0).is_ok());
        assert_eq!(Prototypes::taught(p.turn, same, -140.0), Err(TaughtError::TooAlike(Drag::Left, Drag::Toward)));
    }

    #[test]
    fn turns_only_knows_turns_and_nothing_else() {
        let p = Prototypes::turns_only();
        assert_eq!(p.classify([0.1, -1.0, 0.1]).0, Class::Turn);
        assert_eq!(p.classify([1.0, 0.1, 0.0]).0, Class::Unknown);
        assert_eq!(p.slider_axis(Drag::Right), None);
    }

    #[test]
    fn a_zero_or_broken_vector_classifies_as_unknown() {
        for p in [Prototypes::right_hand(), Prototypes::turns_only()] {
            assert_eq!(p.classify([0.0; 3]), (Class::Unknown, 0.0));
            assert_eq!(p.classify([f64::NAN, 1.0, 0.0]), (Class::Unknown, 0.0));
            assert_eq!(p.classify([f64::INFINITY, 1.0, 0.0]), (Class::Unknown, 0.0));
        }
    }

    #[test]
    fn drag_index_is_the_position_in_all() {
        for (i, drag) in Drag::ALL.iter().enumerate() {
            assert_eq!(drag.index(), i);
        }
    }

    #[test]
    fn the_opposite_drag_is_the_other_of_its_pair() {
        for drag in Drag::ALL {
            assert_ne!(drag.opposite(), drag);
            assert_eq!(drag.opposite().pair(), drag.pair());
            assert_eq!(drag.opposite().opposite(), drag);
        }
    }

    #[test]
    fn a_pinch_ignores_samples_with_a_bad_gap_or_rate() {
        let p = Prototypes::right_hand();
        let rate = p.turn.map(|v| v * 100.0);
        let mut pinch = Pinch::new(Finger::Index, 0.0, 0.0, Palm::Down);
        for dt in [f64::NAN, 5.0, -0.01, 0.0, f64::INFINITY] {
            assert_eq!(pinch.feed(rate, dt, 1.0, &p), Step::None, "{dt}");
            assert_eq!(pinch.moved(), [0.0; 3], "{dt}");
        }
        assert_eq!(pinch.feed([f64::NAN, 0.0, 0.0], 0.01, 1.0, &p), Step::None);
        assert_eq!(pinch.moved(), [0.0; 3]);
        assert_eq!(pinch.state(), State::Undecided);
    }

    #[test]
    fn a_nan_clock_never_decides() {
        let p = Prototypes::right_hand();
        let rate = p.turn.map(|v| v * 1000.0);
        let mut pinch = Pinch::new(Finger::Index, 0.0, 0.0, Palm::Down);
        for _ in 0..10 {
            assert_eq!(pinch.feed(rate, 0.01, f64::NAN, &p), Step::None);
        }
        assert_eq!(pinch.state(), State::Undecided);
        assert!(norm(pinch.moved()) > DECIDE_LATE);
    }

    #[test]
    fn a_pinch_decides_once_after_the_tap_time_and_15_degrees() {
        let p = Prototypes::right_hand();
        let mut pinch = Pinch::new(Finger::Index, 0.0, 0.0, Palm::Down);
        // 100 °/s along the turn axis, 10 ms samples: 15° at 0.15 s, but nothing is decided
        // before DECIDE_AFTER (0.2 s), so it decides at 0.2 s with ~20°.
        let rate = p.turn.map(|v| v * 100.0);
        let mut decided = None;
        for i in 1..=40 {
            let now = f64::from(i) * 0.01;
            if let Step::Decided { class, amount } = pinch.feed(rate, 0.01, now, &p) {
                assert!(decided.is_none(), "decides once");
                decided = Some((class, amount, now));
            }
        }
        let (class, amount, at) = decided.expect("decided");
        assert_eq!(class, Class::Turn);
        assert!((19.0..21.5).contains(&amount), "{amount}");
        assert!((0.199..0.211).contains(&at), "{at}");
        match pinch.feed(rate, 0.01, 0.5, &p) {
            Step::Moved(d) => assert!((d - 1.0).abs() < 1e-9, "{d}"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_taught_sample_comes_once_after_the_tap_time_and_15_degrees() {
        let p = Prototypes::right_hand();
        let mut pinch = Pinch::new(Finger::Index, 0.0, 0.0, Palm::Down);
        let rate = p.turn.map(|v| v * 100.0);
        let samples: Vec<(f64, [f64; 3])> = (1..=40)
            .filter_map(|i| {
                let now = f64::from(i) * 0.01;
                pinch.sample(rate, 0.01, now).map(|d| (now, d))
            })
            .collect();
        assert_eq!(samples.len(), 1);
        let (at, d) = samples[0];
        assert!((0.199..0.211).contains(&at), "{at}");
        assert!((dot(d, p.turn) - 1.0).abs() < 1e-9, "{d:?}");
        assert_eq!(pinch.state(), State::Done);
    }

    #[test]
    fn the_bias_is_learned_only_while_nearly_still() {
        let mut bias = GyroBias::default();
        for _ in 0..2000 {
            bias.learn([10.0, -5.0, 2.0], 0.01);
        }
        assert!(bias.rate([10.0, -5.0, 2.0]).iter().all(|r| r.abs() < 0.01));
        let before = bias.clone();
        bias.learn([500.0, 0.0, 0.0], 0.01);
        assert_eq!(bias, before);
    }

    #[test]
    fn the_bias_ignores_samples_with_a_bad_gap_or_value() {
        let mut bias = GyroBias::default();
        for dt in [f64::NAN, 5.0, -0.01, 0.0] {
            bias.learn([10.0, -5.0, 2.0], dt);
            assert_eq!(bias, GyroBias::default(), "{dt}");
        }
        bias.learn([f64::NAN, 0.0, 0.0], 0.01);
        bias.learn([f64::INFINITY, 0.0, 0.0], 0.01);
        assert_eq!(bias, GyroBias::default());
    }
}
