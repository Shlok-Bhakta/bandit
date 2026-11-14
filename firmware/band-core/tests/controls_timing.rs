//! When held taps fire: the triple's echo double, a held tap replaced by another finger's,
//! and a poll that comes late.

mod controls_common;

use band_core::controls::{BandControls, Controls, Gesture};
use controls_common::*;

/// Two copies of a profile, with these band controls.
fn twice(bindings: &[(Gesture, String)], band: BandControls) -> Controls<String> {
    live(with_band(profiles(vec![profile("a", bindings), profile("b", bindings)]), band))
}

#[test]
fn the_echo_double_after_a_switching_triple_is_swallowed_in_the_new_profile() {
    // Profile b has no index triple (so its index taps don't wait), but binds the double.
    let mut c = live(with_band(
        profiles(vec![profile("a", &[]), profile("b", &[(Gesture::IndexDouble, run("b-double"))])]),
        band(None, Some(Gesture::IndexTriple), Some(Gesture::MiddleTriple)),
    ));
    let out = triple(&mut c, "index", 2.0);
    assert_eq!(switches(&out), [(1, 1)]);
    assert!(runs(&out).is_empty(), "{out:?}");
}

#[test]
fn a_held_index_tap_still_runs_when_a_middle_tap_follows() {
    let mut c = live(profiles(vec![profile(
        "p",
        &[
            (Gesture::IndexTap, run("play")),
            (Gesture::IndexDouble, run("x")),
            (Gesture::MiddleTap, run("mute")),
            (Gesture::MiddleDouble, run("y")),
        ],
    )]));
    let mut out = gesture(&mut c, "index", "tap", 1, 1.0);
    out.extend(gesture(&mut c, "middle", "tap", 2, 1.2));
    out.extend(c.poll(3.0));
    assert_eq!(runs(&out), ["play", "mute"]);
}

#[test]
fn a_tap_held_for_a_triple_still_runs_when_the_other_finger_taps() {
    let mut c = twice(
        &[(Gesture::IndexTap, run("play")), (Gesture::MiddleTap, run("mute"))],
        band(None, Some(Gesture::IndexTriple), Some(Gesture::MiddleTriple)),
    );
    let mut out = gesture(&mut c, "index", "tap", 1, 1.0);
    out.extend(gesture(&mut c, "middle", "tap", 2, 1.2));
    out.extend(c.poll(3.0));
    out.extend(c.poll(4.0));
    assert_eq!(runs(&out), ["play", "mute"]);
}

#[test]
fn a_held_tap_still_runs_when_the_other_finger_triples() {
    // The middle single does nothing, so only the middle triple holds anything back.
    let mut c = twice(
        &[(Gesture::IndexTap, run("play")), (Gesture::IndexDouble, run("x"))],
        band(None, Some(Gesture::MiddleTriple), None),
    );
    let mut out = gesture(&mut c, "index", "tap", 1, 1.0);
    out.extend(gesture(&mut c, "middle", "tap", 2, 1.1));
    out.extend(gesture(&mut c, "middle", "tap", 3, 1.25));
    out.extend(gesture(&mut c, "middle", "tap", 4, 1.38));
    out.extend(c.poll(3.0));
    assert_eq!(runs(&out), ["play"]);
    assert_eq!(switches(&out), [(1, 1)]);
}

#[test]
fn a_late_poll_does_not_merge_two_slow_taps() {
    let mut c = twice(&[(Gesture::IndexTap, run("play"))], band(None, Some(Gesture::IndexTriple), None));
    let mut out = gesture(&mut c, "index", "tap", 1, 1.0);
    // Due at 1.45; the tick at 1.40 is too early and the next one comes after the 2nd tap.
    out.extend(c.poll(1.40));
    out.extend(gesture(&mut c, "index", "tap", 2, 1.47));
    out.extend(c.poll(3.0));
    assert_eq!(runs(&out), ["play", "play"]);
    assert!(switches(&out).is_empty());
}

