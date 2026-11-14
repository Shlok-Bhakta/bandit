use super::*;

fn vectors(dir: &str) -> Vec<(String, String)> {
    let path = format!("{}/tests/{dir}", env!("CARGO_MANIFEST_DIR"));
    let mut files: Vec<_> = std::fs::read_dir(&path).unwrap().map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "json")).collect();
    files.sort();
    files.into_iter().map(|p| (p.file_name().unwrap().to_string_lossy().into_owned(), std::fs::read_to_string(&p).unwrap())).collect()
}

#[test]
fn the_built_in_profiles_are_valid_and_do_what_the_dongle_did() {
    let set = ProfileSet::builtin();
    let ids: Vec<_> = set.profiles.iter().map(|p| p.id.as_str()).collect();
    assert_eq!(ids, ["media", "slides", "write", "copilot", "tv"]);
    let media = &set.profiles[0];
    assert_eq!(media.action(Gesture::MiddleDoubleTap, HostKind::Phone), Some(&Action::PhoneMute));
    assert_eq!(media.action(Gesture::MiddleDoubleTap, HostKind::Windows),
               Some(&Action::Key(Chord { modifiers: modifiers::GUI | modifiers::SHIFT, usage: 0x10 })));
    assert_eq!(media.action(Gesture::IndexHold, HostKind::Mac), Some(&Action::Menu));
    assert_eq!(media.action(Gesture::SwipeUp, HostKind::Mac), None);
    let write = &set.profiles[2];
    assert!(write.types(HostKind::Linux) && write.points(HostKind::Mac) && !write.types(HostKind::Phone));
    assert_eq!(write.action(Gesture::SwipeDown, HostKind::Mac), Some(&Action::Scroll(-4)));
    let copilot = &set.profiles[3];
    assert_eq!(copilot.action(Gesture::MiddleHold, HostKind::Mac), Some(&Action::Hold(Chord { modifiers: modifiers::ALT, usage: 0x2C })));
    assert_eq!(copilot.action(Gesture::SwipeRight, HostKind::Mac), Some(&Action::Key(Chord { modifiers: modifiers::GUI | modifiers::SHIFT, usage: 0x30 })));
    assert_eq!(copilot.action(Gesture::SwipeUp, HostKind::Mac), Some(&Action::Key(Chord { modifiers: modifiers::GUI, usage: 0x34 })));
    assert_eq!(set.start_for(HostKind::Tv), 4);
    assert_eq!(set.start_for(HostKind::Phone), 0);
    assert_eq!(set.menu.get(&'w'), Some(&Action::Profile(ProfileTarget::Index(2))));
    assert_eq!(set.menu.get(&'l'), Some(&Action::Host(HostTarget::Next)));
    assert!(!set.profiles[1].allows(HostKind::Phone));
    // Only the dial or the pointer need wrist motion: a profile with neither never turns it on.
    assert!(media.uses_motion(HostKind::Phone) && write.uses_motion(HostKind::Mac) && !write.uses_motion(HostKind::Phone));
}

#[test]
fn every_valid_vector_parses() {
    for (name, text) in vectors("valid") {
        ProfileSet::parse(&text).unwrap_or_else(|e| panic!("{name}: {e}"));
    }
}

#[test]
fn every_invalid_vector_fails_where_expected() {
    let expected = std::fs::read_to_string(format!("{}/tests/invalid/expected.tsv", env!("CARGO_MANIFEST_DIR"))).unwrap();
    let expected: BTreeMap<&str, &str> = expected.lines().filter_map(|l| l.split_once('\t')).collect();
    let files = vectors("invalid");
    assert_eq!(files.len(), expected.len(), "every invalid vector has an expected path");
    for (name, text) in files {
        let error = ProfileSet::parse(&text).expect_err(&name);
        assert_eq!(error.path, expected[name.as_str()], "{name}: {error}");
    }
}

