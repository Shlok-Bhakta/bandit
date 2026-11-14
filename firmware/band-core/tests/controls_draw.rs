//! The draw session: the Draw band control, strokes, the match and its action.

mod controls_common;

use band_core::controls::draw::{Drawing, Library, MATCH, Stroke};
use band_core::controls::{BandControl, BandControls, Controls, DRAW_DONE, DRAW_IDLE, Drag, Gesture, Invalid, Output, Palm, PalmSet, Warning};
use band_core::events::{Event, Hand};
use controls_common::*;

/// A circle of `r` degrees as gyro motion: 50 steps of 0.02 s from `at`, along its tangent
/// in the drawing plane (x right, y up), each as the forearm-frame direction that projects
/// to it with the palm down (see `draw::project`).
fn circle_motion(c: &mut Controls<String>, r: f64, at: f64) -> Vec<Output<String>> {
    let steps = 50;
    let mut out = Vec::new();
    for i in 0..steps {
        let a = i as f64 / steps as f64 * std::f64::consts::TAU;
        let dir = drawing_dir([-a.sin(), a.cos()]);
        out.extend(motion(c, dir, r * std::f64::consts::TAU / steps as f64, at + i as f64 * 0.02, 0.02));
    }
    out
}

/// A circle of `r` degrees drawn with the index pinch from `at` (let go at `at` + 1.2 s).
fn draw_circle(c: &mut Controls<String>, r: f64, at: f64) -> Vec<Output<String>> {
    let mut out = press(c, "index", 9000 + (at * 100.0) as u64, at);
    out.extend(still(c, at + 0.01, 0.1));
    out.extend(circle_motion(c, r, at + 0.12));
    out.extend(release(c, "index", 9001 + (at * 100.0) as u64, at + 1.2));
    out
}

fn circle_library() -> Library {
    let circle: Stroke = (0..=60).map(|i| {
        let a = i as f64 / 60.0 * std::f64::consts::TAU;
        [10.0 * a.cos(), 10.0 * a.sin()]
    }).collect();
    Library::new(&[Drawing { name: "lightbulb".into(), tries: vec![vec![circle]] }])
}

/// These bindings, Draw on the middle double tap, and a circle called lightbulb that toggles
/// the light.
fn with_draw_on(bindings: &[(Gesture, String)]) -> Controls<String> {
    let mut list = profiles(vec![profile("a", bindings)]);
    list.band.draw = Some(BandControl::on(Gesture::MiddleDouble));
    list.drawings.insert("lightbulb".into(), run("light.toggle"));
    let mut c = ready(list, Hand::Right);
    c.set_library(circle_library());
    c
}

fn with_draw() -> Controls<String> {
    with_draw_on(&[(Gesture::IndexTap, run("tap"))])
}

fn matched(out: &[Output<String>]) -> Option<&str> {
    out.iter().find_map(|o| match o { Output::Drawn { name, .. } => Some(name.as_str()), _ => None })
}

fn open(c: &mut Controls<String>, at: f64) -> Vec<Output<String>> {
    let mut out = gesture(c, "middle", "tap", 1 + (at * 10.0) as u64, at);
    out.extend(gesture(c, "middle", "doubletap", 2 + (at * 10.0) as u64, at + 0.25));
    out
}

#[test]
fn draw_opens_a_session_strokes_are_reported_and_a_match_runs_its_action() {
    let mut c = with_draw();
    assert!(open(&mut c, 1.0).contains(&Output::DrawStarted));
    let drawn = draw_circle(&mut c, 12.0, 2.0);
    assert!(drawn.iter().any(|o| matches!(o, Output::DrawPoint { stroke: 0, .. })));
    let mut out = still(&mut c, 3.25, 0.5);
    out.extend(c.poll(4.3));
    assert!(out.iter().any(|o| matches!(o, Output::DrawFinished { strokes } if strokes.len() == 1)));
    assert_eq!(matched(&out), Some("lightbulb"));
    assert!(out.iter().any(|o| matches!(o, Output::Drawn { distance, .. } if *distance < MATCH)));
    assert_eq!(runs(&out), ["light.toggle"]);
}

