//! One pinch, one meaning: hold, dial, drag gesture or slider.

mod controls_common;

use band_core::controls::{
    BandControl, BandControls, Binding, Controls, Drag, DragMode, Finger, Gesture, Options, Output, Palm, PalmSet, Profile, Profiles,
};
use band_core::controls::pinch::{GYRO_SCALE, Prototypes, from_forearm};
use band_core::events::{Event, Hand};
use controls_common::*;

fn setup(index_dial: bool, gestures: &[(Gesture, String)]) -> Controls<String> {
    let mut p: Profile<String> = profile("a", gestures);
    if index_dial {
        p.index.dial = dial("vol-up", "vol-down");
    }
    ready(profiles(vec![p]), Hand::Right)
}

#[test]
fn a_still_pinch_is_the_hold_when_you_let_go_if_the_finger_has_a_dial() {
    let mut c = setup(true, &[(Gesture::IndexHold, run("assistant"))]);
    let out = pinch(&mut c, "index", turn_dir(), 0.0, 1.0, true);
    assert_eq!(runs(&out), ["assistant"]);
    // It ran at the release, not at the band's hold message.
    let mut c = setup(true, &[(Gesture::IndexHold, run("assistant"))]);
    press(&mut c, "index", 1, 1.0);
    still(&mut c, 1.01, 0.3);
    let at_hold = c.on_event(&Event::Gesture(message("index", "hold", 2, 1.3)), 1.3);
    assert!(runs(&at_hold).is_empty());
    still(&mut c, 1.31, 0.3);
    assert_eq!(runs(&release(&mut c, "index", 3, 1.62)), ["assistant"]);
}

#[test]
fn without_a_dial_or_drags_the_hold_acts_at_the_bands_hold_message() {
    let mut c = setup(false, &[(Gesture::MiddleHold, run("lock"))]);
    press(&mut c, "middle", 1, 1.0);
    still(&mut c, 1.01, 0.28);
    assert_eq!(runs(&c.on_event(&Event::Gesture(message("middle", "hold", 2, 1.3)), 1.3)), ["lock"]);
    still(&mut c, 1.31, 0.3);
    assert!(runs(&release(&mut c, "middle", 3, 1.62)).is_empty(), "once");
}

#[test]
fn a_turn_is_the_dial_and_never_the_hold() {
    let mut c = setup(true, &[(Gesture::IndexHold, run("assistant"))]);
    let out = pinch(&mut c, "index", turn_dir(), 40.0, 1.0, true);
    let ran = runs(&out);
    assert_only(&ran, "vol-up");
    let mut c = setup(true, &[]);
    let down = runs(&pinch(&mut c, "index", turn_dir().map(|v| -v), 40.0, 1.0, true));
    assert_only(&down, "vol-down");
}

#[test]
fn a_drag_never_moves_the_dial_and_fires_its_gesture_once() {
    let mut c = setup(true, &[(Gesture::IndexDragRight, run("next-track"))]);
    let out = pinch(&mut c, "index", drag_dir(Drag::Right), 40.0, 1.0, true);
    assert_eq!(runs(&out), ["next-track"]);
    assert_eq!(gestures(&out), [Gesture::IndexDragRight]);
}

#[test]
fn each_drag_direction_is_its_own_gesture() {
    for drag in Drag::ALL {
        let g = Gesture::drag(Finger::Middle, drag);
        let mut c = setup(false, &[(g, run("x"))]);
        let out = pinch(&mut c, "middle", drag_dir(drag), 40.0, 1.0, true);
        assert_eq!(gestures(&out), [g], "{drag:?}");
        assert_eq!(runs(&out), ["x"], "{drag:?}");
    }
}

