//! Palm down, sideways or up: the band's roll about the forearm (see `pinch::roll`) against
//! a calibration, with hysteresis.

/// How far past a boundary (degrees) the roll must go to change position.
pub const HYSTERESIS: f64 = 10.0;
/// A calibration sample set this spread out (degrees from its mean) wasn't held still.
pub const STILL_SPREAD: f64 = 10.0;
/// Palm down and palm up must be at least this far apart (degrees).
pub const MIN_APART: f64 = 60.0;
/// The roll of palm down on the owner's right wrist (measured 2026-10-25): the right hand's
/// calibration, and the pinch frame's roll when no orientation is known. (The owner's own
/// calibration, 2026-10-26: +2.3°.)
pub const RIGHT_PALM_DOWN_ROLL: f64 = -11.3;
/// The roll of palm up on the owner's right wrist (own calibration: −125.8°).
pub const RIGHT_PALM_UP_ROLL: f64 = -142.3;
/// What the right hand's palm down was taken to be until 2026-10-26 (it's palm up: the
/// recording's palm-down and palm-up steps were labelled the wrong way round). Drags taught
/// back then without a palm calibration carry it as their `Prototypes::palm_down_roll`; an app
/// reading such stored drags should take them as taught at `RIGHT_PALM_DOWN_ROLL` (the
/// directions themselves are in the forearm frame and don't change).
pub const SWAPPED_RIGHT_PALM_DOWN_ROLL: f64 = -142.3;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Palm {
    Down,
    Side,
    Up,
}

impl Palm {
    pub const ALL: [Palm; 3] = [Palm::Down, Palm::Side, Palm::Up];

    /// The name in config files and stored profiles.
    pub fn key(self) -> &'static str {
        match self {
            Palm::Down => "down",
            Palm::Side => "sideways",
            Palm::Up => "up",
        }
    }

    pub fn from_key(key: &str) -> Option<Palm> {
        Palm::ALL.into_iter().find(|palm| palm.key() == key)
    }
}

/// Some palm positions.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Palms(u8);

impl Palms {
    fn bit(palm: Palm) -> u8 {
        1 << palm as u8
    }

    pub fn contains(self, palm: Palm) -> bool {
        self.0 & Self::bit(palm) != 0
    }

    pub fn is_empty(self) -> bool {
        self.0 == 0
    }

    pub fn len(self) -> usize {
        self.0.count_ones() as usize
    }

    /// In `Palm::ALL` order.
    pub fn iter(self) -> impl Iterator<Item = Palm> {
        Palm::ALL.into_iter().filter(move |&palm| self.contains(palm))
    }
}

impl FromIterator<Palm> for Palms {
    fn from_iter<I: IntoIterator<Item = Palm>>(palms: I) -> Self {
        Self(palms.into_iter().fold(0, |bits, palm| bits | Self::bit(palm)))
    }
}

impl<const N: usize> From<[Palm; N]> for Palms {
    fn from(palms: [Palm; N]) -> Self {
        palms.into_iter().collect()
    }
}

impl std::fmt::Debug for Palms {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_set().entries(self.iter()).finish()
    }
}

/// An angle in (−180, 180].
pub fn wrap(degrees: f64) -> f64 {
    let a = degrees.rem_euclid(360.0);
    if a > 180.0 { a - 360.0 } else { a }
}

/// The circular mean of some angles (degrees), and the largest distance from it.
fn mean_and_spread(rolls: &[f64]) -> Option<(f64, f64)> {
    if rolls.is_empty() || rolls.iter().any(|r| !r.is_finite()) {
        return None;
    }
    let (s, c) = rolls.iter().fold((0.0, 0.0), |(s, c), r| {
        let (rs, rc) = r.to_radians().sin_cos();
        (s + rs, c + rc)
    });
    let mean = s.atan2(c).to_degrees();
    let spread = rolls.iter().map(|r| wrap(r - mean).abs()).fold(0.0, f64::max);
    Some((mean, spread))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CalibrationError {
    /// No usable samples for this position.
    Empty(Palm),
    /// The hand moved while this position was sampled.
    NotStill(Palm),
    /// Palm down and palm up came out closer than `MIN_APART`.
    TooClose,
}

/// Where palm down and palm up are, as rolls (degrees). Sideways is halfway.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PalmCalibration {
    pub down_roll: f64,
    pub up_roll: f64,
}

impl PalmCalibration {
    /// Measured on the owner's right wrist (2026-10-25).
    pub fn right_hand() -> Self {
        Self { down_roll: RIGHT_PALM_DOWN_ROLL, up_roll: RIGHT_PALM_UP_ROLL }
    }

    /// From rolls sampled while holding each position still (~2 s each).
    pub fn from_rolls(down: &[f64], up: &[f64]) -> Result<Self, CalibrationError> {
        let (down_roll, down_spread) = mean_and_spread(down).ok_or(CalibrationError::Empty(Palm::Down))?;
        let (up_roll, up_spread) = mean_and_spread(up).ok_or(CalibrationError::Empty(Palm::Up))?;
        if down_spread > STILL_SPREAD {
            return Err(CalibrationError::NotStill(Palm::Down));
        }
        if up_spread > STILL_SPREAD {
            return Err(CalibrationError::NotStill(Palm::Up));
        }
        if wrap(up_roll - down_roll).abs() < MIN_APART {
            return Err(CalibrationError::TooClose);
        }
        Ok(Self { down_roll, up_roll })
    }