#[test]
fn a_profiles_own_action_wins_and_a_drawing_without_an_action_isnt_matched() {
    let mut c = with_draw();
    let mut list = c.profiles().clone();
    list.list[0].drawings.insert("lightbulb".into(), run("own"));
    c.set_profiles(list);
    open(&mut c, 1.0);
    draw_circle(&mut c, 12.0, 2.0);
    let out = c.poll(4.3);
    assert_eq!(runs(&out), ["own"]);
    let mut list = c.profiles().clone();
    list.list[0].drawings.clear();
    list.drawings.clear();
    c.set_profiles(list);
    open(&mut c, 6.0);
    draw_circle(&mut c, 12.0, 7.0);
    assert!(c.poll(9.3).contains(&Output::NotDrawn));
}

#[test]
fn nothing_else_acts_during_a_session_and_draw_again_cancels() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    assert!(runs(&gesture(&mut c, "index", "tap", 50, 1.6)).is_empty());
    assert!(open(&mut c, 2.0).contains(&Output::DrawCancelled));
    assert_eq!(runs(&gesture(&mut c, "index", "tap", 60, 3.0)), ["tap"]);
}

#[test]
fn an_idle_session_is_cancelled() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    assert!(c.poll(11.5).contains(&Output::DrawCancelled));
}

#[test]
fn teaching_reports_the_strokes_without_matching_or_running() {
    let mut c = with_draw();
    c.set_teaching(true);
    open(&mut c, 1.0);
    draw_circle(&mut c, 12.0, 2.0);
    let out = c.poll(4.3);
    assert!(out.iter().any(|o| matches!(o, Output::DrawFinished { .. })));
    assert!(!out.iter().any(|o| matches!(o, Output::Drawn { .. } | Output::NotDrawn)));
    assert!(runs(&out).is_empty());
}

#[test]
fn in_practice_a_session_opens_and_its_match_is_only_practiced() {
    let mut c = with_draw();
    c.set_practice(true);
    assert!(open(&mut c, 1.0).contains(&Output::DrawStarted));
    draw_circle(&mut c, 12.0, 2.0);
    let out = c.poll(4.3);
    assert_eq!(matched(&out), Some("lightbulb"));
    assert!(out.contains(&Output::Practiced(run("light.toggle"))));
    assert!(runs(&out).is_empty());
}

#[test]
fn draw_does_nothing_while_the_controls_are_off() {
    let mut c = with_draw();
    c.pause();
    assert!(!open(&mut c, 1.0).contains(&Output::DrawStarted));
    assert!(!c.drawing());
}

#[test]
fn the_pens_hold_message_is_part_of_the_stroke() {
    let mut c = with_draw_on(&[(Gesture::IndexHold, run("hold"))]);
    open(&mut c, 1.0);
    // The band's hold message comes 0.3 s into the stroke.
    let mut out = press(&mut c, "index", 300, 2.0);
    out.extend(still(&mut c, 2.01, 0.28));
    out.extend(gesture(&mut c, "index", "hold", 301, 2.3));
    out.extend(circle_motion(&mut c, 12.0, 2.31));
    out.extend(release(&mut c, "index", 302, 3.4));
    assert!(gestures(&out).is_empty() && runs(&out).is_empty(), "{out:?}");
    assert!(out.iter().any(|o| matches!(o, Output::DrawPoint { .. })));
    assert_eq!(runs(&c.poll(4.4)), ["light.toggle"]);
}

#[test]
fn a_pen_never_lifted_is_dropped_and_the_session_cancelled() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    press(&mut c, "index", 400, 2.0);
    assert_eq!(c.next_deadline(), Some(12.0), "the pen's age");
    assert!(c.poll(11.9).is_empty());
    assert_eq!(c.poll(12.0), [Output::Pen { down: false }, Output::DrawCancelled]);
    assert!(!c.drawing());
}

#[test]
fn the_next_deadline_follows_the_session() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    let near_deadline = |c: &Controls<String>, at: f64| c.next_deadline().is_some_and(|due| (due - at).abs() < 1e-9);
    assert!(near_deadline(&c, 1.25 + DRAW_IDLE), "{:?}", c.next_deadline());
    draw_circle(&mut c, 12.0, 2.0);
    assert!(near_deadline(&c, 3.2 + DRAW_DONE), "{:?}", c.next_deadline());
}

