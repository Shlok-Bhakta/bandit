//! Writing in a text field (`Controls::set_writing`): gestures are reported for editing and
//! nothing acts but the Controls on/off band control; handwriting types only while `writes`.

mod controls_common;

use band_core::controls::{BandControl, BandControls, Builtin, Controls, Gesture, Output, Palm, Profiles, Unused};
use band_core::events::{Event, Hand};
use controls_common::*;

fn unused(out: &[Output<String>]) -> Vec<(Gesture, Unused)> {
    out.iter().filter_map(|o| match o { Output::Unused { gesture, why } => Some((*gesture, *why)), _ => None }).collect()
}

fn practiced(out: &[Output<String>]) -> usize {
    out.iter().filter(|o| matches!(o, Output::Practiced(_))).count()
}

/// Two profiles (a swipe up bound in the first) under the standard band controls: Controls
/// on/off on the middle hold, next and previous on the index and middle triple taps, Draw on
/// the index hold.
fn standard() -> Profiles<String> {
    with_band(
        profiles(vec![profile("a", &[(Gesture::SwipeUp, run("up"))]), profile("b", &[])]),
        BandControls::standard(),
    )
}

fn writing() -> Controls<String> {
    let mut c = live(standard());
    c.set_writing(true);
    c
}

/// A middle tap, waited out (the middle triple tap is previous profile).
fn middle_tap(c: &mut Controls<String>, sequence: u64, at: f64) -> Vec<Output<String>> {
    let mut out = gesture(c, "middle", "tap", sequence, at);
    out.extend(c.poll(at + 1.0));
    out
}

#[test]
fn the_middle_hold_turns_the_controls_off_and_on_while_writing() {
    let mut c = writing();
    assert_eq!(
        gesture(&mut c, "middle", "hold", 1, 1.0),
        [Output::Gesture { gesture: Gesture::MiddleHold, palm: Palm::Down }, Output::Controls { enabled: false }]
    );
    assert!(!c.enabled() && c.writing());
    assert_eq!(toggles(&gesture(&mut c, "middle", "hold", 2, 3.0)), [true]);
    assert!(c.enabled());
}

#[test]
fn next_previous_and_draw_do_nothing_while_writing() {
    let mut c = writing();
    let out = triple(&mut c, "index", 1.0);
    assert!(switches(&out).is_empty());
    assert_eq!(unused(&out).last(), Some(&(Gesture::IndexTriple, Unused::Writing)));
    let out = triple(&mut c, "middle", 3.0);
    assert!(switches(&out).is_empty());
    assert_eq!(unused(&out).last(), Some(&(Gesture::MiddleTriple, Unused::Writing)));
    assert_eq!(c.active(), 0);
    let out = middle_tap(&mut c, 20, 6.0);
    assert_eq!(
        out,
        [
            Output::Gesture { gesture: Gesture::MiddleTap, palm: Palm::Down },
            Output::Unused { gesture: Gesture::MiddleTap, why: Unused::Writing }
        ]
    );
    assert!(!c.drawing());
}

#[test]
fn every_gesture_is_reported_for_editing_and_nothing_runs() {
    let mut c = writing();
    // Bound, and unbound: reported once each, then why it did nothing, exactly once.
    for (sequence, direction, gesture) in [(1, "up", Gesture::SwipeUp), (2, "down", Gesture::SwipeDown)] {
        let out = gesture_at(&mut c, direction, sequence);
        assert_eq!(out, [Output::Gesture { gesture, palm: Palm::Down }, Output::Unused { gesture, why: Unused::Writing }]);
    }
    assert!(c.status().last_action.is_none());
}

/// A thumb swipe at `sequence` seconds.
fn gesture_at(c: &mut Controls<String>, direction: &str, sequence: u64) -> Vec<Output<String>> {
    gesture(c, "thumb", direction, sequence, sequence as f64)
}

#[test]
fn nothing_is_reported_for_editing_while_writing_with_the_controls_off() {
    let mut c = writing();
    c.pause();
    let out = gesture(&mut c, "thumb", "up", 1, 1.0);
    assert_eq!(unused(&out), [(Gesture::SwipeUp, Unused::ControlsOff)]);
    let out = middle_tap(&mut c, 2, 2.0);
    assert_eq!(unused(&out), [(Gesture::MiddleTap, Unused::ControlsOff)]);
    assert!(runs(&out).is_empty() && !c.drawing());
    // The middle hold still turns them back on.
    assert_eq!(toggles(&gesture(&mut c, "middle", "hold", 3, 4.0)), [true]);
}

