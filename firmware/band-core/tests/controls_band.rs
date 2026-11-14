//! Band controls: above every profile, the call layer and an app's own profile; what they
//! cover is paused, not lost.

mod controls_common;

use band_core::controls::{
    BandControl, BandControls, Builtin, CallBinding, Controls, Gesture, Invalid, Output, Palm, PalmSet, Palms, Place, Profiles,
    TRIPLE_TAP_GAP, Unused, Warning,
};
use controls_common::*;

fn three_with_lock_on_hold() -> Profiles<String> {
    let mut list = with_band(
        profiles(vec![
            profile("a", &[(Gesture::MiddleHold, run("a-hold"))]),
            profile("b", &[(Gesture::MiddleHold, run("b-hold"))]),
            profile("vlc", &[(Gesture::MiddleHold, run("vlc-hold"))]),
        ]),
        BandControls::standard(),
    );
    list.apps.insert("org.videolan.vlc".into(), 2);
    list.calls.insert(Gesture::MiddleHold, CallBinding::Do(run("call-hold").into()));
    list
}

/// The hold turns the controls off, running nothing, then a new hold turns them back on.
#[track_caller]
fn locks_and_unlocks(c: &mut Controls<String>, sequence: u64, at: f64) {
    let out = gesture(c, "middle", "hold", sequence, at);
    assert_eq!(toggles(&out), [false]);
    assert!(runs(&out).is_empty(), "{out:?}");
    assert_eq!(toggles(&gesture(c, "middle", "hold", sequence + 1, at + 1.5)), [true]);
}

#[test]
fn a_band_control_wins_in_every_profile_an_apps_own_and_a_call() {
    let mut c = live(three_with_lock_on_hold());
    // The first profile.
    locks_and_unlocks(&mut c, 1, 1.0);
    // Another picked profile.
    c.pick(1);
    locks_and_unlocks(&mut c, 3, 4.0);
    // An app's own profile.
    c.set_foreground(Some("org.videolan.vlc".into()));
    locks_and_unlocks(&mut c, 5, 7.0);
    // In a call, with the call layer binding the hold too.
    c.set_in_call(true);
    locks_and_unlocks(&mut c, 7, 10.0);
}

#[test]
fn the_gesture_you_locked_with_unlocks_after_an_apps_profile_comes_to_the_front() {
    let mut c = live(three_with_lock_on_hold());
    assert_eq!(toggles(&gesture(&mut c, "middle", "hold", 1, 1.0)), [false]);
    c.set_foreground(Some("org.videolan.vlc".into()));
    assert_eq!(toggles(&gesture(&mut c, "middle", "hold", 2, 3.0)), [true]);
}

#[test]
fn a_band_control_wins_over_a_call_layer_nothing() {
    let mut list = with_band(profiles(vec![profile("a", &[])]), band(Some(Gesture::MiddleHold), None, None));
    list.calls.insert(Gesture::MiddleHold, CallBinding::Nothing);
    list.calls.insert(Gesture::SwipeDown, CallBinding::Do(run("call.hangup").into()));
    let mut c = live(list);
    c.set_in_call(true);
    // The call layer's `Nothing` on the hold doesn't cover the band control: the hold turns
    // the controls off, and back on.
    assert_eq!(toggles(&gesture(&mut c, "middle", "hold", 1, 1.0)), [false]);
    assert!(runs(&gesture(&mut c, "thumb", "down", 2, 2.0)).is_empty(), "off now");
    assert_eq!(toggles(&gesture(&mut c, "middle", "hold", 3, 4.0)), [true]);
    // On again: the call layer's other bindings run.
    assert_eq!(runs(&gesture(&mut c, "thumb", "down", 4, 5.0)), ["call.hangup"]);
}

#[test]
fn while_off_a_lock_triple_is_still_waited_for_in_a_call() {
    let mut list = with_band(
        profiles(vec![profile("a", &[(Gesture::MiddleTap, run("mute"))])]),
        band(Some(Gesture::MiddleTriple), None, None),
    );
    list.calls.insert(Gesture::MiddleTriple, CallBinding::Nothing);
    let mut c = live(list);
    c.set_in_call(true);
    c.pause();
    let out = triple(&mut c, "middle", 2.0);
    assert_eq!(toggles(&out), [true]);
    assert!(runs(&out).is_empty());
}

