mod controls_common;

use band_core::controls::pinch::{GYRO_SCALE, Prototypes, from_forearm};
use band_core::controls::{
    BandControl, BandControls, Binding, CallBinding, Controls, Drag, DragMode, Gesture, HandSetting, Options, Output,
    Palm, PalmCalibration, PalmSet, Profile,
};
use band_core::events::{Event, Hand};
use controls_common::*;

fn swipe_up_with_up_override() -> Controls<String> {
    let mut p = profile("a", &[]);
    p.gestures.insert(Gesture::SwipeUp, up_override("normal", "up"));
    ready(profiles(vec![p]), Hand::Right)
}

#[test]
fn an_override_runs_in_its_position_and_the_normal_action_elsewhere() {
    let mut c = swipe_up_with_up_override();
    facing(&mut c, PALM_UP, 0.2, 0.5);
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 1, 0.75)), ["up"]);
    facing(&mut c, PALM_SIDE, 1.0, 0.5);
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 2, 1.55)), ["normal"]);
    facing(&mut c, PALM_DOWN, 2.0, 0.5);
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 3, 2.55)), ["normal"]);
}

#[test]
fn without_recent_orientation_the_palm_counts_as_down() {
    let mut c = swipe_up_with_up_override();
    facing(&mut c, PALM_UP, 0.2, 0.2);
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 1, 1.2)), ["normal"], "0.8 s stale");
}

#[test]
fn a_band_control_limited_to_palm_up_leaves_the_gesture_alone_elsewhere() {
    let mut list = with_band(
        profiles(vec![profile("a", &[(Gesture::SwipeUp, run("launcher"))]), profile("b", &[])]),
        band(None, None, None),
    );
    list.band.next = Some(BandControl { gesture: Gesture::SwipeUp, palm: PalmSet::Only([Palm::Up].into()) });
    let mut c = ready(list, Hand::Right);
    facing(&mut c, PALM_DOWN, 0.2, 0.5);
    let down = gesture(&mut c, "thumb", "up", 1, 0.75);
    assert_eq!(runs(&down), ["launcher"]);
    assert!(switches(&down).is_empty());
    facing(&mut c, PALM_UP, 1.0, 0.5);
    let up = gesture(&mut c, "thumb", "up", 2, 1.55);
    assert_eq!(switches(&up), [(1, 1)]);
    assert!(runs(&up).is_empty());
}

#[test]
fn a_triple_uses_the_palm_of_its_first_tap() {
    let mut p = profile("a", &[]);
    p.gestures.insert(Gesture::IndexTriple, up_override("normal", "up"));
    let mut c = ready(profiles(vec![p]), Hand::Right);
    // No presses: each tap's palm is the palm at the moment. The first tap palm up; the hand
    // turns down before the second.
    facing(&mut c, PALM_UP, 0.2, 1.8);
    let mut out = gesture(&mut c, "index", "tap", 1, 2.0);
    facing(&mut c, PALM_DOWN, 2.05, 0.1);
    out.extend(gesture(&mut c, "index", "tap", 2, 2.2));
    out.extend(gesture(&mut c, "index", "doubletap", 3, 2.2));
    out.extend(gesture(&mut c, "index", "tap", 4, 2.4));
    out.extend(gesture(&mut c, "index", "doubletap", 5, 2.4));
    out.extend(c.poll(3.0));
    assert_eq!(runs(&out), ["up"]);
}

#[test]
fn the_left_hand_counts_as_palm_down_until_calibrated() {
    let mut c = swipe_up_with_up_override();
    c.on_event(&Event::Handedness(Hand::Left), 0.75);
    facing(&mut c, PALM_UP, 0.8, 0.5);
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 1, 1.35)), ["normal"]);
    let mut options = c.options().clone();
    options.palm = Some(LEFT_CALIBRATION);
    c.set_options(options);
    facing(&mut c, -PALM_UP, 1.5, 0.5);
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 2, 2.05)), ["up"]);
}