#[test]
fn a_dial_does_not_step_while_writing() {
    let mut p = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    let mut c = ready(profiles(vec![p]), Hand::Right);
    c.set_writing(true);
    let out = pinch(&mut c, "index", turn_dir(), 30.0, 1.0, true);
    assert!(runs(&out).is_empty() && practiced(&out) == 0, "{out:?}");
    assert!(!out.iter().any(|o| matches!(o, Output::PinchEnded { .. })), "{out:?}");
    // Back to normal once the field loses focus.
    c.set_writing(false);
    assert!(!runs(&pinch(&mut c, "index", turn_dir(), 30.0, 3.0, true)).is_empty());
}

#[test]
fn writes_only_while_writing_with_the_controls_on_and_the_band_live() {
    let mut c = Controls::new(Default::default(), standard());
    c.set_writing(true);
    assert!(!c.writes(), "not live yet");
    c.on_event(&Event::Connected, 0.0);
    assert!(c.writes());
    c.set_writing(false);
    assert!(!c.writes());
    c.set_writing(true);
    c.pause();
    assert!(!c.writes());
    c.resume(1.0);
    assert!(c.writes());
    c.on_disconnect();
    assert!(!c.writes());
    // Practice alone is not writing.
    let mut c = live(standard());
    c.set_practice(true);
    assert!(!c.writes() && !c.writing());
}

#[test]
fn writing_wins_over_practice() {
    let mut c = writing();
    c.set_practice(true);
    let out = gesture(&mut c, "thumb", "up", 1, 1.0);
    assert_eq!(unused(&out), [(Gesture::SwipeUp, Unused::Writing)]);
    assert_eq!(practiced(&out), 0);
    assert_eq!(toggles(&gesture(&mut c, "middle", "hold", 2, 2.0)), [false]);
    // Out of the field, practice is as it was.
    c.resume(3.0);
    c.set_writing(false);
    assert_eq!(practiced(&gesture(&mut c, "thumb", "up", 3, 4.0)), 1);
    assert_eq!(unused(&gesture(&mut c, "middle", "hold", 4, 5.0)), [(Gesture::MiddleHold, Unused::Paused(Builtin::Controls))]);
}

#[test]
fn teaching_drags_wins_over_writing() {
    let mut c = writing();
    c.set_drag_teaching(true);
    assert_eq!(unused(&gesture(&mut c, "thumb", "up", 1, 1.0)), [(Gesture::SwipeUp, Unused::Teaching)]);
    // Its hold waits for the release, and doesn't turn the controls off either.
    let out = pinch(&mut c, "middle", [0.0, 1.0, 0.0], 0.0, 2.0, true);
    assert_eq!(unused(&out), [(Gesture::MiddleHold, Unused::Teaching)]);
    assert!(c.enabled());
}

#[test]
fn a_draw_session_carries_on_when_writing_starts() {
    // Draw on the middle tap, which (unlike a hold) also cancels a session.
    let band = BandControls { draw: Some(BandControl::on(Gesture::MiddleTap)), ..BandControls::standard() };
    let mut c = live(with_band(profiles(vec![profile("a", &[(Gesture::SwipeUp, run("up"))]), profile("b", &[])]), band));
    assert!(middle_tap(&mut c, 1, 1.0).contains(&Output::DrawStarted));
    c.set_writing(true);
    assert!(c.drawing());
    // Its own rules: only the Draw gesture acts, cancelling it.
    assert_eq!(unused(&gesture(&mut c, "thumb", "up", 2, 3.0)), [(Gesture::SwipeUp, Unused::Drawing)]);
    assert!(middle_tap(&mut c, 3, 4.0).contains(&Output::DrawCancelled));
    assert!(!c.drawing());
    // The app's teach screen can still open one.
    assert!(c.start_drawing(6.0).contains(&Output::DrawStarted));
}

#[test]
fn a_gesture_the_field_does_not_take_acts_as_usual_while_writing() {
    let mut c = writing();
    c.set_writing_layer(vec![Gesture::SwipeLeft], false);
    // Swipe up isn't the field's: it runs its action.
    let out = gesture(&mut c, "thumb", "up", 1, 1.0);
    assert_eq!(runs(&out), ["up"], "{out:?}");
    // Swipe left is.
    let out = gesture(&mut c, "thumb", "left", 2, 2.0);
    assert_eq!(unused(&out), [(Gesture::SwipeLeft, Unused::Writing)]);
}

#[test]
fn a_dial_steps_while_writing_when_the_layer_lets_it() {
    let mut p = profile("a", &[]);
    p.index.dial = dial("vol-up", "vol-down");
    let mut c = ready(profiles(vec![p]), Hand::Right);
    c.set_writing(true);
    c.set_writing_layer(Gesture::ALL.to_vec(), true);
    assert!(!runs(&pinch(&mut c, "index", turn_dir(), 30.0, 1.0, true)).is_empty());
}