#[test]
fn sliders_follow_the_pair_both_ways() {
    let mut p: Profile<String> = profile("a", &[]);
    p.middle.drags = DragMode::Sliders([dial("seek-fwd", "seek-back"), None, None]);
    let mut c = ready(profiles(vec![p]), Hand::Right);
    let right = runs(&pinch(&mut c, "middle", drag_dir(Drag::Right), 40.0, 1.0, true));
    assert_only(&right, "seek-fwd");
    let left = runs(&pinch(&mut c, "middle", drag_dir(Drag::Left), 40.0, 3.0, true));
    assert_only(&left, "seek-back");
    // The up/down slider is None: an up drag does nothing, and isn't a hold either.
    let up = pinch(&mut c, "middle", drag_dir(Drag::Up), 40.0, 5.0, true);
    assert!(runs(&up).is_empty());
}

#[test]
fn a_band_control_on_a_drag_gesture_wins_over_a_slider() {
    let mut p: Profile<String> = profile("a", &[]);
    p.middle.drags = DragMode::Sliders([dial("seek-fwd", "seek-back"), None, None]);
    let mut c = ready(with_band(profiles(vec![p]), band(Some(Gesture::MiddleDragRight), None, None)), Hand::Right);
    let out = pinch(&mut c, "middle", drag_dir(Drag::Right), 40.0, 1.0, true);
    assert_eq!(toggles(&out), [false]);
    assert!(runs(&out).is_empty());
}

#[test]
fn the_default_lock_stays_fast() {
    let mut c = ready(with_band(profiles(vec![profile("a", &[])]), BandControls::standard()), Hand::Right);
    press(&mut c, "middle", 1, 1.0);
    still(&mut c, 1.01, 0.28);
    assert_eq!(toggles(&c.on_event(&Event::Gesture(message("middle", "hold", 2, 1.3)), 1.3)), [false]);
}

#[test]
fn a_hold_message_without_a_press_still_acts() {
    // Older firmware or a lost press: the hold acts at its message, as before.
    let mut c = setup(true, &[(Gesture::MiddleHold, run("lock"))]);
    assert_eq!(runs(&gesture(&mut c, "middle", "hold", 1, 1.0)), ["lock"]);
}

#[test]
fn a_tap_never_starts_a_drag() {
    let mut c = setup(false, &[(Gesture::IndexDragRight, run("x")), (Gesture::IndexTap, run("tap"))]);
    press(&mut c, "index", 1, 1.0);
    let moved = motion(&mut c, drag_dir(Drag::Right), 30.0, 1.01, 0.12);
    release(&mut c, "index", 2, 1.14);
    assert!(runs(&moved).is_empty());
    assert_eq!(runs(&gesture(&mut c, "index", "tap", 3, 1.15)), ["tap"]);
}

#[test]
fn practice_reports_the_drag_and_what_it_would_do() {
    let mut c = setup(false, &[(Gesture::IndexDragUp, run("home"))]);
    c.set_practice(true);
    let out = pinch(&mut c, "index", drag_dir(Drag::Up), 40.0, 1.0, true);
    assert!(gestures(&out).contains(&Gesture::IndexDragUp));
    assert!(out.contains(&Output::Practiced("home".into())));
    assert!(runs(&out).is_empty());
}

#[test]
fn the_left_hand_turns_its_dial_the_other_way_and_has_no_drags_until_taught() {
    let mut p: Profile<String> = profile("a", &[(Gesture::IndexDragRight, run("x"))]);
    p.index.dial = dial("vol-up", "vol-down");
    let mut c = ready_with(Options::default(), profiles(vec![p]), Hand::Left);
    let turned = runs(&pinch(&mut c, "index", [0.0, 1.0, 0.0], 40.0, 1.0, true));
    assert_only(&turned, "vol-down");
    assert!(runs(&pinch(&mut c, "index", drag_dir(Drag::Right), 40.0, 3.0, true)).is_empty());
}

#[test]
fn releasing_a_pinch_that_moved_is_not_an_index_tap() {
    let mut c = setup(true, &[(Gesture::IndexTap, run("tap"))]);
    pinch(&mut c, "index", turn_dir(), 40.0, 1.0, true);
    assert!(runs(&gesture(&mut c, "index", "tap", 9, 1.9)).is_empty());
}