#[test]
fn the_everything_vector_resolves_by_host() {
    let set = ProfileSet::parse(&vectors("valid").into_iter().find(|(n, _)| n == "everything.json").unwrap().1).unwrap();
    let music = &set.profiles[0];
    assert_eq!(music.action(Gesture::MiddleHold, HostKind::Phone), Some(&Action::Media(Media::Voice)));
    assert_eq!(music.action(Gesture::MiddleHold, HostKind::Windows), Some(&Action::Hold(Chord { modifiers: modifiers::ALT, usage: 0x2C })));
    // An exact kind beats "computer".
    assert_eq!(music.action(Gesture::MiddleHold, HostKind::Mac),
               Some(&Action::Hold(Chord { modifiers: modifiers::GUI | modifiers::SHIFT, usage: 0x2C })));
    // "none" as the default: a TV gets nothing.
    assert_eq!(music.action(Gesture::MiddleHold, HostKind::Tv), None);
    assert_eq!(music.action(Gesture::MiddleTripleTap, HostKind::Mac), None);
    assert_eq!(music.max_taps(Finger::Index, HostKind::Mac), 3);
    assert_eq!(music.action(Gesture::SwipeUp, HostKind::Phone), Some(&Action::Call(Call::Answer)));
    assert_eq!(music.action(Gesture::SwipeDown, HostKind::Phone), Some(&Action::Call(Call::End)));
    assert_eq!(music.action(Gesture::SwipeUp, HostKind::Mac), None);
    assert_eq!(music.max_taps(Finger::Middle, HostKind::Mac), 2, "middle.tripleTap is bound to none");
    let desk = &set.profiles[1];
    assert_eq!(desk.action(Gesture::SwipeUp, HostKind::Mac), Some(&Action::Scroll(10)));
    assert_eq!(desk.action(Gesture::MiddleTap, HostKind::Mac), Some(&Action::Key(Chord { modifiers: modifiers::GUI | modifiers::SHIFT, usage: 0x2E })));
    assert_eq!(desk.action(Gesture::IndexTap, HostKind::Mac), Some(&Action::Key(Chord { modifiers: 0, usage: 0x45 })));
    assert_eq!(set.start_for(HostKind::Linux), 1);
    assert_eq!(set.step(1, true, HostKind::Phone), Some(0), "desk isn't for a phone, music is");
    assert_eq!(set.menu.get(&'5'), Some(&Action::Type("hello".into())));
    assert_eq!(desk.action(Gesture::IndexTripleTap, HostKind::Mac), Some(&Action::Write(15)));
    assert_eq!(set.menu.get(&'w'), Some(&Action::Write(WRITE_SECONDS)));
    // Apps: any case; only for a host the profile allows.
    assert_eq!(set.for_app("com.google.chrome", HostKind::Mac), Some(1));
    assert_eq!(set.for_app("org.mozilla.firefox", HostKind::Phone), None);
    assert_eq!(set.for_app("com.apple.Notes", HostKind::Mac), None);
}

#[test]
fn chords() {
    assert_eq!(parse_chord("cmd+shift+]"), Ok(Chord { modifiers: modifiers::GUI | modifiers::SHIFT, usage: 0x30 }));
    assert_eq!(parse_chord("ctrl+alt+delete"), Ok(Chord { modifiers: modifiers::CTRL | modifiers::ALT, usage: 0x4C }));
    assert_eq!(parse_chord("+"), Ok(Chord { modifiers: modifiers::SHIFT, usage: 0x2E }));
    assert_eq!(parse_chord("Option+F5"), Ok(Chord { modifiers: modifiers::ALT, usage: 0x3E }));
    assert_eq!(parse_chord("A"), Ok(Chord { modifiers: modifiers::SHIFT, usage: 0x04 }));
    assert!(parse_chord("cmd+").is_err());
    assert!(parse_chord("hyper+a").is_err());
    assert!(parse_chord("f13").is_err());
}

#[test]
fn files_over_the_limit_are_refused() {
    let big = format!("{{\"format\":\"np-profiles\",\"version\":1,\"name\":\"{}\",\"profiles\":[]}}", " ".repeat(MAX_BYTES));
    assert!(ProfileSet::parse(&big).unwrap_err().message.contains("too big"));
}