    /// The signed way from palm down to palm up (degrees).
    fn arc(&self) -> f64 {
        wrap(self.up_roll - self.down_roll)
    }

    pub fn side_roll(&self) -> f64 {
        wrap(self.down_roll + self.arc() / 2.0)
    }

    /// Where this roll is along the way from palm down (0) to palm up (1), measured from
    /// sideways so that rolls past either end stay on their side.
    fn fraction(&self, roll: f64) -> f64 {
        0.5 + wrap(roll - self.side_roll()) / self.arc()
    }

    /// The position for this roll, given the one before (hysteresis). A non-finite roll keeps
    /// the one before.
    pub fn position(&self, roll: f64, previous: Palm) -> Palm {
        if !roll.is_finite() {
            return previous;
        }
        let f = self.fraction(roll);
        let h = HYSTERESIS / self.arc().abs();
        let stays = match previous {
            Palm::Down => f < 0.25 + h,
            Palm::Side => f > 0.25 - h && f < 0.75 + h,
            Palm::Up => f > 0.75 - h,
        };
        if stays {
            return previous;
        }
        if f < 0.25 {
            Palm::Down
        } else if f < 0.75 {
            Palm::Side
        } else {
            Palm::Up
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_measured_positions_land_where_they_should_from_any_start() {
        let c = PalmCalibration::right_hand();
        assert_eq!((c.down_roll, c.up_roll), (-11.3, -142.3), "palm down −11.3°, palm up −142.3°");
        assert_eq!(c.down_roll, RIGHT_PALM_DOWN_ROLL);
        for start in Palm::ALL {
            assert_eq!(c.position(-11.3, start), Palm::Down, "{start:?}");
            assert_eq!(c.position(-71.2, start), Palm::Side, "{start:?}");
            assert_eq!(c.position(-142.3, start), Palm::Up, "{start:?}");
            // The owner's own calibration (2026-10-26): palm down +2.3°, palm up −125.8°.
            assert_eq!(c.position(2.3, start), Palm::Down, "{start:?}");
            assert_eq!(c.position(-125.8, start), Palm::Up, "{start:?}");
        }
        assert!((c.side_roll() - -76.8).abs() < 0.1);
    }

    #[test]
    fn hysteresis_holds_near_a_boundary() {
        let c = PalmCalibration::right_hand();
        // The down/side boundary is a quarter of the way: −11.3 − 131 / 4 ≈ −44.05.
        assert_eq!(c.position(-48.6, Palm::Down), Palm::Down);
        assert_eq!(c.position(-48.6, Palm::Side), Palm::Side);
        assert_eq!(c.position(-58.6, Palm::Down), Palm::Side);
    }

    #[test]
    fn rolls_past_either_end_stay_on_their_side() {
        let c = PalmCalibration::right_hand();
        assert_eq!(c.position(-11.3 + 70.0, Palm::Side), Palm::Down);
        assert_eq!(c.position(-142.3 - 70.0, Palm::Side), Palm::Up);
    }

    #[test]
    fn a_non_finite_roll_keeps_the_position() {
        assert_eq!(PalmCalibration::right_hand().position(f64::NAN, Palm::Up), Palm::Up);
    }

    #[test]
    fn calibration_needs_still_samples_far_enough_apart() {
        assert_eq!(PalmCalibration::from_rolls(&[], &[0.0]), Err(CalibrationError::Empty(Palm::Down)));
        assert_eq!(
            PalmCalibration::from_rolls(&[-140.0, -110.0], &[-10.0]),
            Err(CalibrationError::NotStill(Palm::Down))
        );
        assert_eq!(PalmCalibration::from_rolls(&[-40.0], &[-10.0]), Err(CalibrationError::TooClose));
        let c = PalmCalibration::from_rolls(&[-141.0, -143.0], &[-11.0, -9.0]).expect("fine");
        assert!((c.down_roll - -142.0).abs() < 1e-9);
        assert!((c.up_roll - -10.0).abs() < 1e-9);
        // A position across ±180° (palm up there is only 38° from −142°, so the wrap is tested
        // with palm down there instead).
        let c = PalmCalibration::from_rolls(&[179.0, -179.0], &[-71.0, -69.0]).expect("fine");
        assert!((wrap(c.down_roll - 180.0)).abs() < 1e-9, "the mean wraps: {}", c.down_roll);
    }

    #[test]
    fn a_set_of_palms() {
        let set: Palms = [Palm::Up, Palm::Down, Palm::Up].into_iter().collect();
        assert!(set.contains(Palm::Down) && set.contains(Palm::Up) && !set.contains(Palm::Side));
        assert_eq!(set.iter().collect::<Vec<_>>(), [Palm::Down, Palm::Up]);
        assert!(Palms::default().is_empty() && !set.is_empty());
        assert_eq!((set.len(), Palms::from(Palm::ALL).len()), (2, 3));
        assert_eq!(format!("{set:?}"), "{Down, Up}");
    }

    #[test]
    fn keys_round_trip() {
        for palm in Palm::ALL {
            assert_eq!(Palm::from_key(palm.key()), Some(palm));
        }
        assert_eq!(Palm::from_key("side"), None);
    }
}