#[test]
fn a_drag_uses_the_palm_at_its_press() {
    let mut p = profile("a", &[]);
    p.gestures.insert(Gesture::MiddleDragRight, up_override("normal", "up"));
    let mut c = ready(profiles(vec![p]), Hand::Right);
    facing(&mut c, PALM_UP, 0.2, 0.8);
    press(&mut c, "middle", 100, 1.0);
    still(&mut c, 1.01, 0.24);
    let mut out = motion_at(&mut c, drag_dir(Drag::Right), 40.0, 1.26, 0.5, PALM_UP);
    out.extend(release(&mut c, "middle", 102, 1.8));
    assert_eq!(runs(&out), ["up"]);
}

#[test]
fn a_triple_keeps_its_first_taps_palm_when_each_tap_has_its_own_press() {
    let mut p = profile("a", &[]);
    p.gestures.insert(Gesture::IndexTriple, up_override("normal", "up"));
    let mut c = ready(profiles(vec![p]), Hand::Right);
    facing(&mut c, PALM_UP, 0.2, 1.8);
    // Each tap as the band sends it: press, release, tap.
    press(&mut c, "index", 50, 1.9);
    release(&mut c, "index", 60, 2.0);
    let mut out = gesture(&mut c, "index", "tap", 1, 2.0);
    // The later taps are pressed palm down.
    facing(&mut c, PALM_DOWN, 2.05, 0.4);
    press(&mut c, "index", 51, 2.15);
    release(&mut c, "index", 61, 2.2);
    out.extend(gesture(&mut c, "index", "tap", 2, 2.2));
    out.extend(gesture(&mut c, "index", "doubletap", 3, 2.2));
    press(&mut c, "index", 52, 2.35);
    release(&mut c, "index", 62, 2.4);
    out.extend(gesture(&mut c, "index", "tap", 4, 2.4));
    out.extend(gesture(&mut c, "index", "doubletap", 5, 2.4));
    out.extend(c.poll(3.0));
    assert_eq!(runs(&out), ["up"]);
}

#[test]
fn a_band_control_on_a_drag_in_one_position_pauses_its_slider_only_there() {
    let mut p = profile("a", &[]);
    p.middle.drags = DragMode::Sliders([dial("seek-fwd", "seek-back"), None, None]);
    let mut list = with_band(profiles(vec![p]), BandControls::default());
    list.band.controls = Some(BandControl { gesture: Gesture::MiddleDragLeft, palm: PalmSet::Only([Palm::Up].into()) });
    let mut c = ready(list, Hand::Right);
    // A slide right pressed with the band rolled this way; its press and release messages are
    // `sequence` and the next.
    let drag = |c: &mut Controls<String>, roll: f64, at: f64, sequence: u64| {
        facing(c, roll, at - 0.5, 0.5);
        let mut out = press(c, "middle", sequence, at);
        out.extend(still(c, at + 0.01, 0.24));
        out.extend(motion_at(c, drag_dir(Drag::Right), 40.0, at + 0.26, 0.5, roll));
        out.extend(release(c, "middle", sequence + 1, at + 0.8));
        out
    };
    let down = runs(&drag(&mut c, PALM_DOWN, 1.0, 100));
    assert_only(&down, "seek-fwd");
    let up = drag(&mut c, PALM_UP, 3.0, 200);
    assert!(runs(&up).is_empty() && toggles(&up).is_empty(), "{up:?}");
}

#[test]
fn a_long_hold_keeps_its_press_palm_for_the_whole_pinch() {
    let mut p = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    p.gestures.insert(Gesture::IndexHold, up_override("normal", "up"));
    let mut c = ready(profiles(vec![p]), Hand::Right);
    // Pressed palm up; no orientation after the press.
    facing(&mut c, PALM_UP, 0.8, 0.2);
    let mut out = press(&mut c, "index", 100, 1.0);
    out.extend(gesture(&mut c, "index", "hold", 101, 1.3));
    out.extend(release(&mut c, "index", 102, 3.4));
    assert_eq!(runs(&out), ["up"]);
}