#[test]
fn controls_on_off_works_on_any_gesture_and_only_it_works_while_off() {
    let mut c = live(with_band(
        profiles(vec![profile("p", &[(Gesture::SwipeRight, run("next-workspace"))])]),
        band(Some(Gesture::SwipeLeft), None, None),
    ));
    assert_eq!(toggles(&gesture(&mut c, "thumb", "left", 1, 1.0)), [false]);
    assert!(c.status().paused);
    assert!(runs(&gesture(&mut c, "thumb", "right", 2, 2.0)).is_empty());
    assert_eq!(toggles(&gesture(&mut c, "thumb", "left", 3, 3.0)), [true]);
    assert_eq!(runs(&gesture(&mut c, "thumb", "right", 4, 4.0)), ["next-workspace"]);
}

#[test]
fn controls_on_off_can_sit_on_a_single_tap() {
    let mut c = live(with_band(profiles(vec![profile("p", &[])]), band(Some(Gesture::IndexTap), None, None)));
    assert_eq!(toggles(&gesture(&mut c, "index", "tap", 1, 1.0)), [false]);
    assert_eq!(toggles(&gesture(&mut c, "index", "tap", 2, 2.0)), [true]);
    // With a double tap bound, the single waits for it, and still works while off.
    let mut c = live(with_band(
        profiles(vec![profile("p", &[(Gesture::IndexDouble, run("x"))])]),
        band(Some(Gesture::IndexTap), None, None),
    ));
    assert!(toggles(&gesture(&mut c, "index", "tap", 1, 1.0)).is_empty());
    assert_eq!(toggles(&c.poll(1.5)), [false]);
    gesture(&mut c, "index", "tap", 2, 3.0);
    assert_eq!(toggles(&c.poll(3.5)), [true]);
}

#[test]
fn controls_on_off_can_sit_on_a_double_tap() {
    let mut c = live(with_band(
        profiles(vec![profile("a", &[(Gesture::IndexDouble, run("double"))])]),
        band(Some(Gesture::IndexDouble), None, None),
    ));
    gesture(&mut c, "index", "tap", 1, 1.0);
    let out = gesture(&mut c, "index", "doubletap", 2, 1.25);
    assert_eq!(toggles(&out), [false]);
    assert!(runs(&out).is_empty(), "{out:?}");
    gesture(&mut c, "index", "tap", 3, 3.0);
    assert_eq!(toggles(&gesture(&mut c, "index", "doubletap", 4, 3.25)), [true]);
}

#[test]
fn next_can_sit_on_a_single_tap() {
    let mut c = live(with_band(
        profiles(vec![profile("a", &[(Gesture::IndexTap, run("tap"))]), profile("b", &[]), profile("c", &[])]),
        band(None, Some(Gesture::IndexTap), None),
    ));
    let out = gesture(&mut c, "index", "tap", 1, 1.0);
    assert_eq!(switches(&out), [(1, 1)]);
    assert!(runs(&out).is_empty(), "{out:?}");
}

#[test]
fn previous_can_sit_on_a_single_tap() {
    let mut c = live(with_band(
        profiles(vec![profile("a", &[(Gesture::MiddleTap, run("tap"))]), profile("b", &[]), profile("c", &[])]),
        band(None, None, Some(Gesture::MiddleTap)),
    ));
    let out = gesture(&mut c, "middle", "tap", 1, 1.0);
    assert_eq!(switches(&out), [(2, -1)]);
    assert!(runs(&out).is_empty(), "{out:?}");
}