#[test]
fn releasing_a_drag_gesture_pinch_is_not_an_index_tap_either() {
    let mut c = setup(false, &[(Gesture::IndexDragRight, run("x")), (Gesture::IndexTap, run("tap"))]);
    assert_eq!(runs(&pinch(&mut c, "index", drag_dir(Drag::Right), 40.0, 1.0, true)), ["x"]);
    assert!(runs(&gesture(&mut c, "index", "tap", 9, 1.9)).is_empty());
}

#[test]
fn a_pinch_whose_motion_stops_is_lost() {
    // No gyro sample for 0.4 s during the pinch: nothing comes of it, not even the hold.
    let mut c = setup(true, &[(Gesture::IndexHold, run("assistant"))]);
    press(&mut c, "index", 1, 1.0);
    still(&mut c, 1.01, 0.2);
    let after = motion(&mut c, turn_dir(), 40.0, 1.61, 0.5);
    assert!(runs(&after).is_empty(), "{after:?}");
    assert!(runs(&release(&mut c, "index", 2, 2.15)).is_empty());
}

#[test]
fn the_left_hands_unknown_move_uses_the_pinch_up() {
    let mut p: Profile<String> = profile("a", &[(Gesture::IndexHold, run("assistant"))]);
    p.index.dial = dial("vol-up", "vol-down");
    let mut c = ready(profiles(vec![p]), Hand::Left);
    // Not about the forearm: unknown for turns-only prototypes, so no dial and no hold.
    assert!(runs(&pinch(&mut c, "index", [1.0, 0.0, 0.0], 40.0, 1.0, true)).is_empty());
}

#[test]
fn an_index_holds_message_never_swallows_the_lock() {
    let mut p: Profile<String> = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    let mut c = ready(with_band(profiles(vec![p]), BandControls::standard()), Hand::Right);
    pinch(&mut c, "index", turn_dir(), 40.0, 1.0, true);
    // The middle hold 0.7 s after the index pinch's hold message is a hold of its own.
    assert_eq!(toggles(&gesture(&mut c, "middle", "hold", 7, 2.0)), [false]);
}

fn standard_lock() -> Controls<String> {
    ready(with_band(profiles(vec![profile("a", &[])]), BandControls::standard()), Hand::Right)
}

#[test]
fn the_lock_acts_even_when_the_gyro_went_quiet() {
    let mut c = standard_lock();
    // The last gyro sample came at 0.7 s: by the hold message the motion is ≥ 0.35 s old.
    press(&mut c, "middle", 1, 1.0);
    assert_eq!(toggles(&c.on_event(&Event::Gesture(message("middle", "hold", 2, 1.3)), 1.3)), [false]);
}

#[test]
fn a_quick_move_before_the_hold_message_never_swallows_the_lock() {
    let mut c = standard_lock();
    let mut out = press(&mut c, "middle", 1, 1.0);
    out.extend(motion(&mut c, drag_dir(Drag::Right), 30.0, 1.01, 0.28));
    out.extend(c.on_event(&Event::Gesture(message("middle", "hold", 2, 1.3)), 1.3));
    out.extend(still(&mut c, 1.31, 0.3));
    out.extend(release(&mut c, "middle", 3, 1.62));
    assert_eq!(toggles(&out), [false]);
    assert_eq!(gestures(&out), [Gesture::MiddleHold], "no drag gesture after the hold");
}

#[test]
fn a_band_control_on_one_drag_pauses_its_pairs_slider() {
    let make = || {
        let mut p: Profile<String> = profile("a", &[]);
        p.middle.drags = DragMode::Sliders([dial("seek-fwd", "seek-back"), None, None]);
        ready(with_band(profiles(vec![p]), band(Some(Gesture::MiddleDragRight), None, None)), Hand::Right)
    };
    let mut c = make();
    assert_eq!(toggles(&pinch(&mut c, "middle", drag_dir(Drag::Right), 40.0, 1.0, true)), [false]);
    let mut c = make();
    let left = pinch(&mut c, "middle", drag_dir(Drag::Left), 40.0, 1.0, true);
    assert!(runs(&left).is_empty(), "{left:?}");
    assert!(toggles(&left).is_empty(), "{left:?}");
}

