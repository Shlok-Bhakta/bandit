mod recordings;

use band_core::controls::palm::{CalibrationError, Palm, PalmCalibration};
use band_core::controls::pinch::{roll, up_in_band};
use recordings::{Line, read, step_at};

#[test]
fn every_press_in_the_palm_steps_lands_in_its_position() {
    let lines = read("rec1-holds-turns-palm.log");
    let c = PalmCalibration::right_hand();
    let mut palm = Palm::Down;
    let mut checked = 0;
    for line in &lines {
        match line {
            Line::Quat { q, .. } => palm = c.position(roll(up_in_band(*q)), palm),
            Line::Gesture { t, action, synthetic: false, .. } if action == "press" => {
                let step = step_at(&lines, *t);
                // A press this soon after a step began belongs to the step before (the late
                // step-1 tap at 20.04 s).
                let began = lines.iter().rev().find_map(|l| match l { Line::Step { t: s, .. } if s <= t => Some(*s), _ => None });
                if began.is_some_and(|began| t - began < 0.5) {
                    continue;
                }
                // The recording's steps 1 and 2 are labelled the wrong way round: step 1 ("palm
                // down") was held palm up, step 2 ("palm up") palm down (the owner, 2026-10-26).
                let want = if step.starts_with("1/11") {
                    Palm::Up
                } else if step.starts_with("2/11") {
                    Palm::Down
                } else if step.starts_with("3/11") {
                    Palm::Side
                } else {
                    continue;
                };
                assert_eq!(palm, want, "{t} {step}");
                checked += 1;
            }
            _ => {}
        }
    }
    // Steps 1–3 have 8 presses; the late step-1 tap at 20.04 s is left out.
    assert_eq!(checked, 7, "presses in steps 1–3");
}

#[test]
fn the_recording_calibrates_close_to_the_defaults() {
    let lines = read("rec1-holds-turns-palm.log");
    let rolls_between = |from: f64, to: f64| -> Vec<f64> {
        lines
            .iter()
            .filter_map(|l| match l {
                Line::Quat { t, q } if *t >= from && *t < to => Some(roll(up_in_band(*q))),
                _ => None,
            })
            .collect()
    };
    // Palm down is step 2 (23–30 s), palm up step 1 (6–11 s): the labels are swapped.
    let c = PalmCalibration::from_rolls(&rolls_between(23.0, 30.0), &rolls_between(6.0, 11.0)).expect("still");
    let defaults = PalmCalibration::right_hand();
    assert!((c.down_roll - defaults.down_roll).abs() < 5.0, "{c:?}");
    assert!((c.up_roll - defaults.up_roll).abs() < 5.0, "{c:?}");
    // The hand turning (12–14 s) isn't still.
    assert_eq!(
        PalmCalibration::from_rolls(&rolls_between(23.0, 30.0), &rolls_between(12.0, 14.0)),
        Err(CalibrationError::NotStill(Palm::Up))
    );
}
