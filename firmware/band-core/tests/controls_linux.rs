//! The Linux controller's tests (`air-gesturesd/tests/controller.rs`), on the shared engine.
//!
//! Same names, same intent. The Linux defaults the tests rely on are bound explicitly in each
//! test's profile. Where the Linux test asserted an empty command list, the shared engine still
//! reports the recognized gesture (`Output::Gesture`, also while the controls are off), so
//! those check that nothing *runs*.

mod controls_common;

use band_core::controls::{Controls, Gesture, HandSetting, Options, Output, Palm, Profile};
use band_core::events::{BatteryStatus, Event, Hand};
use controls_common::*;

const LEFT: &str = "hyprctl dispatch workspace e-1";
const RIGHT: &str = "hyprctl dispatch workspace e+1";
const UP: &str = "wofi --show drun";
const PLAY: &str = "playerctl play-pause";
const MUTE: &str = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
const VOLUME_UP: &str = "wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 2%+";
const VOLUME_DOWN: &str = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 2%-";
const DIAL_TOGGLE: &str = "air-gestures-dial toggle";
/// A pinch turned this far makes some dial steps.
const DEGREES: f64 = 30.0;

/// The Linux default swipes.
fn swipes() -> Profile<String> {
    profile("p", &[(Gesture::SwipeLeft, run(LEFT)), (Gesture::SwipeRight, run(RIGHT)), (Gesture::SwipeUp, run(UP))])
}

/// The Linux default double taps and the volume dial.
fn dial_profile() -> Profile<String> {
    let mut p = profile("p", &[(Gesture::IndexDouble, run(PLAY)), (Gesture::MiddleDouble, run(MUTE))]);
    p.index.dial = dial(VOLUME_UP, VOLUME_DOWN);
    p
}

fn with_hand(hand: Hand) -> Controls<String> {
    let mut c = live(profiles(vec![dial_profile()]));
    c.on_event(&Event::Handedness(hand), 1.0);
    c
}

fn hand(hand: HandSetting) -> Options {
    Options { hand, ..Options::default() }
}

#[test]
fn a_swipe_runs_its_command_once() {
    let mut c = live(profiles(vec![swipes()]));
    let swipe = Event::Gesture(message("thumb", "left", 1, 2.0));
    assert_eq!(c.on_event(&swipe, 2.0), [Output::Gesture { gesture: Gesture::SwipeLeft, palm: Palm::Down }, Output::Run(LEFT.to_owned())]);
    assert!(c.on_event(&swipe, 2.01).is_empty(), "a repeated message is not a second swipe");
    assert_eq!(c.status().gestures, 1);
    assert_eq!(c.status().last_gesture, Some("swipe left"));
    assert_eq!(c.status().last_action.as_deref(), Some(LEFT));
}

#[test]
fn nothing_runs_before_the_band_is_live_or_while_paused() {
    let mut c = Controls::new(Options::default(), profiles(vec![swipes()]));
    assert!(runs(&gesture(&mut c, "thumb", "left", 1, 0.5)).is_empty());
    c.on_event(&Event::Connected, 1.0);
    assert_eq!(toggles(&c.pause()), [false]);
    assert!(c.status().paused);
    assert!(runs(&gesture(&mut c, "thumb", "left", 2, 2.0)).is_empty());
    assert_eq!(toggles(&c.resume(3.0)), [true]);
    let out = c.on_event(&Event::Gesture(message("thumb", "left", 3, 2.9)), 3.0);
    assert!(runs(&out).is_empty(), "input from before resuming never acts");
    assert_eq!(runs(&gesture(&mut c, "thumb", "right", 4, 3.5)), [RIGHT]);
}

#[test]
fn without_autostart_controls_start_paused() {
    let mut c = live_with(Options { autostart: false, ..Options::default() }, profiles(vec![swipes()]));
    assert!(c.status().paused);
    assert!(runs(&gesture(&mut c, "thumb", "up", 1, 2.0)).is_empty());
    assert_eq!(toggles(&c.toggle(3.0)), [true]);
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 2, 3.5)), [UP]);
}

#[test]
fn stale_gestures_never_act() {
    let mut c = live(profiles(vec![swipes()]));
    let out = c.on_event(&Event::Gesture(message("thumb", "left", 1, 1.0)), 2.0);
    assert!(runs(&out).is_empty());
}