#[test]
fn a_pinch_older_than_10_s_is_dropped() {
    let mut c = setup(true, &[(Gesture::IndexHold, run("assistant"))]);
    press(&mut c, "index", 1, 1.0);
    still(&mut c, 1.01, 0.24);
    let turned = runs(&motion(&mut c, turn_dir(), 40.0, 1.26, 0.5));
    assert!(!turned.is_empty(), "the turn works first");
    // No release; the band keeps streaming.
    still(&mut c, 1.77, 10.5);
    assert!(runs(&motion(&mut c, turn_dir(), 40.0, 12.28, 0.5)).is_empty(), "the old pinch is gone");
    // A new press starts a pinch of its own: held still, it's the hold.
    press(&mut c, "index", 2, 13.0);
    still(&mut c, 13.01, 0.4);
    assert_eq!(runs(&release(&mut c, "index", 3, 13.42)), ["assistant"]);
}

#[test]
fn drags_wait_for_a_confirmed_hand() {
    let mut p: Profile<String> = profile("a", &[(Gesture::IndexDragRight, run("x"))]);
    p.middle.drags = DragMode::Sliders([dial("seek-fwd", "seek-back"), None, None]);
    let mut c = live(profiles(vec![p]));
    still(&mut c, 0.2, 0.5);
    let out = pinch(&mut c, "index", drag_dir(Drag::Right), 40.0, 1.0, true);
    assert!(runs(&out).is_empty() && gestures(&out).is_empty(), "{out:?}");
    let out = pinch(&mut c, "middle", drag_dir(Drag::Right), 40.0, 3.0, true);
    assert!(runs(&out).is_empty(), "{out:?}");
}

#[test]
fn the_untaught_left_hand_keeps_the_hold_fast() {
    let mut p: Profile<String> = profile("a", &[(Gesture::MiddleDragRight, run("x")), (Gesture::MiddleHold, run("lock"))]);
    p.middle.drags = DragMode::Gestures;
    let mut c = ready(profiles(vec![p]), Hand::Left);
    press(&mut c, "middle", 1, 1.0);
    still(&mut c, 1.01, 0.28);
    assert_eq!(runs(&c.on_event(&Event::Gesture(message("middle", "hold", 2, 1.3)), 1.3)), ["lock"]);
}

#[test]
fn a_taught_turn_is_never_reversed_for_the_left_hand() {
    let mut p: Profile<String> = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    let taught = Options { drags: Some(Prototypes::right_hand()), ..Options::default() };
    let mut c = ready_with(taught, profiles(vec![p]), Hand::Left);
    let turned = runs(&pinch(&mut c, "index", turn_dir(), 40.0, 1.0, true));
    assert_only(&turned, "vol-up");
}

#[test]
fn a_still_fingers_hold_never_needs_the_gyro() {
    // No hold message (lost, or a firmware without one) and the gyro long quiet: the release
    // after ≥ 0.3 s is still the lock.
    let mut c = standard_lock();
    press(&mut c, "middle", 1, 1.0);
    c.poll(1.2);
    assert_eq!(toggles(&release(&mut c, "middle", 2, 1.5)), [false]);
}

#[test]
fn a_gyro_that_went_quiet_before_the_press_never_loses_the_pinch() {
    // The last gyro sample is from before the press: the pinch's motion never stopped.
    for poll_between in [false, true] {
        let mut c = setup(true, &[(Gesture::IndexHold, run("assistant"))]);
        press(&mut c, "index", 1, 1.0);
        if poll_between {
            c.poll(1.2);
        }
        assert_eq!(runs(&release(&mut c, "index", 2, 1.5)), ["assistant"], "poll between: {poll_between}");
    }
}