#[test]
fn next_and_previous_can_sit_on_a_double_tap() {
    let two = |controls: BandControls| {
        with_band(
            profiles(vec![
                profile("a", &[(Gesture::IndexDouble, run("double"))]),
                profile("b", &[(Gesture::IndexDouble, run("double"))]),
            ]),
            controls,
        )
    };
    let mut c = live(two(band(None, Some(Gesture::IndexDouble), None)));
    gesture(&mut c, "index", "tap", 1, 1.0);
    let out = gesture(&mut c, "index", "doubletap", 2, 1.25);
    assert_eq!(switches(&out), [(1, 1)]);
    assert!(runs(&out).is_empty(), "{out:?}");
    gesture(&mut c, "index", "tap", 3, 3.0);
    // Next from the last profile wraps to the first.
    assert_eq!(switches(&gesture(&mut c, "index", "doubletap", 4, 3.25)), [(0, 1)]);
    let mut c = live(two(band(None, None, Some(Gesture::IndexDouble))));
    gesture(&mut c, "index", "tap", 1, 1.0);
    let out = gesture(&mut c, "index", "doubletap", 2, 1.25);
    assert_eq!(switches(&out), [(1, -1)]);
    assert!(runs(&out).is_empty(), "{out:?}");
    gesture(&mut c, "index", "tap", 3, 3.0);
    assert_eq!(switches(&gesture(&mut c, "index", "doubletap", 4, 3.25)), [(0, -1)]);
}

#[test]
fn previous_can_sit_on_the_middle_hold() {
    let mut c = live(with_band(
        profiles(vec![
            profile("a", &[(Gesture::MiddleHold, run("hold"))]),
            profile("b", &[]),
            profile("c", &[]),
        ]),
        band(None, None, Some(Gesture::MiddleHold)),
    ));
    let out = gesture(&mut c, "middle", "hold", 1, 1.0);
    assert_eq!(switches(&out), [(2, -1)]);
    assert!(runs(&out).is_empty(), "{out:?}");
    // The band repeating the same hold: one step.
    assert!(switches(&gesture(&mut c, "middle", "hold", 2, 1.3)).is_empty());
    // A new hold, after a gap: another step.
    assert_eq!(switches(&gesture(&mut c, "middle", "hold", 3, 3.0)), [(1, -1)]);
}

#[test]
fn next_and_previous_wrap_around() {
    let three = || with_band(
        profiles(vec![profile("a", &[]), profile("b", &[]), profile("c", &[])]),
        band(None, Some(Gesture::SwipeUp), Some(Gesture::SwipeDown)),
    );
    let mut c = live(three());
    assert_eq!(switches(&gesture(&mut c, "thumb", "down", 1, 1.0)), [(2, -1)]);
    assert_eq!(switches(&gesture(&mut c, "thumb", "up", 2, 2.0)), [(0, 1)]);
}

#[test]
fn an_app_with_its_own_profile_holds_it_and_its_taps_do_not_wait() {
    let mut list = with_band(
        profiles(vec![
            profile("a", &[(Gesture::IndexTap, run("play"))]),
            profile("vlc", &[(Gesture::IndexTap, run("play"))]),
        ]),
        band(None, Some(Gesture::IndexTriple), None),
    );
    list.apps.insert("org.videolan.vlc".into(), 1);
    let mut c = live(list);
    assert_eq!(switches(&c.set_foreground(Some("org.videolan.vlc".into()))), [(1, 0)]);
    // No wait: the triple can't switch here.
    assert_eq!(runs(&gesture(&mut c, "index", "tap", 1, 1.0)), ["play"]);
    // A slow third tap: three plain taps, and no switch.
    gesture(&mut c, "index", "tap", 2, 1.3);
    let out = gesture(&mut c, "index", "tap", 3, 1.6);
    assert!(switches(&out).is_empty());
    assert_eq!(switches(&c.set_foreground(None)), [(0, 0)]);
}

#[test]
fn a_switch_refused_by_the_app_in_front_says_which_app() {
    let mut list =
        with_band(profiles(vec![profile("a", &[]), profile("b", &[])]), band(None, Some(Gesture::SwipeUp), None));
    list.apps.insert("com.example.reader".into(), 0);
    let mut c = live(list);
    c.set_foreground(Some("com.example.reader".into()));
    // The reader's profile has no triple in play, so the swipe itself is dispatched.
    let out = gesture(&mut c, "thumb", "up", 1, 1.0);
    assert!(out.contains(&Output::ProfileHeld { app: "com.example.reader".into() }));
}