#[test]
fn the_dial_steps_volume_both_ways() {
    let mut c = with_hand(Hand::Right);
    let up = runs(&pinch(&mut c, "index", turn_dir(), DEGREES, 2.0, true));
    assert_only(&up, VOLUME_UP);
    assert_eq!(c.status().last_gesture, Some("wrist turn +"));
    let down = runs(&pinch(&mut c, "index", turn_dir().map(|v| -v), DEGREES, 4.0, true));
    assert_only(&down, VOLUME_DOWN);
    assert_eq!(c.status().last_gesture, Some("wrist turn \u{2212}"));
}

#[test]
fn the_left_hand_reverses_the_dial() {
    let mut c = with_hand(Hand::Left);
    let ran = runs(&pinch(&mut c, "index", turn_dir(), DEGREES, 2.0, true));
    assert_only(&ran, VOLUME_DOWN);
}

#[test]
fn the_dial_waits_for_a_confirmed_hand() {
    let mut c = live(profiles(vec![dial_profile()]));
    assert!(runs(&pinch(&mut c, "index", turn_dir(), DEGREES, 2.0, true)).is_empty());
}

/// The dial target (and its status) is platform state now: the platform sets the dial's
/// actions, or none. The Linux `cycle_dial` / `status.dial` checks are dropped.
#[test]
fn the_dial_target_can_be_switched_or_turned_off() {
    let mut c = with_hand(Hand::Right);
    c.set_dial(None);
    assert!(runs(&pinch(&mut c, "index", turn_dir(), DEGREES, 2.0, true)).is_empty());
    c.set_dial(dial("bri-up", "bri-down"));
    let ran = runs(&pinch(&mut c, "index", turn_dir(), DEGREES, 3.0, true));
    assert_only(&ran, "bri-up");
}

#[test]
fn releasing_a_wrist_turn_is_not_an_index_tap() {
    let mut c = with_hand(Hand::Right);
    // Released at 2.85.
    assert!(!runs(&pinch(&mut c, "index", turn_dir(), DEGREES, 2.0, true)).is_empty());
    assert!(runs(&gesture(&mut c, "index", "doubletap", 1, 3.05)).is_empty());
    assert_eq!(runs(&gesture(&mut c, "middle", "doubletap", 2, 3.05)), [MUTE]);
    assert_eq!(runs(&gesture(&mut c, "index", "doubletap", 3, 4.05)), [PLAY]);
}

#[test]
fn a_configured_hand_is_written_once_after_connecting() {
    let mut c = live_with(hand(HandSetting::Left), profiles(vec![swipes()]));
    assert_eq!(c.on_event(&Event::Handedness(Hand::Right), 1.5), [Output::SetHand(Hand::Left)]);
    // The band still reports Right: one automatic retry, then no more.
    assert_eq!(c.on_event(&Event::Handedness(Hand::Right), 1.6), [Output::SetHand(Hand::Left)]);
    assert!(c.on_event(&Event::Handedness(Hand::Right), 1.7).is_empty());
    assert!(c.on_event(&Event::Handedness(Hand::Left), 2.0).is_empty());
    assert_eq!(c.status().hand, Some(Hand::Left));
}

#[test]
fn a_lost_hand_request_is_retried_once() {
    let mut c = with_hand(Hand::Right);
    assert_eq!(c.request_hand(Hand::Left), [Output::SetHand(Hand::Left)]);
    // A second request while the first is still outstanding: the controls themselves
    // don't dedupe (a real session would refuse it as busy).
    assert_eq!(c.request_hand(Hand::Left), [Output::SetHand(Hand::Left)]);
    // The band still reports Right — the write never took. One automatic retry.
    assert_eq!(c.on_event(&Event::Handedness(Hand::Right), 2.0), [Output::SetHand(Hand::Left)]);
    // No further retries once one has already been used.
    assert!(c.on_event(&Event::Handedness(Hand::Right), 3.0).is_empty());
}

#[test]
fn a_disconnect_stops_everything_until_the_next_connect() {
    let mut c = live(profiles(vec![swipes()]));
    c.on_disconnect();
    assert!(runs(&gesture(&mut c, "thumb", "left", 1, 2.0)).is_empty());
    c.on_event(&Event::Connected, 3.0);
    assert_eq!(runs(&gesture(&mut c, "thumb", "left", 2, 3.5)), [LEFT]);
}