#[test]
fn a_slider_is_decided_by_its_press_palm_for_the_whole_pinch() {
    let mut p = profile("a", &[]);
    p.middle.drags = DragMode::Sliders([dial("seek-fwd", "seek-back"), None, None]);
    let mut list = with_band(profiles(vec![p]), BandControls::default());
    list.band.controls = Some(BandControl { gesture: Gesture::MiddleDragLeft, palm: PalmSet::Only([Palm::Up].into()) });
    let mut c = ready(list, Hand::Right);
    // Pressed palm down, then a steady slide right for 2.5 s; the orientation turns palm up
    // halfway (the band's frame stays the press's, as the pinch measures it).
    facing(&mut c, PALM_DOWN, 0.8, 0.2);
    press(&mut c, "middle", 100, 1.0);
    still(&mut c, 1.01, 0.24);
    let rate = from_forearm(drag_dir(Drag::Right).map(|v| v * 40.0 / GYRO_SCALE), PALM_DOWN);
    let (mut early, mut late) = (Vec::new(), Vec::new());
    for i in 0..=250 {
        let t = 1.26 + i as f64 * 0.01;
        if i % 2 == 0 {
            facing(&mut c, if t < 2.5 { PALM_DOWN } else { PALM_UP }, t, 0.0);
        }
        let raw = if i == 0 { [0.0; 3] } else { rate };
        let out = c.on_event(&Event::Motion { timestamp_us: (t * 1e6).round() as u64, gyro: raw }, t);
        // Past the press's first 2 s.
        if t < 3.1 { early.extend(out) } else { late.extend(out) }
    }
    let late_too = release(&mut c, "middle", 102, 3.8);
    assert_only(&runs(&early), "seek-fwd");
    assert_only(&runs(&late), "seek-fwd");
    assert!(runs(&late).len() >= 3, "{late:?}");
    assert!(toggles(&late).is_empty() && toggles(&late_too).is_empty());
}

#[test]
fn before_the_bands_hand_is_known_a_configured_left_hand_is_palm_down() {
    let mut p = profile("a", &[]);
    p.gestures.insert(Gesture::SwipeUp, up_override("normal", "up"));
    let options = Options { hand: HandSetting::Left, ..Default::default() };
    let mut c = live_with(options, profiles(vec![p]));
    facing(&mut c, PALM_UP, 0.2, 0.5);
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 1, 0.75)), ["normal"]);
}

#[test]
fn a_holds_palm_is_its_presss() {
    let mut p = profile("a", &[]);
    p.gestures.insert(Gesture::IndexHold, up_override("normal", "up"));
    let mut c = ready(profiles(vec![p]), Hand::Right);
    facing(&mut c, PALM_UP, 0.8, 0.2);
    let mut out = press(&mut c, "index", 100, 1.0);
    // Turned palm down before the band's hold message.
    facing(&mut c, PALM_DOWN, 1.05, 0.2);
    out.extend(gesture(&mut c, "index", "hold", 101, 1.3));
    out.extend(release(&mut c, "index", 102, 1.6));
    assert_eq!(runs(&out), ["up"]);
}

#[test]
fn a_held_double_tap_keeps_its_palm() {
    let mut p = profile("a", &[(Gesture::IndexTriple, run("triple"))]);
    p.gestures.insert(Gesture::IndexDouble, up_override("normal", "up"));
    let mut c = ready(profiles(vec![p]), Hand::Right);
    facing(&mut c, PALM_UP, 0.2, 1.8);
    press(&mut c, "index", 50, 1.9);
    release(&mut c, "index", 60, 2.0);
    let mut out = gesture(&mut c, "index", "tap", 1, 2.0);
    press(&mut c, "index", 51, 2.15);
    release(&mut c, "index", 61, 2.2);
    out.extend(gesture(&mut c, "index", "tap", 2, 2.2));
    out.extend(gesture(&mut c, "index", "doubletap", 3, 2.2));
    assert!(runs(&out).is_empty(), "held for a possible triple: {out:?}");
    // The palm turns down before it fires.
    facing(&mut c, PALM_DOWN, 2.25, 0.3);
    assert!(c.next_deadline().is_some_and(|at| at > 2.55));
    out.extend(c.poll(3.0));
    assert_eq!(runs(&out), ["up"]);
}

