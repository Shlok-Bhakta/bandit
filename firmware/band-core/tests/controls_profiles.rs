mod controls_common;

use std::collections::BTreeMap;

use band_core::controls::{
    BandControl, BandControls, Binding, Builtin, CallBinding, DragMode, Finger, Gesture, Invalid, Palm, PalmSet, Palms, PausedSlider,
    Place, Profile, Profiles, Warning,
};

fn named(name: &str, bindings: &[(Gesture, String)]) -> Profile<String> {
    let mut profile = Profile::new(name);
    profile.gestures.extend(bindings.iter().cloned().map(|(g, a)| (g, Binding::from(a))));
    profile
}

fn list(profiles: Vec<Profile<String>>) -> Profiles<String> {
    let (apps, calls) = (BTreeMap::new(), BTreeMap::new());
    Profiles { band: BandControls::default(), list: profiles, picked: 0, apps, calls, drawings: BTreeMap::new() }
}

#[test]
fn keys_and_labels_are_the_contract_with_both_apps() {
    let triples: Vec<(Gesture, &str, &str)> = Gesture::ALL.iter().map(|&g| (g, g.key(), g.label())).collect();
    assert_eq!(
        triples,
        [
            (Gesture::SwipeLeft, "swipe_left", "swipe left"),
            (Gesture::SwipeRight, "swipe_right", "swipe right"),
            (Gesture::SwipeUp, "swipe_up", "swipe up"),
            (Gesture::SwipeDown, "swipe_down", "swipe down"),
            (Gesture::IndexTap, "index_tap", "index tap"),
            (Gesture::IndexDouble, "index_double", "index double tap"),
            (Gesture::IndexTriple, "index_triple", "index triple tap"),
            (Gesture::IndexHold, "index_hold", "index hold"),
            (Gesture::MiddleTap, "middle_tap", "middle tap"),
            (Gesture::MiddleDouble, "middle_double", "middle double tap"),
            (Gesture::MiddleTriple, "middle_triple", "middle triple tap"),
            (Gesture::MiddleHold, "middle_hold", "middle hold"),
            (Gesture::IndexDragLeft, "index_drag_left", "index drag left"),
            (Gesture::IndexDragRight, "index_drag_right", "index drag right"),
            (Gesture::IndexDragToward, "index_drag_toward", "index drag toward"),
            (Gesture::IndexDragAway, "index_drag_away", "index drag away"),
            (Gesture::IndexDragUp, "index_drag_up", "index drag up"),
            (Gesture::IndexDragDown, "index_drag_down", "index drag down"),
            (Gesture::MiddleDragLeft, "middle_drag_left", "middle drag left"),
            (Gesture::MiddleDragRight, "middle_drag_right", "middle drag right"),
            (Gesture::MiddleDragToward, "middle_drag_toward", "middle drag toward"),
            (Gesture::MiddleDragAway, "middle_drag_away", "middle drag away"),
            (Gesture::MiddleDragUp, "middle_drag_up", "middle drag up"),
            (Gesture::MiddleDragDown, "middle_drag_down", "middle drag down"),
        ]
    );
    assert_eq!(Gesture::ALL.len(), 24);
    for gesture in Gesture::ALL {
        assert_eq!(Gesture::from_key(gesture.key()), Some(gesture));
    }
    assert_eq!(Gesture::from_key("index_turn"), None);
}

#[test]
fn an_apps_own_profile_wins_over_the_picked_one() {
    let mut profiles = list(vec![named("a", &[]), named("b", &[]), named("c", &[])]);
    profiles.picked = 1;
    profiles.apps.insert("org.videolan.vlc".into(), 2);
    assert_eq!(profiles.active(None), 1);
    assert_eq!(profiles.active(Some("com.example.other")), 1);
    assert_eq!(profiles.active(Some("org.videolan.vlc")), 2);
    assert_eq!(profiles.held_by(Some("org.videolan.vlc")), Some("org.videolan.vlc"));
    assert_eq!(profiles.held_by(Some("com.example.other")), None);
}

#[test]
fn out_of_range_indexes_fall_back_to_the_picked_or_first_profile() {
    let mut profiles = list(vec![named("a", &[]), named("b", &[])]);
    profiles.picked = 7;
    profiles.apps.insert("x".into(), 9);
    assert_eq!(profiles.active(Some("x")), 1);
    assert_eq!(profiles.held_by(Some("x")), None);
}

