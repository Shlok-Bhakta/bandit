//! What a gesture did, exactly, for the apps' "gesture · palm → what it did": the palm each
//! gesture was resolved with, why one did nothing, and what a stepping pinch stepped.

mod controls_common;

use band_core::controls::{
    BandControl, BandControls, Builtin, Class, Controls, Drag, DragMode, Finger, Gesture, Output, Palm, Profile, Unused,
};
use band_core::events::Hand;
use controls_common::*;

fn unused(out: &[Output<String>]) -> Vec<(Gesture, Unused)> {
    out.iter().filter_map(|o| match o { Output::Unused { gesture, why } => Some((*gesture, *why)), _ => None }).collect()
}

fn ended(out: &[Output<String>]) -> Vec<(Finger, Class, Palm, u32, u32)> {
    out.iter()
        .filter_map(|o| match o {
            Output::PinchEnded { finger, class, palm, up, down, practiced: false } => Some((*finger, *class, *palm, *up, *down)),
            _ => None,
        })
        .collect()
}

fn practiced(out: &[Output<String>]) -> Vec<(u32, u32)> {
    out.iter()
        .filter_map(|o| match o {
            Output::PinchEnded { up, down, practiced: true, .. } => Some((*up, *down)),
            _ => None,
        })
        .collect()
}

fn dial_controls() -> Controls<String> {
    let mut p = profile("a", &[(Gesture::SwipeUp, run("up"))]);
    p.index.dial = dial("vol-up", "vol-down");
    ready(profiles(vec![p]), Hand::Right)
}

/// An index pinch turning the dial, still down at the end.
fn turning(c: &mut Controls<String>, at: f64) -> Vec<Output<String>> {
    let mut out = press(c, "index", 10_000 + (at * 1000.0) as u64, at);
    out.extend(still(c, at + 0.01, 0.24));
    out.extend(motion(c, turn_dir(), 30.0, at + 0.31, 0.5));
    out
}

fn swipe_up_with_up_override() -> Controls<String> {
    let mut p = profile("a", &[(Gesture::SwipeLeft, run("left")), (Gesture::SwipeRight, run("right"))]);
    p.gestures.insert(Gesture::SwipeUp, up_override("normal", "up"));
    ready(profiles(vec![p]), Hand::Right)
}

#[test]
fn a_gesture_carries_the_palm_it_was_resolved_with() {
    let mut c = swipe_up_with_up_override();
    facing(&mut c, PALM_UP, 0.2, 0.5);
    let out = gesture(&mut c, "thumb", "up", 1, 0.75);
    assert_eq!(out, [Output::Gesture { gesture: Gesture::SwipeUp, palm: Palm::Up }, Output::Run("up".into())]);
    assert_eq!((c.status().last_gesture, c.status().last_palm), (Some("swipe up"), Some(Palm::Up)));
    // No orientation for 0.5 s: palm down, as the engine reads it.
    let out = gesture(&mut c, "thumb", "up", 2, 2.0);
    assert_eq!(out[0], Output::Gesture { gesture: Gesture::SwipeUp, palm: Palm::Down });
}

#[test]
fn a_gesture_that_does_nothing_says_why() {
    let mut c = swipe_up_with_up_override();
    assert_eq!(unused(&gesture(&mut c, "thumb", "down", 1, 1.0)), [(Gesture::SwipeDown, Unused::Unbound)]);
    // Within the action gate of the swipe before.
    assert!(unused(&gesture(&mut c, "thumb", "left", 2, 2.0)).is_empty());
    assert_eq!(unused(&gesture(&mut c, "thumb", "right", 3, 2.1)), [(Gesture::SwipeRight, Unused::TooSoon)]);
    c.pause();
    assert_eq!(unused(&gesture(&mut c, "thumb", "left", 4, 4.0)), [(Gesture::SwipeLeft, Unused::ControlsOff)]);
}