#[test]
fn a_call_layer_override_of_nothing_runs_nothing_in_that_position() {
    let mut list = profiles(vec![profile("a", &[(Gesture::SwipeUp, run("launcher"))])]);
    list.calls.insert(Gesture::SwipeUp, CallBinding::Do(Binding::from(run("call.normal")).with(Palm::Up, None)));
    let mut c = ready(list, Hand::Right);
    c.set_in_call(true);
    facing(&mut c, PALM_UP, 0.2, 0.5);
    let up = gesture(&mut c, "thumb", "up", 1, 0.75);
    assert!(runs(&up).is_empty(), "{up:?}");
    facing(&mut c, PALM_DOWN, 1.0, 0.5);
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 2, 1.55)), ["call.normal"]);
    facing(&mut c, PALM_SIDE, 2.0, 0.5);
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 3, 2.55)), ["call.normal"]);
}

/// Right hand configured, then the left requested at runtime and confirmed by the band at 0.8 s.
fn requested_left(p: Profile<String>) -> Controls<String> {
    let options = Options { hand: HandSetting::Right, ..Default::default() };
    let mut c = ready_with(options, profiles(vec![p]), Hand::Right);
    assert_eq!(c.request_hand(Hand::Left), [Output::SetHand(Hand::Left)]);
    assert!(c.on_event(&Event::Handedness(Hand::Left), 0.8).is_empty());
    c
}

/// The right hand's, mirrored (the roll about the forearm turns the other way).
const LEFT_CALIBRATION: PalmCalibration = PalmCalibration { down_roll: -PALM_DOWN, up_roll: -PALM_UP };

#[test]
fn a_new_calibration_keeps_the_requested_hand() {
    let mut p = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    p.gestures.insert(Gesture::SwipeUp, up_override("normal", "up"));
    let mut c = requested_left(p);
    c.set_calibration(Some(LEFT_CALIBRATION), None);
    assert_eq!(c.options().hand, HandSetting::Right);
    assert_eq!(c.options().palm, Some(LEFT_CALIBRATION));
    // Still the left hand: nothing to write back, and the untaught dial turns the other way.
    assert!(c.on_event(&Event::Handedness(Hand::Left), 0.9).is_empty());
    assert_only(&runs(&pinch(&mut c, "index", [0.0, 1.0, 0.0], 40.0, 1.0, true)), "vol-down");
    // The new calibration's palm up.
    facing(&mut c, -PALM_UP, 2.0, 0.5);
    assert_eq!(c.palm(2.5), Palm::Up);
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 1, 2.55)), ["up"]);
}

#[test]
fn a_new_calibration_sets_the_prototypes_and_their_palm_down_roll() {
    let mut c = requested_left(profile("a", &[]));
    assert_eq!(c.prototypes(), &Prototypes::turns_only());
    c.set_calibration(Some(LEFT_CALIBRATION), Some(Prototypes::right_hand()));
    assert_eq!(c.options().drags, Some(Prototypes::right_hand()));
    assert_eq!(c.prototypes().drags, Prototypes::right_hand().drags);
    assert_eq!(c.prototypes().palm_down_roll, LEFT_CALIBRATION.down_roll);
    c.set_calibration(None, None);
    assert_eq!(c.prototypes(), &Prototypes::turns_only());
}

#[test]
fn the_left_hand_without_a_calibration_is_palm_down_again() {
    let mut c = requested_left(profile("a", &[]));
    c.set_calibration(Some(LEFT_CALIBRATION), None);
    facing(&mut c, -PALM_UP, 1.0, 0.5);
    assert_eq!(c.palm(1.5), Palm::Up);
    c.set_calibration(None, None);
    assert_eq!(c.palm(1.5), Palm::Down);
    facing(&mut c, -PALM_UP, 1.6, 0.2);
    assert_eq!(c.palm(1.8), Palm::Down);
}