/// A straight stroke: press at `at`, `degrees` along `[dx, dy]` over `secs`, release.
fn line(c: &mut Controls<String>, finger: &str, [dx, dy]: [f64; 2], degrees: f64, at: f64, secs: f64) -> Vec<Output<String>> {
    let sequence = 20_000 + (at * 1000.0).round() as u64 * 10;
    let mut out = press(c, finger, sequence, at);
    out.extend(motion(c, drawing_dir([dx, dy]), degrees, at + 0.01, secs));
    out.extend(release(c, finger, sequence + 1, at + 0.02 + secs));
    out
}

fn finished(out: &[Output<String>]) -> Vec<Stroke> {
    out.iter().find_map(|o| match o { Output::DrawFinished { strokes } => Some(strokes.clone()), _ => None }).expect("finished")
}

fn points(out: &[Output<String>]) -> Vec<(usize, [f64; 2])> {
    out.iter().filter_map(|o| match o { Output::DrawPoint { stroke, x, y } => Some((*stroke, [*x, *y])), _ => None }).collect()
}

fn near(a: [f64; 2], b: [f64; 2]) -> bool {
    (a[0] - b[0]).hypot(a[1] - b[1]) < 0.5
}

fn synthetic_release(c: &mut Controls<String>, finger: &str, sequence: u64, t: f64) -> Vec<Output<String>> {
    let mut m = message(finger, "release", sequence, t);
    m.synthetic = true;
    c.on_event(&Event::Gesture(m), t)
}

#[test]
fn the_second_stroke_starts_where_the_hand_moved_to_between_strokes() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    line(&mut c, "index", [1.0, 0.0], 10.0, 2.0, 0.5);
    // Pen up: 6° up, then the second stroke.
    still(&mut c, 2.53, 0.05);
    motion(&mut c, drawing_dir([0.0, 1.0]), 6.0, 2.59, 0.3);
    let second = line(&mut c, "index", [1.0, 0.0], 10.0, 2.95, 0.5);
    let strokes = finished(&c.poll(5.0));
    assert_eq!(strokes.len(), 2);
    let end = *strokes[0].last().unwrap();
    assert!(near(end, [10.0, 0.0]), "{end:?}");
    assert!(near(strokes[1][0], [10.0, 6.0]), "{:?}", strokes[1][0]);
    // Its first point is reported too.
    assert_eq!(points(&second).first().map(|(s, p)| (*s, near(*p, [10.0, 6.0]))), Some((1, true)), "{second:?}");
}

#[test]
fn a_tap_isnt_a_stroke() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    line(&mut c, "index", [1.0, 0.0], 3.0, 2.0, 0.15);
    let drawn = draw_circle(&mut c, 12.0, 2.5);
    assert!(points(&drawn).iter().all(|(stroke, _)| *stroke == 0));
    let strokes = finished(&c.poll(5.0));
    assert_eq!(strokes.len(), 1);
    // A tap alone: nothing drawn, the session is cancelled when idle.
    open(&mut c, 6.0);
    line(&mut c, "index", [1.0, 0.0], 3.0, 7.0, 0.15);
    assert!(c.poll(16.4).contains(&Output::DrawCancelled));
}

#[test]
fn the_pens_synthetic_release_drops_its_stroke() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    press(&mut c, "index", 500, 2.0);
    motion(&mut c, drawing_dir([1.0, 0.0]), 10.0, 2.01, 0.5);
    synthetic_release(&mut c, "index", 501, 2.52);
    draw_circle(&mut c, 12.0, 3.0);
    let strokes = finished(&c.poll(5.5));
    assert_eq!(strokes.len(), 1);
    // Only the circle (left of where it starts), none of the dropped line.
    assert!(strokes[0].len() > 50 && strokes[0].iter().all(|p| p[0] < 1.0), "{:?}", strokes[0]);
}

