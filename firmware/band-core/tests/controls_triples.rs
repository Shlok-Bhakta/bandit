mod controls_common;

use band_core::controls::{BandControls, Gesture};
use controls_common::*;

/// Two profiles (the first with these bindings) and today's band controls.
fn two(bindings: &[(Gesture, String)]) -> band_core::controls::Controls<String> {
    live(with_band(profiles(vec![profile("one", bindings), profile("two", &[])]), BandControls::standard()))
}

#[test]
fn an_index_triple_tap_is_the_next_profile() {
    let mut c = two(&[(Gesture::IndexTap, run("media.play_pause")), (Gesture::IndexDouble, run("dbl"))]);
    let out = triple(&mut c, "index", 2.0);
    assert_eq!(switches(&out), [(1, 1)]);
    assert!(runs(&out).is_empty(), "{out:?}");
}

#[test]
fn a_middle_triple_tap_is_the_previous_profile() {
    let mut c = two(&[(Gesture::MiddleDouble, run("volume.mute"))]);
    let out = triple(&mut c, "middle", 2.0);
    assert_eq!(switches(&out), [(1, -1)]);
    assert!(runs(&out).is_empty(), "{out:?}");
}

#[test]
fn with_one_profile_three_taps_are_just_taps() {
    let mut c = live(with_band(
        profiles(vec![profile("solo", &[(Gesture::IndexTap, run("media.play_pause"))])]),
        BandControls::standard(),
    ));
    let out = triple(&mut c, "index", 2.0);
    assert!(switches(&out).is_empty());
    assert!(runs(&out).contains(&"media.play_pause".to_owned()));
    // The triple can't act, so a tap doesn't wait for one: it runs at once.
    assert_eq!(runs(&gesture(&mut c, "index", "tap", 10, 5.0)), ["media.play_pause"]);
}

#[test]
fn with_profile_triples_a_lone_tap_still_runs_once_after_the_wait() {
    let mut c = two(&[(Gesture::IndexTap, run("media.play_pause"))]);
    assert!(runs(&gesture(&mut c, "index", "tap", 1, 2.0)).is_empty());
    assert!(runs(&c.poll(2.2)).is_empty());
    assert_eq!(runs(&c.poll(2.45)), ["media.play_pause"]);
    assert!(runs(&c.poll(3.0)).is_empty());
}

#[test]
fn a_slow_triple_tap_without_band_doubles_runs_no_single_tap() {
    let mut c = two(&[(Gesture::IndexTap, run("media.play_pause"))]);
    let mut out = Vec::new();
    // 0.38 s apart: too slow for the band's own double tap, quick enough for a triple.
    out.extend(gesture(&mut c, "index", "tap", 1, 2.0));
    out.extend(c.poll(2.3));
    out.extend(gesture(&mut c, "index", "tap", 2, 2.38));
    out.extend(c.poll(2.7));
    out.extend(gesture(&mut c, "index", "tap", 3, 2.76));
    out.extend(c.poll(4.0));
    assert!(runs(&out).is_empty());
    assert_eq!(switches(&out), [(1, 1)]);
}

#[test]
fn a_middle_hold_right_after_a_profile_triple_still_toggles_the_controls() {
    let mut c = two(&[(Gesture::MiddleDouble, run("volume.mute"))]);
    triple(&mut c, "middle", 2.0);
    gesture(&mut c, "middle", "hold", 9, 2.9);
    assert!(c.status().paused);
}

#[test]
fn profile_triples_do_nothing_while_controls_are_off() {
    let mut c = two(&[(Gesture::IndexTap, run("media.play_pause"))]);
    c.pause();
    assert!(switches(&triple(&mut c, "index", 2.0)).is_empty());
}

#[test]
fn new_bindings_mid_triple_keep_counting_its_taps() {
    let both = || {
        with_band(
            profiles(vec![profile("one", &[(Gesture::IndexTap, run("play"))]), profile("two", &[])]),
            BandControls::standard(),
        )
    };
    let mut c = live(both());
    let mut out = gesture(&mut c, "index", "tap", 1, 2.0);
    out.extend(gesture(&mut c, "index", "tap", 2, 2.2));
    out.extend(gesture(&mut c, "index", "doubletap", 3, 2.2));
    assert!(c.set_profiles(both()).is_empty());
    out.extend(gesture(&mut c, "index", "tap", 4, 2.4));
    out.extend(gesture(&mut c, "index", "doubletap", 5, 2.4));
    out.extend(c.poll(4.0));
    assert_eq!(switches(&out), [(1, 1)]);
    assert!(runs(&out).is_empty(), "{out:?}");
}