#[test]
fn battery_reports_update_the_status() {
    let mut c = live(profiles(vec![swipes()]));
    c.on_event(&Event::BatteryStatus(Some(BatteryStatus { level: 42, charging: Some(true) })), 2.0);
    assert_eq!((c.status().battery, c.status().charging), (Some(42), Some(true)));
    c.on_event(&Event::BatteryStatus(None), 3.0);
    assert_eq!((c.status().battery, c.status().charging), (Some(42), None));
}

#[test]
fn a_stale_hand_is_forgotten_on_reconnect() {
    let mut c = live(profiles(vec![swipes()]));
    c.on_event(&Event::Handedness(Hand::Right), 1.0);
    c.on_disconnect();
    assert!(c.set_options(hand(HandSetting::Left)).is_empty());
    assert!(c.on_event(&Event::Connected, 3.0).is_empty());
    assert_eq!(c.on_event(&Event::Handedness(Hand::Right), 3.5), [Output::SetHand(Hand::Left)]);
}

#[test]
fn an_explicit_hand_request_overrides_the_config_until_it_reloads() {
    let mut c = live_with(hand(HandSetting::Left), profiles(vec![swipes()]));
    assert!(c.on_event(&Event::Handedness(Hand::Left), 1.0).is_empty());
    assert_eq!(c.request_hand(Hand::Right), [Output::SetHand(Hand::Right)]);
    assert!(c.on_event(&Event::Handedness(Hand::Right), 1.5).is_empty());
}

fn with_index_tap() -> Controls<String> {
    live(profiles(vec![profile("p", &[(Gesture::IndexTap, run(DIAL_TOGGLE)), (Gesture::IndexDouble, run(PLAY))])]))
}

#[test]
fn an_index_tap_waits_out_its_double_tap_then_runs() {
    let mut c = with_index_tap();
    assert!(runs(&gesture(&mut c, "index", "tap", 1, 2.0)).is_empty());
    let due = c.next_deadline().expect("the tap is held");
    assert!(c.poll(due - 0.01).is_empty());
    assert_eq!(runs(&c.poll(due)), [DIAL_TOGGLE]);
    assert!(c.next_deadline().is_none());
    assert!(c.poll(due + 1.0).is_empty(), "runs once");
}

/// On the band a double tap is: tap, then ~0.3 s later tap + doubletap at once.
#[test]
fn a_double_tap_runs_only_its_own_action() {
    let mut c = with_index_tap();
    assert!(gesture(&mut c, "index", "tap", 1, 2.0).is_empty());
    assert!(gesture(&mut c, "index", "tap", 2, 2.3).is_empty());
    assert_eq!(runs(&gesture(&mut c, "index", "doubletap", 3, 2.3)), [PLAY]);
    assert!(c.next_deadline().is_none());
    assert!(c.poll(5.0).is_empty());
}

#[test]
fn a_tap_without_a_double_tap_action_runs_at_once() {
    let mut c = live(profiles(vec![profile("p", &[(Gesture::IndexTap, run(DIAL_TOGGLE))])]));
    assert_eq!(runs(&gesture(&mut c, "index", "tap", 1, 2.0)), [DIAL_TOGGLE]);
    assert!(c.next_deadline().is_none());
}

#[test]
fn a_disconnect_drops_a_held_tap() {
    let mut c = with_index_tap();
    gesture(&mut c, "index", "tap", 1, 2.0);
    c.on_disconnect();
    assert!(c.poll(5.0).is_empty());
}

/// `toggle = MiddleTriple`: the middle triple tap is the band control for controls on/off. The
/// `on_toggle` hook is the platform's now; the engine reports `Output::Controls`.
fn with_toggle_tap() -> Controls<String> {
    live(with_band(
        profiles(vec![profile("p", &[(Gesture::SwipeLeft, run(LEFT)), (Gesture::MiddleDouble, run(MUTE))])]),
        band(Some(Gesture::MiddleTriple), None, None),
    ))
}

/// On the band: tap; tap + doubletap ~0.25 s later; tap (+ maybe doubletap).
fn middle_triple(c: &mut Controls<String>, sequence: u64, at: f64) -> Vec<Output<String>> {
    let mut out = gesture(c, "middle", "tap", sequence, at);
    out.extend(gesture(c, "middle", "tap", sequence + 1, at + 0.25));
    out.extend(gesture(c, "middle", "doubletap", sequence + 2, at + 0.25));
    out.extend(gesture(c, "middle", "tap", sequence + 3, at + 0.5));
    out.extend(gesture(c, "middle", "doubletap", sequence + 4, at + 0.5));
    out
}