#[test]
fn a_paused_action_runs_again_once_its_band_control_moves() {
    let list = || with_band(
        profiles(vec![profile("a", &[(Gesture::MiddleDouble, run("back"))])]),
        band(None, Some(Gesture::MiddleDouble), None),
    );
    let mut c = live(list());
    gesture(&mut c, "middle", "tap", 1, 1.0);
    let out = gesture(&mut c, "middle", "doubletap", 2, 1.25);
    assert!(runs(&out).is_empty(), "paused: {out:?}");
    let mut moved = list();
    moved.band.next = Some(BandControl::on(Gesture::IndexTriple));
    c.set_profiles(moved);
    gesture(&mut c, "middle", "tap", 3, 3.0);
    let mut out = gesture(&mut c, "middle", "doubletap", 4, 3.25);
    out.extend(c.poll(5.0));
    assert_eq!(runs(&out), ["back"]);
}

#[test]
fn next_and_previous_do_nothing_while_off_and_their_gesture_stays_theirs() {
    let list = || with_band(
        profiles(vec![profile("a", &[(Gesture::SwipeUp, run("up"))]), profile("b", &[])]),
        band(Some(Gesture::MiddleHold), Some(Gesture::SwipeUp), None),
    );
    // On: the swipe switches, and the profile's own swipe up stays paused.
    let mut c = live(list());
    let out = gesture(&mut c, "thumb", "up", 1, 1.0);
    assert_eq!(switches(&out), [(1, 1)]);
    assert!(runs(&out).is_empty(), "{out:?}");
    // Off: no switch, and still nothing runs.
    let mut c = live(list());
    c.pause();
    let out = gesture(&mut c, "thumb", "up", 1, 1.0);
    assert!(switches(&out).is_empty());
    assert!(runs(&out).is_empty());
    assert_eq!(c.active(), 0);
}

#[test]
fn practice_never_acts_on_a_band_control() {
    let mut c = live(with_band(profiles(vec![profile("a", &[]), profile("b", &[])]), BandControls::standard()));
    c.set_practice(true);
    assert_eq!(
        gesture(&mut c, "middle", "hold", 1, 1.0),
        [
            Output::Gesture { gesture: Gesture::MiddleHold, palm: Palm::Down },
            Output::Unused { gesture: Gesture::MiddleHold, why: Unused::Paused(Builtin::Controls) }
        ]
    );
    assert!(switches(&triple(&mut c, "index", 2.0)).is_empty());
    assert!(!c.status().paused);
}

/// Three index taps, then a single one: what runs after each. (The triple first: it uses
/// sequence numbers 1–5.)
fn triple_then_tap(c: &mut Controls<String>) {
    assert_eq!(runs(&triple(c, "index", 1.0)), ["x"]);
    assert!(runs(&gesture(c, "index", "tap", 10, 4.0)).is_empty(), "the tap waits for a triple");
    assert!(runs(&c.poll(4.0 + TRIPLE_TAP_GAP - 0.01)).is_empty());
    assert_eq!(runs(&c.poll(4.0 + TRIPLE_TAP_GAP)), ["tap"]);
}

#[test]
fn a_profiles_own_triple_makes_its_single_tap_wait() {
    let mut c =
        live(profiles(vec![profile("a", &[(Gesture::IndexTap, run("tap")), (Gesture::IndexTriple, run("x"))])]));
    triple_then_tap(&mut c);
}

#[test]
fn a_call_layer_triple_makes_the_single_tap_wait() {
    let mut list = profiles(vec![profile("a", &[(Gesture::IndexTap, run("tap"))])]);
    list.calls.insert(Gesture::IndexTriple, CallBinding::Do(run("x").into()));
    let mut c = live(list);
    c.set_in_call(true);
    triple_then_tap(&mut c);
}