#[test]
fn the_other_fingers_press_while_the_pen_is_down_is_a_new_pen() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    // Middle pressed, never released; the index takes over.
    press(&mut c, "middle", 500, 2.0);
    motion(&mut c, drawing_dir([1.0, 0.0]), 10.0, 2.01, 0.5);
    let out = line(&mut c, "index", [0.0, 1.0], 8.0, 2.55, 0.5);
    // The middle's release later is nothing.
    release(&mut c, "middle", 501, 3.2);
    let strokes = finished(&c.poll(5.0));
    assert_eq!(strokes.len(), 1);
    let (start, end) = (strokes[0][0], *strokes[0].last().unwrap());
    assert!(near([end[0] - start[0], end[1] - start[1]], [0.0, 8.0]), "{start:?} {end:?}");
    assert!(points(&out).iter().all(|(stroke, _)| *stroke == 0));
}

#[test]
fn the_pens_press_twice_is_one_press() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    press(&mut c, "index", 500, 2.0);
    motion(&mut c, drawing_dir([1.0, 0.0]), 5.0, 2.01, 0.25);
    // The band's second press message, late.
    c.on_event(&Event::Gesture(band_core::events::GestureMessage { derived_action: "buttonPress".into(), ..message("index", "unknown", 501, 2.27) }), 2.27);
    motion(&mut c, drawing_dir([1.0, 0.0]), 5.0, 2.28, 0.25);
    release(&mut c, "index", 502, 2.55);
    let strokes = finished(&c.poll(4.0));
    assert_eq!(strokes.len(), 1);
    assert!(near(*strokes[0].last().unwrap(), [10.0, 0.0]), "{:?}", strokes[0].last());
}

#[test]
fn a_gap_in_the_bands_clock_drops_the_stroke() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    press(&mut c, "index", 500, 2.0);
    motion(&mut c, drawing_dir([1.0, 0.0]), 5.0, 2.01, 0.25);
    // 0.4 s of motion lost, then the pen goes on and is let go.
    motion(&mut c, drawing_dir([1.0, 0.0]), 5.0, 2.66, 0.25);
    release(&mut c, "index", 501, 2.95);
    assert!(c.poll(13.0).contains(&Output::DrawCancelled));
}

#[test]
fn the_middle_finger_is_a_pen_too() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    let out = line(&mut c, "middle", [1.0, 0.0], 10.0, 2.0, 0.5);
    assert!(!points(&out).is_empty());
    let strokes = finished(&c.poll(4.0));
    assert_eq!(strokes.len(), 1);
    assert!(near(*strokes[0].last().unwrap(), [10.0, 0.0]));
}

#[test]
fn two_strokes_are_numbered_0_and_1() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    let mut out = line(&mut c, "index", [1.0, 0.0], 10.0, 2.0, 0.5);
    out.extend(line(&mut c, "index", [0.0, 1.0], 10.0, 2.8, 0.5));
    let numbers: Vec<usize> = points(&out).iter().map(|(stroke, _)| *stroke).collect();
    assert!(numbers.contains(&0) && numbers.contains(&1) && numbers.windows(2).all(|w| w[0] <= w[1]), "{numbers:?}");
    assert_eq!(finished(&c.poll(5.0)).len(), 2);
}

#[test]
fn swipes_and_drags_dont_act_during_a_session() {
    let mut c = with_draw_on(&[(Gesture::SwipeUp, run("swipe")), (Gesture::IndexDragUp, run("drag"))]);
    open(&mut c, 1.0);
    let mut out = gesture(&mut c, "thumb", "up", 100, 1.6);
    out.extend(pinch(&mut c, "index", drag_dir(Drag::Up), 40.0, 2.0, true));
    assert!(runs(&out).is_empty(), "{out:?}");
    assert!(!gestures(&out).contains(&Gesture::IndexDragUp));
    // After the session they do.
    c.poll(4.0);
    assert!(!c.drawing());
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 101, 4.5)), ["swipe"]);
    assert_eq!(runs(&pinch(&mut c, "index", drag_dir(Drag::Up), 40.0, 5.0, true)), ["drag"]);
}