#[test]
fn the_call_layer_is_part_of_the_profiles() {
    use controls_common::{gesture, live, runs};
    let mut profiles = list(vec![named(
        "a",
        &[
            (Gesture::IndexDouble, "play".into()),
            (Gesture::MiddleTap, "mute".into()),
            (Gesture::SwipeUp, "launcher".into()),
        ],
    )]);
    profiles.calls.insert(Gesture::IndexDouble, CallBinding::Do(Binding::from("call.answer".to_string())));
    profiles.calls.insert(Gesture::MiddleTap, CallBinding::Nothing);
    profiles.calls.insert(Gesture::SwipeUp, CallBinding::AsUsual);
    let mut c = live(profiles);
    c.set_in_call(true);
    assert_eq!(runs(&gesture(&mut c, "index", "doubletap", 1, 1.0)), ["call.answer"]);
    assert!(runs(&gesture(&mut c, "middle", "tap", 2, 2.0)).is_empty());
    assert_eq!(runs(&gesture(&mut c, "thumb", "up", 3, 3.0)), ["launcher"]);
}

#[test]
fn builtin_keys_are_the_contract_with_both_apps() {
    for (builtin, key) in [
        (Builtin::Controls, "controls"),
        (Builtin::NextProfile, "next-profile"),
        (Builtin::PreviousProfile, "previous-profile"),
        (Builtin::Draw, "draw"),
    ] {
        assert_eq!(builtin.key(), key);
        assert_eq!(Builtin::from_key(key), Some(builtin));
    }
    assert_eq!(Builtin::from_key("@controls"), None);
    assert_eq!(Builtin::from_key("next_profile"), None);
}

/// Profile 0's middle finger is in sliders mode (left/right only), profile 1's in gestures mode,
/// profile 2's in sliders mode without a left/right slider; all bind the middle drag right.
fn sliders_and_gestures() -> Profiles<String> {
    let right = [(Gesture::MiddleDragRight, "x".to_string())];
    let mut a = named("a", &right);
    a.middle.drags = DragMode::Sliders([controls_common::dial("seek-fwd", "seek-back"), None, None]);
    let b = named("b", &right);
    let mut c = named("c", &right);
    c.middle.drags = DragMode::Sliders([None, controls_common::dial("zoom-in", "zoom-out"), None]);
    let mut profiles = list(vec![a, b, c]);
    profiles.band.controls = Some(BandControl::on(Gesture::MiddleDragLeft));
    profiles
}

#[test]
fn a_drag_entry_of_a_finger_in_sliders_mode_is_never_a_use() {
    let profiles = sliders_and_gestures();
    let places: Vec<Place> = profiles.uses(Gesture::MiddleDragRight).iter().map(|u| u.place).collect();
    assert_eq!(places, [Place::Profile(1)]);
}

#[test]
fn a_band_control_on_either_drag_of_a_pair_pauses_its_sliders() {
    let profiles = sliders_and_gestures();
    assert_eq!(
        profiles.paused_sliders(),
        [PausedSlider { builtin: Builtin::Controls, gesture: Gesture::MiddleDragLeft, profile: 0, finger: Finger::Middle, pair: 0, positions: Palms::from_iter(Palm::ALL) }]
    );
    // An unreachable band control (Controls wins on the gesture) pauses nothing of its own.
    let mut both = sliders_and_gestures();
    both.band.next = Some(BandControl::on(Gesture::MiddleDragLeft));
    assert_eq!(both.paused_sliders().len(), 1);
}

#[test]
fn a_paused_slider_says_where_its_band_control_wins() {
    let mut profiles = sliders_and_gestures();
    profiles.band.controls = Some(BandControl { gesture: Gesture::MiddleDragLeft, palm: PalmSet::Only([Palm::Up].into()) });
    assert_eq!(profiles.paused_sliders().iter().map(|p| p.positions).collect::<Vec<_>>(), [Palms::from_iter([Palm::Up])]);
    profiles.band.controls = None;
    assert!(profiles.paused_sliders().is_empty());
}