#[test]
fn a_paused_triple_does_not_make_taps_wait() {
    // One profile: next can't act, and the profile's own triple is paused under it.
    let list = |bindings: &[(Gesture, String)]| {
        with_band(profiles(vec![profile("a", bindings)]), band(None, Some(Gesture::IndexTriple), None))
    };
    let mut c = live(list(&[(Gesture::IndexTap, run("tap")), (Gesture::IndexTriple, run("paused"))]));
    // Three taps are three plain taps (the triple first: it uses sequence numbers 1–5).
    let out = triple(&mut c, "index", 1.0);
    assert!(runs(&out).contains(&"tap".to_owned()), "{out:?}");
    assert!(!runs(&out).contains(&"paused".to_owned()), "{out:?}");
    assert!(switches(&out).is_empty());
    assert_eq!(runs(&gesture(&mut c, "index", "tap", 10, 4.0)), ["tap"]);
    assert!(c.next_deadline().is_none());
    // Without the tap: a triple runs nothing at all.
    let mut c = live(list(&[(Gesture::IndexTriple, run("paused"))]));
    let out = triple(&mut c, "index", 3.0);
    assert!(runs(&out).is_empty(), "{out:?}");
    assert!(switches(&out).is_empty());
}

#[test]
fn uses_lists_every_profile_and_the_call_layer() {
    let list = three_with_lock_on_hold();
    let places: Vec<Place> = list.uses(Gesture::MiddleHold).iter().map(|used| used.place).collect();
    assert_eq!(places, [Place::Profile(0), Place::Profile(1), Place::Profile(2), Place::Calls]);
    assert!(list.uses(Gesture::SwipeLeft).is_empty());
}

#[test]
fn a_call_layer_nothing_is_not_a_use() {
    let mut list = profiles(vec![profile("a", &[])]);
    list.calls.insert(Gesture::IndexTap, CallBinding::Nothing);
    assert!(list.uses(Gesture::IndexTap).is_empty());
}

/// What `paused()` lists: band control, gesture, where, action.
fn paused(list: &Profiles<String>) -> Vec<(Builtin, Gesture, Place, String)> {
    list.paused()
        .iter()
        .map(|paused| (paused.builtin, paused.gesture, paused.used.place, paused.used.action.clone()))
        .collect()
}

#[test]
fn paused_lists_by_band_control_then_profile_then_the_call_layer() {
    let mut list = with_band(
        profiles(vec![
            profile(
                "a",
                &[
                    (Gesture::MiddleTriple, run("a-prev")),
                    (Gesture::MiddleHold, run("a-lock")),
                    (Gesture::IndexTriple, run("a-next")),
                    (Gesture::SwipeLeft, run("a-left")),
                ],
            ),
            profile("b", &[(Gesture::IndexTriple, run("b-next")), (Gesture::MiddleHold, run("b-lock"))]),
        ]),
        BandControls::standard(),
    );
    list.calls.insert(Gesture::MiddleTriple, CallBinding::Do(run("call-prev").into()));
    list.calls.insert(Gesture::MiddleHold, CallBinding::Do(run("call-lock").into()));
    list.calls.insert(Gesture::IndexTriple, CallBinding::Nothing);
    assert_eq!(
        paused(&list),
        [
            (Builtin::Controls, Gesture::MiddleHold, Place::Profile(0), "a-lock".to_owned()),
            (Builtin::Controls, Gesture::MiddleHold, Place::Profile(1), "b-lock".to_owned()),
            (Builtin::Controls, Gesture::MiddleHold, Place::Calls, "call-lock".to_owned()),
            (Builtin::NextProfile, Gesture::IndexTriple, Place::Profile(0), "a-next".to_owned()),
            (Builtin::NextProfile, Gesture::IndexTriple, Place::Profile(1), "b-next".to_owned()),
            (Builtin::PreviousProfile, Gesture::MiddleTriple, Place::Profile(0), "a-prev".to_owned()),
            (Builtin::PreviousProfile, Gesture::MiddleTriple, Place::Calls, "call-prev".to_owned()),
        ]
    );
}

#[test]
fn paused_lists_a_shared_gesture_once_under_the_band_control_that_wins() {
    let mut list = with_band(
        profiles(vec![profile("a", &[(Gesture::SwipeUp, run("up"))])]),
        band(Some(Gesture::SwipeUp), Some(Gesture::SwipeUp), None),
    );
    assert_eq!(paused(&list), [(Builtin::Controls, Gesture::SwipeUp, Place::Profile(0), "up".to_owned())]);
    list.band = band(None, Some(Gesture::SwipeUp), Some(Gesture::SwipeUp));
    assert_eq!(paused(&list), [(Builtin::NextProfile, Gesture::SwipeUp, Place::Profile(0), "up".to_owned())]);
}