#[test]
fn a_new_calibration_applies_to_the_last_orientation_at_once() {
    let mut c = requested_left(profile("a", &[]));
    facing(&mut c, -PALM_UP, 1.0, 0.5);
    assert_eq!(c.palm(1.5), Palm::Down, "no calibration yet");
    c.set_calibration(Some(LEFT_CALIBRATION), None);
    assert_eq!(c.palm(1.5), Palm::Up);
}

#[test]
fn a_new_calibration_loses_the_pinch_in_progress() {
    let mut p = profile("a", &[(Gesture::IndexTap, run("tap"))]);
    p.index.dial = dial("vol-up", "vol-down");
    let mut c = requested_left(p);
    press(&mut c, "index", 100, 1.0);
    still(&mut c, 1.01, 0.24);
    // Read in the old frame against the old prototypes: nothing more comes of it.
    c.set_calibration(Some(LEFT_CALIBRATION), None);
    let mut out = motion(&mut c, [0.0, 1.0, 0.0], 40.0, 1.31, 0.5);
    out.extend(release(&mut c, "index", 102, 1.85));
    assert!(runs(&out).is_empty(), "{out:?}");
    // Its release is not an index tap.
    assert!(runs(&gesture(&mut c, "index", "tap", 103, 1.9)).is_empty());
}

#[test]
fn a_new_calibration_keeps_the_hold_of_a_finger_whose_moves_do_nothing() {
    let p = profile("a", &[(Gesture::MiddleHold, run("lock"))]);
    let mut c = requested_left(p);
    press(&mut c, "middle", 100, 1.0);
    still(&mut c, 1.01, 0.14);
    c.set_calibration(Some(LEFT_CALIBRATION), Some(Prototypes::right_hand()));
    assert_eq!(runs(&release(&mut c, "middle", 101, 1.5)), ["lock"]);
}

#[test]
fn the_same_calibration_again_leaves_the_pinch_alone() {
    let mut p = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    let mut c = requested_left(p);
    c.set_calibration(Some(LEFT_CALIBRATION), None);
    press(&mut c, "index", 100, 1.0);
    still(&mut c, 1.01, 0.24);
    c.set_calibration(Some(LEFT_CALIBRATION), None);
    let mut out = motion(&mut c, [0.0, 1.0, 0.0], 40.0, 1.31, 0.5);
    out.extend(release(&mut c, "index", 102, 1.85));
    assert_only(&runs(&out), "vol-down");
}

#[test]
fn the_palm_now_is_down_without_a_fresh_orientation() {
    let mut c = swipe_up_with_up_override();
    assert_eq!(c.palm(0.75), Palm::Down, "no orientation yet");
    facing(&mut c, PALM_UP, 0.8, 0.5);
    assert_eq!(c.palm(1.3), Palm::Up);
    assert_eq!(c.palm(1.75), Palm::Up);
    assert_eq!(c.palm(1.85), Palm::Down, "over 0.5 s stale");
    facing(&mut c, PALM_SIDE, 2.0, 0.2);
    assert_eq!(c.palm(2.2), Palm::Side);
}

#[test]
fn a_hand_change_mid_pinch_loses_it() {
    let mut p = profile("a", &[(Gesture::IndexDragRight, run("x")), (Gesture::IndexTap, run("tap"))]);
    p.index.dial = dial("vol-up", "vol-down");
    for direction in [turn_dir(), drag_dir(Drag::Right)] {
        let mut c = ready(profiles(vec![p.clone()]), Hand::Right);
        press(&mut c, "index", 100, 1.0);
        still(&mut c, 1.01, 0.24);
        // The band now says left: the pinch was read against the right hand's directions.
        assert!(c.on_event(&Event::Handedness(Hand::Left), 1.26).is_empty());
        let mut out = motion(&mut c, direction, 40.0, 1.31, 0.5);
        out.extend(release(&mut c, "index", 102, 1.85));
        assert!(runs(&out).is_empty(), "{out:?}");
        // Its release is not an index tap.
        assert!(runs(&gesture(&mut c, "index", "tap", 103, 1.9)).is_empty());
    }
}