#[test]
fn a_gap_in_the_bands_clock_after_the_press_loses_the_pinch() {
    // Samples keep arriving, but the band's clock jumps 0.4 s: its motion in between is unknown.
    let mut c = setup(true, &[(Gesture::IndexHold, run("assistant"))]);
    press(&mut c, "index", 1, 1.0);
    still(&mut c, 1.01, 0.2);
    let band = from_forearm(turn_dir().map(|v| v * 80.0 / GYRO_SCALE), Prototypes::right_hand().palm_down_roll);
    let mut out = Vec::new();
    for i in 0..50 {
        let t = 1.22 + f64::from(i) * 0.01;
        let stamp = ((t + 0.4) * 1e6).round() as u64;
        out.extend(c.on_event(&Event::Motion { timestamp_us: stamp, gyro: band }, t));
    }
    out.extend(release(&mut c, "index", 2, 1.75));
    assert!(runs(&out).is_empty(), "{out:?}");
}

#[test]
fn a_gap_in_the_bands_clock_spares_a_still_fingers_hold() {
    let mut c = ready(with_band(profiles(vec![profile("a", &[])]), BandControls::standard()), Hand::Right);
    press(&mut c, "middle", 1, 1.0);
    still(&mut c, 1.01, 0.2);
    for i in 0..30 {
        let t = 1.22 + f64::from(i) * 0.01;
        c.on_event(&Event::Motion { timestamp_us: ((t + 0.4) * 1e6).round() as u64, gyro: [0.0; 3] }, t);
    }
    assert_eq!(toggles(&release(&mut c, "middle", 2, 1.55)), [false]);
}

#[test]
fn teaching_drags_reports_each_pinchs_direction_and_nothing_acts() {
    let mut p = profile("a", &[(Gesture::IndexDragRight, run("x")), (Gesture::IndexHold, run("hold"))]);
    p.index.dial = dial("vol-up", "vol-down");
    let mut c = ready(with_band(profiles(vec![p]), BandControls::standard()), Hand::Right);
    c.set_drag_teaching(true);
    let out = pinch(&mut c, "index", drag_dir(Drag::Right), 40.0, 1.0, true);
    let samples: Vec<_> = out.iter().filter_map(|o| match o {
        Output::DragSample { finger, direction } => Some((*finger, *direction)),
        _ => None,
    }).collect();
    assert_eq!(samples.len(), 1);
    assert_eq!(samples[0].0, Finger::Index);
    let d = samples[0].1;
    let r = drag_dir(Drag::Right);
    let cos = (d[0] * r[0] + d[1] * r[1] + d[2] * r[2]) / (d[0].hypot(d[1]).hypot(d[2]));
    assert!(cos > 0.99, "{d:?}");
    assert!(runs(&out).is_empty());
    // A turn is a sample too; a still pinch is no sample and no hold; the lock doesn't act.
    assert!(pinch(&mut c, "index", turn_dir(), 40.0, 3.0, true).iter().any(|o| matches!(o, Output::DragSample { .. })));
    let still_out = pinch(&mut c, "index", turn_dir(), 0.0, 5.0, true);
    assert!(runs(&still_out).is_empty() && !still_out.iter().any(|o| matches!(o, Output::DragSample { .. })));
    assert_eq!(gestures(&still_out), [Gesture::IndexHold], "the hold is still reported");
    assert!(toggles(&pinch(&mut c, "middle", turn_dir(), 0.0, 7.0, true)).is_empty());
    c.set_drag_teaching(false);
    assert_eq!(runs(&pinch(&mut c, "index", drag_dir(Drag::Right), 40.0, 9.0, true)), ["x"]);
}