#[test]
fn the_two_warnings() {
    let mut list = profiles(vec![profile("a", &[])]);
    assert_eq!(list.warnings(), [Warning::NoControls]);
    list.list.push(profile("b", &[]));
    assert_eq!(list.warnings(), [Warning::NoControls, Warning::NoWayOut]);
    list.band = band(Some(Gesture::MiddleHold), None, Some(Gesture::MiddleTriple));
    assert!(list.warnings().is_empty(), "previous alone is a way out");
    list.band = band(Some(Gesture::MiddleHold), Some(Gesture::IndexTriple), None);
    assert!(list.warnings().is_empty(), "next alone is a way out");
}

#[test]
fn a_next_or_previous_under_controls_on_off_is_no_way_out() {
    let mut list = with_band(
        profiles(vec![profile("a", &[]), profile("b", &[])]),
        band(Some(Gesture::MiddleHold), Some(Gesture::MiddleHold), None),
    );
    assert_eq!(list.warnings(), [Warning::NoWayOut]);
    list.band.previous = Some(BandControl::on(Gesture::MiddleHold));
    assert_eq!(list.warnings(), [Warning::NoWayOut]);
    // Next and previous on one gesture of their own: next wins there, a way out.
    list.band = band(Some(Gesture::MiddleHold), Some(Gesture::SwipeUp), Some(Gesture::SwipeUp));
    assert!(list.warnings().is_empty());
}

#[test]
fn two_band_controls_on_one_gesture_resolve_in_a_fixed_order() {
    let all_three = band(Some(Gesture::SwipeUp), Some(Gesture::SwipeUp), Some(Gesture::SwipeUp));
    assert_eq!(all_three.on(Gesture::SwipeUp, Palm::Down), Some(Builtin::Controls));
    let next_and_previous = band(None, Some(Gesture::SwipeUp), Some(Gesture::SwipeUp));
    assert_eq!(next_and_previous.on(Gesture::SwipeUp, Palm::Down), Some(Builtin::NextProfile));
}

#[test]
fn the_standard_band_controls_and_none_by_default() {
    let standard = BandControls::standard();
    assert_eq!(standard.control(Builtin::Controls).map(|c| c.gesture), Some(Gesture::MiddleHold));
    assert_eq!(standard.control(Builtin::NextProfile).map(|c| c.gesture), Some(Gesture::IndexTriple));
    assert_eq!(standard.control(Builtin::PreviousProfile).map(|c| c.gesture), Some(Gesture::MiddleTriple));
    assert_eq!(standard.control(Builtin::Draw).map(|c| c.gesture), Some(Gesture::IndexHold));
    assert_eq!(standard.on(Gesture::IndexTriple, Palm::Down), Some(Builtin::NextProfile));
    assert_eq!(BandControls::default().on(Gesture::MiddleHold, Palm::Down), None);
}

#[test]
fn paused_and_uses_go_per_palm_position() {
    let mut list = profiles(vec![profile("a", &[])]);
    list.list[0].gestures.insert(Gesture::IndexTriple, up_override("normal", "up"));
    list.band.next = Some(BandControl { gesture: Gesture::IndexTriple, palm: PalmSet::Only([Palm::Up].into()) });
    let uses = list.uses(Gesture::IndexTriple);
    assert_eq!(uses.iter().map(|u| u.palm).collect::<Vec<_>>(), [None, Some(Palm::Up)]);
    let paused = list.paused();
    assert_eq!(paused.len(), 1, "only the palm-up override is under Next");
    assert_eq!(paused[0].used.action, "up");
    assert_eq!(paused[0].positions, Palms::from_iter([Palm::Up]));
}

#[test]
fn more_than_two_overrides_is_reported() {
    let mut list = profiles(vec![profile("a", &[])]);
    list.list[0].gestures.insert(
        Gesture::IndexTap,
        up_override("x", "x").with(Palm::Down, Some(run("x"))).with(Palm::Side, Some(run("x"))),
    );
    assert_eq!(list.invalid(), [Invalid::Binding { place: Place::Profile(0), gesture: Gesture::IndexTap }]);
}