#[test]
fn a_late_poll_does_not_merge_two_taps_waiting_for_a_double() {
    let mut c = live(profiles(vec![profile("p", &[(Gesture::IndexTap, run("play")), (Gesture::IndexDouble, run("dbl"))])]));
    let mut out = gesture(&mut c, "index", "tap", 1, 1.0);
    // Due at 1.40; no tick before the next tap.
    out.extend(gesture(&mut c, "index", "tap", 2, 1.42));
    out.extend(c.poll(3.0));
    assert_eq!(gestures(&out), [Gesture::IndexTap, Gesture::IndexTap]);
    assert_eq!(runs(&out), ["play", "play"]);
}

#[test]
fn a_double_that_fired_ends_the_triple_sequence() {
    let mut c = live(with_band(
        profiles(vec![profile("p", &[(Gesture::MiddleDouble, run("mute"))])]),
        band(Some(Gesture::MiddleTriple), None, None),
    ));
    let mut out = gesture(&mut c, "middle", "tap", 1, 2.0);
    // The band's double tap a moment before its tap.
    out.extend(gesture(&mut c, "middle", "doubletap", 2, 2.25));
    out.extend(gesture(&mut c, "middle", "tap", 3, 2.27));
    let due = c.next_deadline().expect("the double tap is held");
    out.extend(c.poll(due));
    assert_eq!(runs(&out), ["mute"]);
    // A new tap after the double ran starts afresh: not the third tap of a triple.
    let out = gesture(&mut c, "middle", "tap", 4, due + 0.01);
    assert!(toggles(&out).is_empty(), "{out:?}");
    assert!(!c.status().paused);
}

#[test]
fn one_hold_acts_once_however_long_it_lasts() {
    let mut c = live(with_band(profiles(vec![profile("a", &[])]), band(Some(Gesture::MiddleHold), None, None)));
    let mut out = Vec::new();
    // The band repeats a long hold every 0.3 s.
    for (sequence, at) in [(1, 1.0), (2, 1.3), (3, 1.6), (4, 1.9), (5, 2.2)] {
        out.extend(gesture(&mut c, "middle", "hold", sequence, at));
    }
    assert_eq!(toggles(&out), [false]);
    // A new hold, after a gap.
    assert_eq!(toggles(&gesture(&mut c, "middle", "hold", 6, 3.5)), [true]);
}

#[test]
fn a_held_tap_runs_in_the_profile_it_was_made_in() {
    let mut c = live(with_band(
        profiles(vec![
            profile("a", &[(Gesture::IndexTap, run("a-tap")), (Gesture::IndexDouble, run("a-dbl"))]),
            profile("b", &[(Gesture::IndexTap, run("b-tap"))]),
        ]),
        band(None, Some(Gesture::SwipeUp), None),
    ));
    let mut out = gesture(&mut c, "index", "tap", 1, 1.0);
    out.extend(gesture(&mut c, "thumb", "up", 2, 1.1));
    out.extend(c.poll(2.0));
    assert_eq!(switches(&out), [(1, 1)]);
    assert_eq!(runs(&out), ["a-tap"]);
}

fn close(a: Option<f64>, b: f64) -> bool {
    a.is_some_and(|a| (a - b).abs() < 1e-9)
}

#[test]
fn the_deadline_is_the_double_wait_its_extension_or_the_triple_gap() {
    let mut c = live(profiles(vec![profile("p", &[(Gesture::IndexTap, run("play")), (Gesture::IndexDouble, run("dbl"))])]));
    assert_eq!(c.next_deadline(), None);
    gesture(&mut c, "index", "tap", 1, 1.0);
    assert!(close(c.next_deadline(), 1.4), "{:?}", c.next_deadline());
    // A second tap without its double tap (yet): a little longer.
    gesture(&mut c, "index", "tap", 2, 1.35);
    assert!(close(c.next_deadline(), 1.43), "{:?}", c.next_deadline());
    // With a triple in play, the whole triple gap.
    let mut c = twice(&[(Gesture::IndexTap, run("play"))], band(None, Some(Gesture::IndexTriple), None));
    gesture(&mut c, "index", "tap", 1, 1.0);
    assert!(close(c.next_deadline(), 1.45), "{:?}", c.next_deadline());
    gesture(&mut c, "index", "tap", 2, 1.3);
    assert!(close(c.next_deadline(), 1.75), "{:?}", c.next_deadline());
}
