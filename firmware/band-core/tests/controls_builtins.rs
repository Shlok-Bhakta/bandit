mod controls_common;

use band_core::controls::{CallBinding, Gesture, Output, Palm, Unused};
use band_core::events::Event;
use controls_common::*;

#[test]
fn the_call_layer_overrides_then_steps_back() {
    let mut list = profiles(vec![profile(
        "a",
        &[(Gesture::IndexTap, run("play")), (Gesture::MiddleTap, run("mute"))],
    )]);
    list.calls.insert(Gesture::IndexTap, CallBinding::Do(run("call.answer").into()));
    list.calls.insert(Gesture::MiddleTap, CallBinding::Nothing);
    let mut c = live(list);
    c.set_in_call(true);
    assert_eq!(runs(&gesture(&mut c, "index", "tap", 1, 1.0)), ["call.answer"]);
    assert!(runs(&gesture(&mut c, "middle", "tap", 2, 2.0)).is_empty());
    c.set_in_call(false);
    assert_eq!(runs(&gesture(&mut c, "index", "tap", 3, 3.0)), ["play"]);
}

#[test]
fn practice_reports_without_acting() {
    let mut c = live(with_band(
        profiles(vec![profile("a", &[(Gesture::IndexTap, run("play"))]), profile("b", &[])]),
        band(Some(Gesture::MiddleHold), Some(Gesture::SwipeUp), None),
    ));
    c.set_practice(true);
    let tap = gesture(&mut c, "index", "tap", 1, 1.0);
    assert_eq!(tap, [Output::Gesture { gesture: Gesture::IndexTap, palm: Palm::Down }, Output::Practiced("play".into())]);
    let hold = gesture(&mut c, "middle", "hold", 2, 2.0);
    let paused = Output::Unused { gesture: Gesture::MiddleHold, why: Unused::Paused(band_core::controls::Builtin::Controls) };
    assert_eq!(hold, [Output::Gesture { gesture: Gesture::MiddleHold, palm: Palm::Down }, paused]);
    assert!(!c.status().paused);
    let next = Output::Unused { gesture: Gesture::SwipeUp, why: Unused::Paused(band_core::controls::Builtin::NextProfile) };
    assert_eq!(gesture(&mut c, "thumb", "up", 3, 3.0), [Output::Gesture { gesture: Gesture::SwipeUp, palm: Palm::Down }, next]);
    assert_eq!(c.active(), 0);
}

#[test]
fn practice_works_while_the_controls_are_off() {
    let mut c = live(profiles(vec![profile("a", &[(Gesture::IndexTap, run("play"))])]));
    c.pause();
    c.set_practice(true);
    assert!(gesture(&mut c, "index", "tap", 1, 1.0).contains(&Output::Practiced("play".into())));
}

#[test]
fn every_gesture_is_reported_even_while_off() {
    let mut c = live(profiles(vec![profile("a", &[(Gesture::SwipeLeft, run("x"))])]));
    c.pause();
    assert_eq!(gestures(&gesture(&mut c, "thumb", "left", 1, 1.0)), [Gesture::SwipeLeft]);
    assert_eq!(c.status().gestures, 1);
}

#[test]
fn new_bindings_keep_a_held_tap_and_the_dial() {
    let bindings = [(Gesture::IndexTap, run("play")), (Gesture::IndexDouble, run("dial-switch"))];
    let mut first = profile("a", &bindings);
    first.index.dial = dial("up", "down");
    let mut c = live(profiles(vec![first.clone()]));
    c.on_event(&Event::Handedness(band_core::events::Hand::Right), 0.1);
    gesture(&mut c, "index", "tap", 1, 1.0); // held for its double
    c.set_profiles(profiles(vec![first]));
    assert_eq!(runs(&c.poll(1.45)), ["play"]);
    // A pinch in progress carries on with the new bindings' dial.
    press(&mut c, "index", 10, 2.0);
    still(&mut c, 2.01, 0.24);
    c.set_profiles(profiles(vec![{
        let mut p = profile("a", &bindings);
        p.index.dial = dial("up2", "down2");
        p
    }]));
    let mut out = motion(&mut c, turn_dir(), 30.0, 2.31, 0.5);
    out.extend(release(&mut c, "index", 11, 2.85));
    assert_only(&runs(&out), "up2");
}

#[test]
fn pause_and_resume_report_once() {
    let mut c = live(profiles(vec![profile("a", &[])]));
    assert_eq!(toggles(&c.pause()), [false]);
    assert!(c.pause().is_empty());
    assert_eq!(toggles(&c.resume(1.0)), [true]);
    assert!(c.resume(2.0).is_empty());
}