#[test]
fn a_disconnect_ends_the_session() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    press(&mut c, "index", 500, 2.0);
    motion(&mut c, drawing_dir([1.0, 0.0]), 5.0, 2.01, 0.25);
    c.on_disconnect();
    assert!(!c.drawing());
    assert_eq!(c.next_deadline(), None);
    c.on_event(&Event::Connected, 3.0);
    let mut out = motion(&mut c, drawing_dir([1.0, 0.0]), 5.0, 3.1, 0.25);
    out.extend(release(&mut c, "index", 501, 3.4));
    out.extend(c.poll(15.0));
    assert!(points(&out).is_empty() && !out.iter().any(|o| matches!(o, Output::DrawFinished { .. } | Output::DrawCancelled)), "{out:?}");
}

#[test]
fn pausing_cancels_the_session() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    press(&mut c, "index", 500, 2.0);
    assert_eq!(c.pause(), [Output::DrawCancelled, Output::Controls { enabled: false }]);
    assert!(!c.drawing());
}

#[test]
fn the_app_can_start_and_cancel_a_session_without_the_band_control() {
    let mut c = ready(profiles(vec![profile("a", &[(Gesture::IndexTap, run("tap"))])]), Hand::Right);
    c.set_library(circle_library());
    c.set_teaching(true);
    assert_eq!(c.cancel_drawing(), []);
    assert_eq!(c.start_drawing(1.0), [Output::DrawStarted]);
    assert!(c.drawing());
    assert_eq!(c.start_drawing(1.5), [], "already drawing");
    draw_circle(&mut c, 12.0, 2.0);
    assert_eq!(finished(&c.poll(4.3)).len(), 1);
    assert_eq!(c.start_drawing(5.0), [Output::DrawStarted]);
    assert_eq!(c.cancel_drawing(), [Output::DrawCancelled]);
    assert!(!c.drawing());
    assert_eq!(runs(&gesture(&mut c, "index", "tap", 60, 6.0)), ["tap"]);
}

#[test]
fn draw_on_a_triple_or_drag_cant_cancel_its_session() {
    // A hold can't either, but it's the standard Draw and not shown as wrong.
    for (gesture, cant) in [
        (Gesture::IndexHold, false),
        (Gesture::MiddleHold, false),
        (Gesture::MiddleTriple, true),
        (Gesture::IndexDragUp, true),
        (Gesture::MiddleDouble, false),
        (Gesture::SwipeDown, false),
    ] {
        let mut list = profiles(vec![profile("a", &[])]);
        list.band.draw = Some(BandControl::on(gesture));
        assert_eq!(list.invalid().contains(&Invalid::DrawCantCancel), cant, "{gesture:?}");
    }
}

#[test]
fn draw_in_a_session_has_its_own_press_palm() {
    let mut list = profiles(vec![profile("a", &[])]);
    list.band.draw = Some(BandControl { gesture: Gesture::MiddleDouble, palm: PalmSet::Only([Palm::Up].into()) });
    let mut c = ready(list, Hand::Right);
    facing(&mut c, PALM_UP, 0.8, 0.5);
    assert!(open(&mut c, 1.3).contains(&Output::DrawStarted));
    // Pressed with the palm up; by the time the double tap comes it's down.
    facing(&mut c, PALM_UP, 2.0, 0.2);
    press(&mut c, "middle", 500, 2.2);
    facing(&mut c, PALM_DOWN, 2.25, 0.3);
    let mut out = gesture(&mut c, "middle", "tap", 501, 2.5);
    out.extend(gesture(&mut c, "middle", "doubletap", 502, 2.55));
    assert!(out.contains(&Output::DrawCancelled), "{out:?}");
}

#[test]
fn a_hold_running_through_the_sessions_end_doesnt_fire_after_it() {
    for standard in [false, true] {
        let mut c = with_draw_on(&[(Gesture::MiddleHold, run("hold"))]);
        if standard {
            let mut list = c.profiles().clone();
            list.band = BandControls { draw: list.band.draw, ..BandControls::standard() };
            c.set_profiles(list);
        }
        assert_eq!(c.start_drawing(1.0), [Output::DrawStarted]);
        press(&mut c, "middle", 500, 2.0);
        gesture(&mut c, "middle", "hold", 501, 2.3);
        assert_eq!(c.cancel_drawing(), [Output::DrawCancelled]);
        // The band repeats the hold while it lasts.
        let out = gesture(&mut c, "middle", "hold", 502, 2.6);
        assert!(runs(&out).is_empty() && toggles(&out).is_empty(), "standard {standard}: {out:?}");
        assert!(c.enabled());
    }
}