#[test]
fn taught_drags_replace_the_measured_ones() {
    let p = Prototypes::right_hand();
    // Teach "right" as what was measured as "up", and "up" as "right".
    let mut drags = p.drags.unwrap();
    drags.swap(Drag::Right.index(), Drag::Up.index());
    let options = Options { drags: Some(Prototypes::taught(p.turn, drags, p.palm_down_roll).unwrap()), ..Options::default() };
    let mut profile_a = profile("a", &[(Gesture::IndexDragRight, run("right"))]);
    profile_a.index.dial = None;
    let mut c = ready_with(options, profiles(vec![profile_a]), Hand::Right);
    assert_eq!(runs(&pinch(&mut c, "index", drag_dir(Drag::Up), 40.0, 1.0, true)), ["right"]);
}

#[test]
fn teaching_drags_samples_a_finger_whose_moves_do_nothing_and_no_session_starts() {
    // The middle finger's moves do nothing here (its hold would be the fast one).
    let mut list = with_band(profiles(vec![profile("a", &[(Gesture::MiddleHold, run("hold"))])]), BandControls::standard());
    list.band.draw = Some(BandControl::on(Gesture::IndexDouble));
    let mut c = ready(list, Hand::Right);
    c.set_drag_teaching(true);
    assert!(c.drag_teaching());
    let out = pinch(&mut c, "middle", drag_dir(Drag::Up), 40.0, 1.0, true);
    assert!(out.iter().any(|o| matches!(o, Output::DragSample { finger: Finger::Middle, .. })), "{out:?}");
    assert!(runs(&out).is_empty());
    // Neither the Draw band control nor the app opens a draw session.
    let mut out = gesture(&mut c, "index", "tap", 50, 3.0);
    out.extend(gesture(&mut c, "index", "doubletap", 51, 3.25));
    out.extend(c.start_drawing(3.3));
    assert!(!out.contains(&Output::DrawStarted) && !c.drawing(), "{out:?}");
}

#[test]
fn teaching_drags_cancels_an_open_draw_session() {
    let mut c = setup(false, &[]);
    c.start_drawing(1.0);
    assert_eq!(c.set_drag_teaching(true), [Output::DrawCancelled]);
    assert!(!c.drawing());
    assert_eq!(c.set_drag_teaching(false), []);
}

#[test]
fn teaching_drags_drops_a_held_tap_either_way() {
    for teaching_first in [true, false] {
        let mut c = setup(false, &[(Gesture::IndexTap, run("tap")), (Gesture::IndexDouble, run("double"))]);
        c.set_drag_teaching(teaching_first);
        gesture(&mut c, "index", "tap", 1, 1.0);
        let mut out = c.set_drag_teaching(!teaching_first);
        out.extend(c.poll(2.0));
        assert!(runs(&out).is_empty(), "teaching first {teaching_first}: {out:?}");
    }
}

#[test]
fn teaching_drags_drops_a_tap_sequence_either_way() {
    for teaching_first in [true, false] {
        let mut c = setup(false, &[(Gesture::IndexTriple, run("triple"))]);
        c.set_drag_teaching(teaching_first);
        let mut out = gesture(&mut c, "index", "tap", 1, 1.0);
        out.extend(gesture(&mut c, "index", "tap", 2, 1.2));
        out.extend(gesture(&mut c, "index", "doubletap", 3, 1.2));
        out.extend(c.set_drag_teaching(!teaching_first));
        out.extend(gesture(&mut c, "index", "tap", 4, 1.4));
        out.extend(gesture(&mut c, "index", "doubletap", 5, 1.4));
        out.extend(c.poll(2.5));
        assert!(runs(&out).is_empty() && !gestures(&out).contains(&Gesture::IndexTriple), "teaching first {teaching_first}: {out:?}");
    }
}