#[test]
fn files_nested_too_deep_are_refused_before_parsing() {
    let deep = format!("{{\"format\":\"np-profiles\",\"version\":1,\"name\":\"x\",\"profiles\":[{}1{}]}}", "[".repeat(120), "]".repeat(120));
    assert!(ProfileSet::parse(&deep).unwrap_err().message.contains("nested"));
    // Brackets in strings don't count.
    let quoted = format!("{{\"format\":\"np-profiles\",\"version\":1,\"name\":\"{}\\\"{}\",\"profiles\":[]}}", "[".repeat(40), "{".repeat(40));
    assert!(!ProfileSet::parse(&quoted).unwrap_err().message.contains("nested"));
    assert!(nesting(DEFAULT_JSON) <= 5);
}

#[test]
fn a_double_tap_with_only_doubles_bound_acts_at_once() {
    let mut taps = Taps::default();
    // The band: singleTap, then singleTap and doubleTap together.
    assert_eq!(taps.tap(Finger::Index, false, 0.0, 2), None);
    assert_eq!(taps.tap(Finger::Index, false, 0.25, 2), Some(2));
    assert_eq!(taps.tap(Finger::Index, true, 0.25, 2), None, "the band's doubleTap is the same tap");
    assert!(taps.poll(1.0).is_empty());
}

#[test]
fn a_lone_doubletap_message_still_counts() {
    let mut taps = Taps::default();
    assert_eq!(taps.tap(Finger::Middle, true, 5.0, 2), Some(2));
}

#[test]
fn a_single_tap_waits_when_doubles_are_bound_too() {
    let mut taps = Taps::default();
    assert_eq!(taps.tap(Finger::Index, false, 0.0, 2), None);
    assert!(taps.poll(0.3).is_empty());
    assert_eq!(taps.poll(0.5), vec![(Finger::Index, 1)]);
}

#[test]
fn triple_taps() {
    let mut taps = Taps::default();
    assert_eq!(taps.tap(Finger::Index, false, 0.0, 3), None);
    assert_eq!(taps.tap(Finger::Index, false, 0.25, 3), None);
    assert_eq!(taps.tap(Finger::Index, true, 0.25, 3), None);
    assert_eq!(taps.tap(Finger::Index, false, 0.5, 3), Some(3));
    // Two taps with a triple bound: the double comes once the window passes.
    assert_eq!(taps.tap(Finger::Middle, false, 2.0, 3), None);
    assert_eq!(taps.tap(Finger::Middle, false, 2.2, 3), None);
    assert_eq!(taps.tap(Finger::Middle, true, 2.2, 3), None);
    assert_eq!(taps.poll(2.7), vec![(Finger::Middle, 2)]);
}

#[test]
fn single_taps_alone_act_at_once_and_fingers_are_separate() {
    let mut taps = Taps::default();
    assert_eq!(taps.tap(Finger::Index, false, 0.0, 1), Some(1));
    assert_eq!(taps.tap(Finger::Index, false, 0.2, 1), Some(1));
    assert_eq!(taps.tap(Finger::Index, true, 0.2, 1), None);
    assert_eq!(taps.tap(Finger::Middle, false, 0.3, 0), None, "nothing bound");
}

#[test]
fn a_hold_is_not_a_tap() {
    let mut taps = Taps::default();
    assert_eq!(taps.tap(Finger::Index, false, 0.0, 2), None);
    taps.hold(Finger::Index);
    assert_eq!(taps.tap(Finger::Index, false, 0.5, 2), None, "while held");
    taps.release(Finger::Index, 2.0);
    assert_eq!(taps.tap(Finger::Index, false, 2.1, 1), None, "as it lets go");
    assert!(taps.poll(3.0).is_empty());
    assert_eq!(taps.tap(Finger::Index, false, 3.0, 1), Some(1));
}