#[test]
fn a_band_control_limited_to_no_position_or_all_three_is_reported() {
    let mut profiles = list(vec![named("a", &[(Gesture::IndexTap, "x".to_string())])]);
    profiles.calls.insert(
        Gesture::SwipeUp,
        CallBinding::Do(Palm::ALL.into_iter().fold(Binding::from("y".to_string()), |b, palm| b.with(palm, Some("y".to_string())))),
    );
    profiles.band.controls = Some(BandControl { gesture: Gesture::MiddleHold, palm: PalmSet::Only([Palm::Up].into()) });
    profiles.band.next = Some(BandControl { gesture: Gesture::IndexTriple, palm: PalmSet::Only(Palm::ALL.into()) });
    profiles.band.previous = Some(BandControl { gesture: Gesture::MiddleTriple, palm: PalmSet::Only([].into()) });
    assert_eq!(
        profiles.invalid(),
        [
            Invalid::Binding { place: Place::Calls, gesture: Gesture::SwipeUp },
            Invalid::BandControl(Builtin::NextProfile),
            Invalid::BandControl(Builtin::PreviousProfile),
        ]
    );
    profiles.band.controls = Some(BandControl { gesture: Gesture::MiddleHold, palm: PalmSet::Only([Palm::Up, Palm::Down].into()) });
    profiles.band.next = None;
    profiles.band.previous = None;
    profiles.calls.clear();
    assert!(profiles.invalid().is_empty());
}

#[test]
fn controls_on_off_limited_to_no_position_is_no_controls() {
    let mut profiles = list(vec![named("a", &[])]);
    profiles.band.controls = Some(BandControl { gesture: Gesture::MiddleHold, palm: PalmSet::Only([].into()) });
    assert_eq!(profiles.warnings(), [Warning::NoControls]);
    profiles.band.controls = Some(BandControl { gesture: Gesture::MiddleHold, palm: PalmSet::Only([Palm::Side].into()) });
    assert!(profiles.warnings().is_empty());
}

#[test]
fn band_controls_are_copy_and_a_palm_set_holds_palms() {
    fn copy<T: Copy>(_: T) {}
    let controls = BandControls::standard();
    copy(controls);
    copy(controls);
    copy(BandControl { gesture: Gesture::MiddleHold, palm: PalmSet::Only([Palm::Up].into()) });
    let only = PalmSet::Only(Palms::from_iter([Palm::Up, Palm::Side]));
    assert!(only.contains(Palm::Side) && !only.contains(Palm::Down) && only.valid());
    assert!(!PalmSet::Only(Palms::default()).valid() && !PalmSet::Only(Palm::ALL.into()).valid());
}

#[test]
fn draw_is_the_fourth_band_control_on_the_index_hold_by_default() {
    assert_eq!(Builtin::ALL, [Builtin::Controls, Builtin::NextProfile, Builtin::PreviousProfile, Builtin::Draw]);
    assert_eq!(BandControls::standard().draw, Some(BandControl::on(Gesture::IndexHold)));
    assert!(BandControls::default().draw.is_none());
    let band = BandControls { draw: Some(BandControl::on(Gesture::MiddleDouble)), ..BandControls::default() };
    assert_eq!(band.control(Builtin::Draw).map(|c| c.gesture), Some(Gesture::MiddleDouble));
    assert_eq!(band.on(Gesture::MiddleDouble, Palm::Side), Some(Builtin::Draw));
}

#[test]
fn a_profiles_own_drawing_action_wins_over_the_shared_one() {
    let mut profiles = list(vec![named("a", &[]), named("b", &[])]);
    profiles.drawings.insert("circle".into(), "shared".to_string());
    profiles.list[1].drawings.insert("circle".into(), "own".to_string());
    profiles.list[1].drawings.insert("star".into(), "b-star".to_string());
    assert_eq!(profiles.drawing_action(0, "circle").map(String::as_str), Some("shared"));
    assert_eq!(profiles.drawing_action(1, "circle").map(String::as_str), Some("own"));
    assert_eq!(profiles.drawing_action(0, "star"), None);
    assert_eq!(profiles.drawing_action(1, "star").map(String::as_str), Some("b-star"));
    assert_eq!(profiles.drawing_action(5, "circle").map(String::as_str), Some("shared"));
}

/// `hold_waits` for both fingers in profile 0 with the palm down: `[index, middle]`.
fn waits(profiles: &Profiles<String>) -> [bool; 2] {
    [Finger::Index, Finger::Middle].map(|finger| profiles.hold_waits(0, finger, Palm::Down))
}