/// Whether this finger's hold acts at the band's hold message (the fast hold) through the
/// engine: right hand, no call, pressed with the palm this way.
fn fast_hold(mut profiles: Profiles<String>, finger: Finger, palm: Palm) -> bool {
    let (name, hold) = match finger {
        Finger::Index => ("index", Gesture::IndexHold),
        Finger::Middle => ("middle", Gesture::MiddleHold),
    };
    for p in &mut profiles.list {
        p.gestures.insert(hold, run("hold").into());
    }
    let mut c = ready(profiles, Hand::Right);
    let roll = match palm {
        Palm::Down => PALM_DOWN,
        Palm::Side => PALM_SIDE,
        Palm::Up => PALM_UP,
    };
    facing(&mut c, roll, 0.75, 0.25);
    assert_eq!(c.palm(1.0), palm);
    press(&mut c, name, 1, 1.0);
    still(&mut c, 1.01, 0.28);
    let ran = runs(&c.on_event(&Event::Gesture(message(name, "hold", 2, 1.3)), 1.3));
    assert!(ran.is_empty() || ran == ["hold"], "{ran:?}");
    !ran.is_empty()
}

#[test]
fn hold_waits_is_the_engines_rule() {
    let one = |p: Profile<String>| profiles(vec![p]);
    let mut cases: Vec<(&str, Profiles<String>)> = vec![("empty", one(profile("a", &[(Gesture::IndexTap, run("tap"))])))];
    let mut p = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    cases.push(("index dial", one(p)));
    let mut p = profile("a", &[]);
    p.gestures.insert(Gesture::IndexDragUp, Binding::from(run("up")).with(Palm::Up, None));
    cases.push(("drag binding, none palm up", one(p)));
    let mut p = profile("a", &[(Gesture::MiddleDragRight, run("x"))]);
    p.middle.drags = DragMode::Sliders([None, None, None]);
    cases.push(("sliders mode, no slider", one(p)));
    let mut p = profile("a", &[]);
    p.middle.drags = DragMode::Sliders([dial("seek-fwd", "seek-back"), None, None]);
    cases.push(("a slider", one(p.clone())));
    cases.push(("a slider, next on its pair, one profile", with_band(one(p.clone()), band(None, Some(Gesture::MiddleDragRight), None))));
    cases.push((
        "a slider, next on its pair, two profiles",
        with_band(profiles(vec![p, profile("b", &[])]), band(None, Some(Gesture::MiddleDragRight), None)),
    ));
    let mut list = one(profile("a", &[]));
    list.band.controls = Some(BandControl { gesture: Gesture::IndexDragLeft, palm: PalmSet::Only([Palm::Up].into()) });
    cases.push(("controls on a drag, palm up only", list));
    let mut list = profiles(vec![profile("a", &[]), profile("b", &[(Gesture::MiddleDragAway, run("away"))])]);
    list.picked = 1;
    cases.push(("the picked profile's drag", list));
    for (name, list) in cases {
        let active = list.picked;
        for finger in [Finger::Index, Finger::Middle] {
            for palm in Palm::ALL {
                let waits = list.hold_waits(active, finger, palm);
                assert_eq!(waits, !fast_hold(list.clone(), finger, palm), "{name}: {finger:?} {palm:?}");
            }
        }
    }
}

#[test]
fn an_app_holding_its_profile_makes_next_on_a_drag_fast_but_hold_waits_doesnt_know() {
    // Next on the index drag up, two profiles, the app in front holds profile 0.
    let make = |foreground: Option<&str>| {
        let mut list = with_band(
            profiles(vec![profile("a", &[(Gesture::IndexHold, run("hold"))]), profile("b", &[])]),
            band(None, Some(Gesture::IndexDragUp), None),
        );
        list.apps.insert("app".into(), 0);
        let mut c = ready(list, Hand::Right);
        c.set_foreground(foreground.map(String::from));
        press(&mut c, "index", 1, 1.0);
        still(&mut c, 1.01, 0.28);
        (runs(&c.on_event(&Event::Gesture(message("index", "hold", 2, 1.3)), 1.3)), c)
    };
    let (held, c) = make(Some("app"));
    assert_eq!(held, ["hold"], "next does nothing while the app holds its profile: the fast hold");
    // The profile rule leaves the app out: it waits, as with no app in front.
    assert!(c.profiles().hold_waits(0, Finger::Index, Palm::Down));
    let (free, _) = make(None);
    assert!(free.is_empty(), "{free:?}");
}