#[test]
fn buzz_patterns() {
    assert_eq!(parse_pattern("250 _200 250*90"), Ok(vec![
        Pulse { at_ms: 0, ms: 250, strength: DEFAULT_STRENGTH }, Pulse { at_ms: 450, ms: 250, strength: 90 }]));
    assert_eq!(pattern_ms(&parse_pattern("250 _200 250*90").unwrap()), 700);
    assert_eq!(Pulse { at_ms: 0, ms: 1, strength: 100 }.amplitude(), 255);
    assert_eq!(Pulse { at_ms: 0, ms: 1, strength: 63 }.amplitude(), 161);
    for bad in ["", "_100 200", "200 _100", "200 _100 _100 200", "10", "2001", "200*0", "200*101", "200x", "-5", "200 _5000 200",
                "2000 _100 2000 _100 2000 _100 2000 _100 2000"] {
        assert!(parse_pattern(bad).is_err(), "{bad:?}");
    }
    for (name, text) in BUILTIN_BUZZES { assert!(parse_pattern(text).is_ok(), "{name}"); }
}

#[test]
fn band_events_name_what_the_band_says() {
    let swipe_in = Gesture::from_name("band.thumb.swipeIn").unwrap();
    assert_eq!(swipe_in.name(), "band.thumb.swipeIn");
    let Gesture::Band(event) = swipe_in else { panic!() };
    assert!(event.matches("thumb", "swipeIn", "unknown"));
    assert!(!event.matches("index", "swipeIn", "unknown"));
    assert_eq!(Gesture::from_name("band.wake").unwrap().name(), "band.wake");
    assert!(Gesture::from_name("band.pinky.tap").is_none() && Gesture::from_name("band.index.squeeze").is_none());
    let names: Vec<String> = BandEvent::of_message("index", "tap", "singleTap").into_iter().map(|e| Gesture::Band(e).name()).collect();
    assert_eq!(names, ["band.index.tap", "band.index.singleTap", "band.tap", "band.singleTap"]);
    assert_eq!(BandEvent::of_message("notApplicable", "wake", "unknown").len(), 1);
}

#[test]
fn the_buzzes_vector_resolves() {
    let set = ProfileSet::parse(&vectors("valid").into_iter().find(|(n, _)| n == "buzzes-and-flicks.json").unwrap().1).unwrap();
    let zap = parse_pattern("40*100 _60 40*100").unwrap();
    assert_eq!(set.feedback(Feedback::AlertQuestion), Some(&zap));
    assert_eq!(set.feedback(Feedback::Connected), None, "none is silent");
    // A file's pattern replaces the built-in one of the same name, everywhere it's used.
    assert_eq!(set.feedback(Feedback::AlertDone), Some(&parse_pattern("120 _80 120 _80 300*95").unwrap()));
    assert_eq!(set.feedback(Feedback::Refused), set.pattern("long").as_ref());
    assert_eq!(set.feedback(Feedback::Gesture), set.pattern("tick").as_ref());
    assert_eq!(set.menu.get(&'z'), Some(&Action::Buzz(zap.clone())));
    let car = &set.profiles[0];
    assert_eq!(car.buzz, set.pattern("rise").unwrap());
    assert_eq!(car.action(Gesture::FlickUp, HostKind::Phone), Some(&Action::Media(Media::VolumeUp)));
    assert_eq!(car.action(Gesture::FlickUp, HostKind::Mac), None);
    assert_eq!(car.buzz(Gesture::FlickLeft), Some(&zap));
    assert_eq!(car.buzz(Gesture::FlickRight), None);
    assert!(car.uses_motion(HostKind::Phone) && car.flicks(HostKind::Phone));
    assert_eq!(car.band_events().count(), 4);
    assert_eq!(car.action(Gesture::from_name("band.wake").unwrap(), HostKind::Phone), None);
    let desk = &set.profiles[1];
    assert_eq!(desk.buzz, set.pattern("triple").unwrap());
    assert_eq!(desk.action(Gesture::FlickRight, HostKind::Mac), Some(&Action::Apps(true)));
    assert!(!desk.flicks(HostKind::Mac), "a pointer profile's pinch moves the pointer");
    assert_eq!(set.profiles[2].buzz, set.pattern("tap").unwrap(), "null is the default");
}