#[test]
fn the_same_hand_again_mid_pinch_leaves_it_alone() {
    let mut p = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    let mut c = ready(profiles(vec![p]), Hand::Right);
    press(&mut c, "index", 100, 1.0);
    still(&mut c, 1.01, 0.24);
    assert!(c.on_event(&Event::Handedness(Hand::Right), 1.26).is_empty());
    let mut out = motion(&mut c, turn_dir(), 40.0, 1.31, 0.5);
    out.extend(release(&mut c, "index", 102, 1.85));
    assert_only(&runs(&out), "vol-up");
}

#[test]
fn a_hand_change_mid_pinch_keeps_a_still_fingers_hold() {
    let p = profile("a", &[(Gesture::MiddleHold, run("lock"))]);
    let mut c = ready(profiles(vec![p]), Hand::Right);
    press(&mut c, "middle", 100, 1.0);
    still(&mut c, 1.01, 0.14);
    assert!(c.on_event(&Event::Handedness(Hand::Left), 1.2).is_empty());
    assert_eq!(runs(&release(&mut c, "middle", 101, 1.5)), ["lock"]);
}

#[test]
fn a_config_reload_with_a_new_calibration_mid_pinch_loses_it() {
    let mut p = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    let mut c = ready(profiles(vec![p]), Hand::Right);
    press(&mut c, "index", 100, 1.0);
    still(&mut c, 1.01, 0.24);
    let options = Options { palm: Some(LEFT_CALIBRATION), ..c.options().clone() };
    assert!(c.set_options(options).is_empty());
    let mut out = motion(&mut c, turn_dir(), 40.0, 1.31, 0.5);
    out.extend(release(&mut c, "index", 102, 1.85));
    assert!(runs(&out).is_empty(), "{out:?}");
}

#[test]
fn a_hand_change_that_changes_nothing_in_effect_keeps_the_pinch() {
    let mut p = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    // Taught drags and a calibration: the same whichever hand the band reports.
    let options =
        Options { drags: Some(Prototypes::right_hand()), palm: Some(PalmCalibration::right_hand()), ..Default::default() };
    let mut c = ready_with(options, profiles(vec![p]), Hand::Right);
    press(&mut c, "index", 100, 1.0);
    still(&mut c, 1.01, 0.24);
    assert!(c.on_event(&Event::Handedness(Hand::Left), 1.26).is_empty());
    let mut out = motion(&mut c, turn_dir(), 40.0, 1.31, 0.5);
    out.extend(release(&mut c, "index", 102, 1.85));
    assert_only(&runs(&out), "vol-up");
}

#[test]
fn the_bands_hand_rereads_the_palm_at_once() {
    let mut c = ready(profiles(vec![profile("a", &[])]), Hand::Left);
    facing(&mut c, PALM_UP, 1.0, 0.5);
    assert_eq!(c.palm(1.5), Palm::Down, "the uncalibrated left hand");
    c.on_event(&Event::Handedness(Hand::Right), 1.5);
    assert_eq!(c.palm(1.5), Palm::Up);
}

#[test]
fn a_new_calibration_keeps_the_retry_of_an_unconfirmed_hand_request() {
    let mut c = ready(profiles(vec![profile("a", &[])]), Hand::Right);
    assert_eq!(c.request_hand(Hand::Left), [Output::SetHand(Hand::Left)]);
    c.set_calibration(Some(LEFT_CALIBRATION), None);
    // The write was lost: the band still says right. One retry, then no more.
    assert_eq!(c.on_event(&Event::Handedness(Hand::Right), 1.0), [Output::SetHand(Hand::Left)]);
    assert!(c.on_event(&Event::Handedness(Hand::Right), 1.5).is_empty());
}