#[test]
fn a_session_finished_while_paused_isnt_matched() {
    let mut c = with_draw();
    c.pause();
    assert_eq!(c.start_drawing(1.0), [Output::DrawStarted]);
    draw_circle(&mut c, 12.0, 2.0);
    let out = c.poll(4.3);
    assert!(matches!(out.as_slice(), [Output::DrawFinished { strokes }] if strokes.len() == 1), "{:?}", out.len());
    assert!(c.status().last_action.is_none());
}

#[test]
fn draw_on_a_single_tap_is_a_warning() {
    for (gesture, warned) in [(Gesture::IndexTap, true), (Gesture::MiddleTap, true), (Gesture::MiddleDouble, false)] {
        let mut list = profiles(vec![profile("a", &[])]);
        list.band.draw = Some(BandControl::on(gesture));
        assert_eq!(list.warnings().contains(&Warning::DrawOnTap), warned, "{gesture:?}");
    }
}

/// The pen's ups and downs (`Output::Pen`), in order.
fn pens(out: &[Output<String>]) -> Vec<bool> {
    out.iter().filter_map(|o| match o { Output::Pen { down } => Some(*down), _ => None }).collect()
}

#[test]
fn the_pen_goes_down_before_its_strokes_first_point_and_up_at_the_release() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    assert_eq!(press(&mut c, "index", 500, 2.0), [Output::Pen { down: true }, Output::DrawPoint { stroke: 0, x: 0.0, y: 0.0 }]);
    let mut out = motion(&mut c, drawing_dir([1.0, 0.0]), 10.0, 2.01, 0.5);
    // The band's second press, another finger's release: the pen stays down.
    out.extend(press(&mut c, "index", 501, 2.2));
    out.extend(release(&mut c, "middle", 502, 2.3));
    assert!(pens(&out).is_empty(), "{out:?}");
    assert_eq!(release(&mut c, "index", 503, 2.55), [Output::Pen { down: false }]);
    // Nothing more of the pen until the next press; the session's end isn't a pen change.
    let mut out = still(&mut c, 2.56, 0.3);
    out.extend(c.poll(4.0));
    assert!(pens(&out).is_empty() && out.iter().any(|o| matches!(o, Output::DrawFinished { .. })), "{out:?}");
}

#[test]
fn a_dropped_stroke_puts_the_pen_up() {
    // A tap.
    let mut c = with_draw();
    open(&mut c, 1.0);
    assert_eq!(pens(&line(&mut c, "index", [1.0, 0.0], 3.0, 2.0, 0.15)), [true, false]);
    // The band's synthetic release.
    let mut c = with_draw();
    open(&mut c, 1.0);
    let mut out = press(&mut c, "index", 500, 2.0);
    out.extend(motion(&mut c, drawing_dir([1.0, 0.0]), 10.0, 2.01, 0.5));
    out.extend(synthetic_release(&mut c, "index", 501, 2.52));
    assert_eq!(pens(&out), [true, false]);
    assert!(release(&mut c, "index", 502, 2.6).is_empty(), "its real release later is nothing");
    // A gap in the band's clock: up when the motion comes back.
    let mut c = with_draw();
    open(&mut c, 1.0);
    press(&mut c, "index", 500, 2.0);
    motion(&mut c, drawing_dir([1.0, 0.0]), 5.0, 2.01, 0.25);
    let after_gap = motion(&mut c, drawing_dir([1.0, 0.0]), 5.0, 2.66, 0.25);
    assert_eq!(pens(&after_gap), [false]);
    assert!(points(&after_gap).is_empty(), "{after_gap:?}");
    assert!(release(&mut c, "index", 501, 2.95).is_empty());
}