#[test]
fn picking_a_profile_reports_the_switch_unless_an_app_holds_one() {
    let mut list = profiles(vec![profile("a", &[]), profile("b", &[])]);
    list.apps.insert("app".into(), 0);
    let mut c = live(list);
    assert_eq!(switches(&c.pick(1)), [(1, 0)]);
    c.set_foreground(Some("app".into()));
    // The app's own profile stays active, so picking changes nothing you can see yet.
    assert!(c.pick(0).is_empty());
    assert_eq!(c.active(), 0);
    assert_eq!(c.profiles().picked, 0, "the pick is kept for when the app leaves");
    // The picked profile is the app's own, so leaving the app changes nothing either.
    assert!(c.set_foreground(None).is_empty());
    assert_eq!(c.active(), 0);
    assert!(c.pick(9).is_empty());
    assert_eq!(c.profiles().picked, 0);
}

#[test]
fn a_run_action_can_be_anything_the_app_understands() {
    let mut c: band_core::controls::Controls<String> =
        live(profiles(vec![profile("a", &[(Gesture::MiddleHold, "lock-screen".into())])]));
    assert_eq!(runs(&gesture(&mut c, "middle", "hold", 1, 1.0)), ["lock-screen"]);
    // The band repeats a hold; it acts once.
    assert!(runs(&gesture(&mut c, "middle", "hold", 2, 1.4)).is_empty());
}

#[test]
fn the_platform_can_read_the_controls_state() {
    let mut c = band_core::controls::Controls::new(Default::default(), profiles(vec![profile("a", &[])]));
    assert!(!c.live());
    assert!(c.enabled());
    assert!(!c.in_call() && !c.practice());
    assert_eq!(c.foreground(), None);
    c.on_event(&Event::Connected, 0.0);
    c.set_in_call(true);
    c.set_practice(true);
    c.set_foreground(Some("org.videolan.vlc".into()));
    c.pause();
    assert!(c.live());
    assert!(!c.enabled());
    assert!(c.in_call() && c.practice());
    assert_eq!(c.foreground(), Some("org.videolan.vlc"));
    c.on_disconnect();
    assert!(!c.live());
}

#[test]
fn the_dial_is_the_active_profiles_until_overridden_and_a_switch_clears_the_override() {
    let mut a = profile("a", &[]);
    a.index.dial = dial("up", "down");
    let mut b = profile("b", &[]);
    b.index.dial = dial("b-up", "b-down");
    let mut c = live(profiles(vec![a, b]));
    assert_eq!(c.dial(), dial("up", "down").as_ref());
    assert!(!c.dial_overridden());
    c.set_dial(None);
    assert_eq!(c.dial(), None);
    assert!(c.dial_overridden());
    c.set_dial(dial("bri-up", "bri-down"));
    assert_eq!(c.dial(), dial("bri-up", "bri-down").as_ref());
    // Picking the profile that is already active changes nothing.
    assert!(c.pick(0).is_empty());
    assert!(c.dial_overridden());
    assert_eq!(switches(&c.pick(1)), [(1, 0)]);
    assert!(!c.dial_overridden());
    assert_eq!(c.dial(), dial("b-up", "b-down").as_ref());
    c.clear_dial();
    assert!(!c.dial_overridden());
}

#[test]
fn new_profiles_report_when_the_active_profile_changes() {
    let mut c = live(profiles(vec![profile("a", &[]), profile("b", &[])]));
    c.pick(1);
    let mut fewer = profiles(vec![profile("a", &[])]);
    fewer.picked = 1;
    assert_eq!(c.set_profiles(fewer.clone()), [Output::Profile { index: 0, step: 0 }]);
    assert_eq!(c.status().profile, 0);
    assert!(c.set_profiles(fewer).is_empty());
}

#[test]
fn the_status_follows_the_active_profile() {
    let mut list = with_band(
        profiles(vec![profile("a", &[]), profile("b", &[]), profile("c", &[])]),
        band(None, Some(Gesture::SwipeUp), None),
    );
    list.apps.insert("app".into(), 2);
    let mut c = live(list);
    assert_eq!(c.status().profile, 0);
    c.pick(1);
    assert_eq!(c.status().profile, 1);
    gesture(&mut c, "thumb", "up", 1, 1.0);
    assert_eq!(c.status().profile, 2);
    gesture(&mut c, "thumb", "up", 2, 2.0);
    assert_eq!(c.status().profile, 0);
    c.set_foreground(Some("app".into()));
    assert_eq!(c.status().profile, 2);
    c.set_foreground(None);
    assert_eq!(c.status().profile, 0);
}