#[test]
fn a_triple_tap_toggles_the_controls_even_while_off() {
    let mut c = with_toggle_tap();
    let out = middle_triple(&mut c, 1, 2.0);
    assert_eq!(toggles(&out), [false]);
    assert!(runs(&out).is_empty());
    // The last gesture is the real gesture's label now ("triple tap" on Linux).
    assert_eq!(c.status().last_gesture, Some("middle triple tap"));
    assert!(c.status().paused);
    assert!(c.poll(10.0).is_empty(), "no mute from the triple");
    // Off: other gestures do nothing, but the triple tap still turns it back on.
    assert!(runs(&gesture(&mut c, "thumb", "left", 10, 5.0)).is_empty());
    let out = middle_triple(&mut c, 20, 6.0);
    assert_eq!(toggles(&out), [true]);
    assert!(runs(&out).is_empty());
    assert!(!c.status().paused);
}

#[test]
fn the_toggle_fingers_double_tap_waits_for_a_possible_third_tap() {
    let mut c = with_toggle_tap();
    gesture(&mut c, "middle", "tap", 1, 2.0);
    gesture(&mut c, "middle", "tap", 2, 2.25);
    assert!(runs(&gesture(&mut c, "middle", "doubletap", 3, 2.25)).is_empty());
    let due = c.next_deadline().expect("the double tap is held");
    assert_eq!(runs(&c.poll(due)), [MUTE]);
    assert!(!c.status().paused);
}

/// Changed on purpose: on Linux a slow triple tap (no band double taps in it) also ran the
/// single tap. The shared engine holds a single tap for the whole triple, so it doesn't.
#[test]
fn a_slow_toggle_triple_runs_no_single_tap() {
    let mut c = live(with_band(
        profiles(vec![profile("p", &[(Gesture::IndexTap, run("play"))])]),
        band(Some(Gesture::IndexTriple), None, None),
    ));
    let mut out = Vec::new();
    // 0.38 s apart: too slow for the band's own double tap, quick enough for a triple.
    out.extend(gesture(&mut c, "index", "tap", 1, 2.0));
    out.extend(c.poll(2.3));
    out.extend(gesture(&mut c, "index", "tap", 2, 2.38));
    out.extend(c.poll(2.7));
    out.extend(gesture(&mut c, "index", "tap", 3, 2.76));
    out.extend(c.poll(4.0));
    assert!(runs(&out).is_empty());
    assert_eq!(toggles(&out), [false]);
}

#[test]
fn slow_taps_are_not_a_triple_tap() {
    let mut c = with_toggle_tap();
    for (sequence, at) in [(1, 2.0), (2, 2.6), (3, 3.2)] {
        gesture(&mut c, "middle", "tap", sequence, at);
    }
    assert!(!c.status().paused);
}

/// `toggle = MiddleHold`: the middle hold is the band control for controls on/off. (On Linux the
/// test also set `middle_hold = "never-runs"` to show the toggle wins; a band control wins
/// over any profile action, see `controls_band.rs`.)
fn with_hold_toggle() -> Controls<String> {
    live(with_band(
        profiles(vec![profile("p", &[(Gesture::MiddleDouble, run(MUTE))])]),
        band(Some(Gesture::MiddleHold), None, None),
    ))
}

#[test]
fn a_middle_hold_toggles_the_controls_even_while_off() {
    let mut c = with_hold_toggle();
    let out = gesture(&mut c, "middle", "hold", 1, 2.0);
    assert_eq!(toggles(&out), [false]);
    assert!(runs(&out).is_empty());
    assert!(c.status().paused);
    assert!(toggles(&gesture(&mut c, "middle", "hold", 2, 2.3)).is_empty(), "one toggle per hold");
    assert_eq!(toggles(&gesture(&mut c, "middle", "hold", 3, 4.0)), [true]);
    assert!(!c.status().paused);
}

#[test]
fn with_a_hold_toggle_the_middle_double_tap_runs_at_once() {
    let mut c = with_hold_toggle();
    gesture(&mut c, "middle", "tap", 1, 2.0);
    gesture(&mut c, "middle", "tap", 2, 2.25);
    assert_eq!(runs(&gesture(&mut c, "middle", "doubletap", 3, 2.25)), [MUTE]);
}
