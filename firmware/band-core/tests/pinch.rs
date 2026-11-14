mod recordings;

use band_core::controls::{Finger, Palm};
use band_core::controls::pinch::{Class, Drag, GyroBias, MAX_DT, Pinch, Prototypes, State, Step, from_forearm};
use recordings::{Line, read, step_at};

/// Each index/middle pinch of a recording, replayed: (step text, finger, what it became).
fn replay(name: &str) -> Vec<(String, String, State)> {
    let lines = read(name);
    let p = Prototypes::right_hand();
    let mut bias = GyroBias::default();
    let mut last_stamp: Option<u64> = None;
    let mut quat: Option<[f32; 4]> = None;
    let mut pinch: Option<(String, Pinch)> = None;
    let mut out = Vec::new();
    for line in &lines {
        match line {
            Line::Quat { q, .. } => quat = Some(*q),
            Line::Gyro { t, stamp, raw } => {
                let dt = last_stamp.map(|s| (*stamp as f64 - s as f64) / 1e6);
                last_stamp = Some(*stamp);
                let Some(dt) = dt.filter(|dt| *dt > 0.0 && *dt <= MAX_DT) else { continue };
                match &mut pinch {
                    None => bias.learn(*raw, dt),
                    Some((_, pinch)) => {
                        let _ = pinch.feed(bias.rate(*raw), dt, *t, &p);
                    }
                }
            }
            Line::Gesture { t, finger, action, synthetic: false, .. } if finger == "index" || finger == "middle" => {
                if action == "press" && pinch.is_none() {
                    let which = if finger == "index" { Finger::Index } else { Finger::Middle };
                    pinch = Some((finger.clone(), Pinch::new(which, *t, p.roll_for(quat), Palm::Down)));
                } else if action == "release" && pinch.as_ref().is_some_and(|(f, _)| f == finger) {
                    let (f, done) = pinch.take().expect("checked");
                    out.push((step_at(&lines, done.pressed_at()), f, done.state()));
                }
            }
            _ => {}
        }
    }
    out
}

fn expected(step: &str) -> Option<Class> {
    for (word, class) in [
        ("TURN", Class::Turn),
        ("DRAG RIGHT", Class::Drag(Drag::Right)),
        ("DRAG LEFT", Class::Drag(Drag::Left)),
        ("DRAG TOWARD", Class::Drag(Drag::Toward)),
        ("DRAG AWAY", Class::Drag(Drag::Away)),
        ("DRAG UP", Class::Drag(Drag::Up)),
        ("DRAG DOWN", Class::Drag(Drag::Down)),
    ] {
        if step.contains(word) {
            return Some(class);
        }
    }
    None
}

#[test]
fn the_recorded_turns_and_drags_classify_as_measured() {
    let mut right = 0;
    let mut misses = Vec::new();
    for name in ["rec7-turn-and-drags.log", "rec8-drags-up-down.log"] {
        for (step, finger, state) in replay(name) {
            let want = expected(&step).expect("every pinch here is a turn or a drag");
            if state == State::Decided(want) {
                right += 1;
            } else {
                misses.push(format!("{name} {finger} {step}: {state:?}"));
            }
        }
    }
    assert_eq!(right + misses.len(), 28, "{misses:?}");
    assert!(right >= 26, "{misses:?}");
}

#[test]
fn holding_still_never_decides_and_turning_does() {
    let (mut holds, mut turns) = (0, 0);
    for (step, finger, state) in replay("rec1-holds-turns-palm.log") {
        // A stray pinch of the other finger (one index pinch at the start of step 9) isn't the
        // step's move.
        let named = if step.contains("MIDDLE") { Some("middle") } else if step.contains("INDEX") { Some("index") } else { None };
        if named.is_some_and(|f| f != finger) {
            continue;
        }
        if step.contains("HOLD STILL") || step.contains("hold still 3 s") {
            assert_eq!(state, State::Undecided, "{finger} {step}");
            holds += 1;
        }
        if step.contains("TURN right away") || step.contains("THEN turn") {
            assert_eq!(state, State::Decided(Class::Turn), "{finger} {step}");
            turns += 1;
        }
    }
    assert_eq!((holds, turns), (12, 8));
}

#[test]
fn a_decided_turn_reports_its_amount_then_steps() {
    let p = Prototypes::right_hand();
    let mut pinch = Pinch::new(Finger::Middle, 0.0, p.palm_down_roll, Palm::Down);
    let rate = from_forearm(p.turn.map(|v| -80.0 * v), p.palm_down_roll);
    let mut steps = Vec::new();
    for i in 1..=60 {
        steps.push(pinch.feed(rate, 0.01, f64::from(i) * 0.01, &p));
    }
    let decided = steps.iter().find_map(|s| match s { Step::Decided { class, amount } => Some((*class, *amount)), _ => None });
    let (class, amount) = decided.expect("decided");
    assert_eq!(class, Class::Turn);
    assert!(amount < -14.0, "a negative turn: {amount}");
    assert!(steps.iter().any(|s| matches!(s, Step::Moved(d) if *d < 0.0)));
}