#[test]
fn a_band_control_that_does_nothing_pauses_the_profiles_action_and_says_so() {
    let band = BandControls { next: Some(BandControl::on(Gesture::SwipeLeft)), ..BandControls::default() };
    let p: Profile<String> = profile("only", &[(Gesture::SwipeLeft, run("left"))]);
    let mut c = ready(with_band(profiles(vec![p]), band), Hand::Right);
    let out = gesture(&mut c, "thumb", "left", 1, 1.0);
    assert!(runs(&out).is_empty());
    assert_eq!(unused(&out), [(Gesture::SwipeLeft, Unused::Paused(Builtin::NextProfile))], "one profile: next does nothing");
    // A band control that acts says what it did instead.
    let band = BandControls { controls: Some(BandControl::on(Gesture::SwipeLeft)), ..BandControls::default() };
    let mut c = ready(with_band(profiles(vec![profile("only", &[])]), band), Hand::Right);
    let out = gesture(&mut c, "thumb", "left", 1, 1.0);
    assert!(unused(&out).is_empty() && out.contains(&Output::Controls { enabled: false }), "{out:?}");
}

#[test]
fn a_stepping_pinch_ends_with_what_it_stepped() {
    let mut p = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    p.middle.drags = DragMode::Sliders([dial("right", "left"), None, None]);
    let mut c = ready(profiles(vec![p]), Hand::Right);
    let out = pinch(&mut c, "index", turn_dir(), 30.0, 1.0, true);
    let steps = runs(&out).len() as u32;
    assert!(steps > 0, "{out:?}");
    assert_eq!(ended(&out), [(Finger::Index, Class::Turn, Palm::Down, steps, 0)]);
    let out = pinch(&mut c, "middle", drag_dir(Drag::Right), 30.0, 3.0, true);
    let steps = runs(&out).len() as u32;
    assert!(steps > 0, "{out:?}");
    assert_eq!(ended(&out), [(Finger::Middle, Class::Drag(Drag::Right), Palm::Down, steps, 0)]);
    // A pinch that only held reports no steps.
    assert!(ended(&pinch(&mut c, "index", [0.0, 1.0, 0.0], 0.0, 5.0, true)).is_empty());
}

#[test]
fn a_practiced_pinch_says_so() {
    let mut c = dial_controls();
    c.set_practice(true);
    let out = pinch(&mut c, "index", turn_dir(), 30.0, 1.0, true);
    let steps = out.iter().filter(|o| matches!(o, Output::Practiced(_))).count() as u32;
    assert!(steps > 0 && runs(&out).is_empty(), "{out:?}");
    assert_eq!(practiced(&out), [(steps, 0)]);
    assert!(ended(&out).is_empty());
}

#[test]
fn teaching_drags_and_drawing_say_so_instead_of_unbound() {
    let mut c = dial_controls();
    c.set_drag_teaching(true);
    let out = gesture(&mut c, "thumb", "up", 1, 1.0);
    assert_eq!(unused(&out), [(Gesture::SwipeUp, Unused::Teaching)]);
    assert!(runs(&out).is_empty());
    c.set_drag_teaching(false);
    c.start_drawing(2.0);
    let out = gesture(&mut c, "thumb", "up", 2, 3.0);
    assert_eq!(unused(&out), [(Gesture::SwipeUp, Unused::Drawing)]);
    assert!(runs(&out).is_empty());
}

#[test]
fn a_stepping_pinch_cut_short_still_says_what_it_stepped() {
    type Cut = fn(&mut Controls<String>, f64) -> Vec<Output<String>>;
    let cuts: [(&str, Cut); 4] = [
        ("drawing", |c, now| c.start_drawing(now)),
        ("teaching drags", |c, _| c.set_drag_teaching(true)),
        ("pause", |c, _| c.pause()),
        ("too old", |c, now| c.poll(now + 10.0)),
    ];
    for (what, cut) in cuts {
        let mut c = dial_controls();
        let steps = runs(&turning(&mut c, 1.0)).len() as u32;
        assert!(steps > 0, "{what}");
        let out = cut(&mut c, 2.0);
        assert_eq!(ended(&out), [(Finger::Index, Class::Turn, Palm::Down, steps, 0)], "{what}: {out:?}");
        // Reported once: the release that may still come says nothing more.
        assert!(ended(&release(&mut c, "index", 99_999, 13.0)).is_empty(), "{what}");
    }
}