#[test]
fn a_hold_waits_for_the_release_when_the_fingers_dial_is_set() {
    let mut profiles = list(vec![named("a", &[(Gesture::IndexHold, "hold".into()), (Gesture::IndexTap, "tap".into())])]);
    assert_eq!(waits(&profiles), [false, false], "holds and taps aren't moves");
    profiles.list[0].index.dial = controls_common::dial("vol-up", "vol-down");
    assert_eq!(waits(&profiles), [true, false]);
    for palm in Palm::ALL {
        assert!(profiles.hold_waits(0, Finger::Index, palm), "{palm:?}");
    }
    profiles.list[0].index.dial = None;
    profiles.list[0].middle.dial = controls_common::dial("zoom-in", "zoom-out");
    assert_eq!(waits(&profiles), [false, true]);
}

#[test]
fn a_hold_waits_when_a_drag_gesture_has_an_action_in_that_palm() {
    let mut profiles = list(vec![named("a", &[])]);
    profiles.list[0].gestures.insert(Gesture::IndexDragUp, Binding::from("up".to_string()).with(Palm::Up, None));
    assert_eq!(waits(&profiles), [true, false]);
    assert!(profiles.hold_waits(0, Finger::Index, Palm::Side));
    assert!(!profiles.hold_waits(0, Finger::Index, Palm::Up), "nothing there");
    // Only an override: only there.
    profiles.list[0].gestures.insert(Gesture::IndexDragUp, Binding { normal: None, overrides: [(Palm::Up, Some("up".to_string()))].into() });
    assert!(profiles.hold_waits(0, Finger::Index, Palm::Up));
    assert!(!profiles.hold_waits(0, Finger::Index, Palm::Down));
}

#[test]
fn in_sliders_mode_a_hold_waits_for_a_slider_not_for_drag_gestures() {
    let mut profiles = list(vec![named("a", &[(Gesture::MiddleDragRight, "x".into())])]);
    profiles.list[0].middle.drags = DragMode::Sliders([None, None, None]);
    assert_eq!(waits(&profiles), [false, false], "a sliders-mode finger's drag entry never runs");
    profiles.list[0].middle.drags = DragMode::Sliders([None, controls_common::dial("zoom-in", "zoom-out"), None]);
    assert_eq!(waits(&profiles), [false, true]);
}

#[test]
fn a_reachable_band_control_on_a_drag_makes_its_fingers_hold_wait() {
    let mut profiles = list(vec![named("a", &[])]);
    profiles.band.controls = Some(BandControl { gesture: Gesture::IndexDragLeft, palm: PalmSet::Only([Palm::Up].into()) });
    assert_eq!(waits(&profiles), [false, false]);
    assert!(profiles.hold_waits(0, Finger::Index, Palm::Up));
    assert!(!profiles.hold_waits(0, Finger::Middle, Palm::Up));
    // Next on a drag pausing its pair's slider: with one profile next does nothing, so
    // neither drag of the pair does.
    let mut profiles = list(vec![named("a", &[])]);
    profiles.list[0].middle.drags = DragMode::Sliders([controls_common::dial("seek-fwd", "seek-back"), None, None]);
    profiles.band.next = Some(BandControl::on(Gesture::MiddleDragRight));
    assert_eq!(waits(&profiles), [false, false]);
    profiles.list.push(named("b", &[]));
    assert_eq!(waits(&profiles), [false, true]);
}

#[test]
fn hold_waits_is_per_profile_and_leaves_out_the_call_layer() {
    let mut profiles = list(vec![named("a", &[]), named("b", &[(Gesture::MiddleDragAway, "away".into())])]);
    profiles.calls.insert(Gesture::IndexDragUp, CallBinding::Do(Binding::from("call".to_string())));
    profiles.calls.insert(Gesture::MiddleDragAway, CallBinding::Nothing);
    assert_eq!(waits(&profiles), [false, false]);
    assert!(profiles.hold_waits(1, Finger::Middle, Palm::Down));
    assert!(!profiles.hold_waits(1, Finger::Index, Palm::Down));
    assert!(!profiles.hold_waits(2, Finger::Middle, Palm::Down), "no such profile");
}