#[test]
fn a_pen_down_too_long_goes_up_and_the_session_goes_on_after_a_stroke() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    line(&mut c, "index", [1.0, 0.0], 10.0, 2.0, 0.5);
    press(&mut c, "index", 600, 3.0);
    assert!(c.poll(12.9).is_empty());
    assert_eq!(c.poll(13.0), [Output::Pen { down: false }]);
    assert!(c.drawing());
    assert_eq!(finished(&c.poll(14.0)).len(), 1);
}

#[test]
fn the_other_fingers_takeover_puts_the_pen_up_then_down() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    assert_eq!(pens(&press(&mut c, "middle", 500, 2.0)), [true]);
    motion(&mut c, drawing_dir([1.0, 0.0]), 10.0, 2.01, 0.5);
    assert_eq!(
        press(&mut c, "index", 501, 2.55),
        [Output::Pen { down: false }, Output::Pen { down: true }, Output::DrawPoint { stroke: 0, x: 0.0, y: 0.0 }]
    );
    // The middle's release later is nothing; the index's lets go.
    assert!(release(&mut c, "middle", 502, 2.8).is_empty());
    assert_eq!(pens(&release(&mut c, "index", 503, 3.0)), [false]);
}

#[test]
fn closing_the_session_with_the_pen_down_is_no_pen_change() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    press(&mut c, "index", 500, 2.0);
    assert_eq!(c.cancel_drawing(), [Output::DrawCancelled]);
    // The pen's release after the session is nothing either.
    assert!(pens(&release(&mut c, "index", 501, 2.5)).is_empty());
}

#[test]
fn the_draw_gesture_with_the_pen_down_only_cancels() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    press(&mut c, "index", 500, 2.0);
    motion(&mut c, drawing_dir([1.0, 0.0]), 5.0, 2.01, 0.25);
    // Draw (the middle double tap) again while the index pen is down.
    let out = open(&mut c, 2.3);
    let rest: Vec<&Output<String>> = out.iter().filter(|o| !matches!(o, Output::Gesture { .. } | Output::Unused { .. })).collect();
    assert_eq!(rest, [&Output::DrawCancelled], "{out:?}");
    assert!(!c.drawing());
}

/// A palm calibration (the owner's: down +2.3°, up −125.8°) doesn't turn the drawings: each
/// stroke's own roll is taken out, and the drawing frame is fixed (`draw::FRAME_ROLL`).
#[test]
fn a_calibration_doesnt_turn_the_drawings() {
    let draw = |calibrated: bool| {
        let mut c = with_draw();
        if calibrated {
            c.set_calibration(Some(band_core::controls::PalmCalibration { down_roll: 2.3, up_roll: -125.8 }), None);
        }
        facing(&mut c, 2.3, 0.2, 0.5);
        open(&mut c, 1.0);
        facing(&mut c, 2.3, 1.5, 0.4);
        line(&mut c, "index", [1.0, 1.0], 10.0, 2.0, 0.3);
        finished(&c.poll(4.0))
    };
    let (plain, calibrated) = (draw(false), draw(true));
    assert_eq!(plain.len(), 1);
    for (a, b) in plain[0].iter().zip(&calibrated[0]) {
        assert!(near(*a, *b), "{plain:?} vs {calibrated:?}");
    }
}

/// Without a fresh orientation the pen is taken to be palm down (`Prototypes::palm_down_roll`):
/// a stroke made palm down draws as itself; the same motion with the palm known to be up
/// draws turned.
#[test]
fn without_a_fresh_orientation_the_pen_is_palm_down() {
    let mut c = with_draw();
    open(&mut c, 1.0);
    line(&mut c, "index", [1.0, 0.0], 10.0, 2.0, 0.5);
    let stroke = finished(&c.poll(4.0)).remove(0);
    assert!(near(*stroke.last().unwrap(), [10.0, 0.0]), "{stroke:?}");
    let mut c = with_draw();
    open(&mut c, 1.0);
    facing(&mut c, PALM_UP, 1.5, 0.45);
    line(&mut c, "index", [1.0, 0.0], 10.0, 2.0, 0.5);
    let turned = finished(&c.poll(4.0)).remove(0);
    assert!(!near(*turned.last().unwrap(), [10.0, 0.0]), "read at the palm up instead: {turned:?}");
}
