//! The owner's drawings (rec2 in the air, rec6 pen grip on a table) through the $P recogniser.

mod recordings;

use band_core::controls::draw::{self, Drawing, Library, Stroke, TeachError, check_tries, distance, prepare};
use band_core::controls::pinch::{GyroBias, MAX_DT, Prototypes};
use band_core::controls::{Controls, Options, Output, Profile, Profiles};
use band_core::events::{Event, GestureMessage, Hand};
use recordings::{Line, read, step_at};

/// A pinch of a recording as a stroke: its label (from the step at its press; a pinch made
/// during "Get ready" is labelled by the step it was released in), press time, duration and points.
#[derive(Debug, Clone)]
struct Recorded {
    label: String,
    at: f64,
    secs: f64,
    stroke: Stroke,
}

fn label(step: &str) -> &'static str {
    for word in ["CIRCLE", "LIGHTBULB", "CHECK", "STAR", "Z"] {
        if step.contains(&format!(" {word}")) {
            return word;
        }
    }
    "?"
}

/// Each non-synthetic index/middle press → release of at least 0.3 s.
fn strokes(name: &str) -> Vec<Recorded> {
    let lines = read(name);
    let p = Prototypes::right_hand();
    let mut bias = GyroBias::default();
    let mut last_stamp: Option<u64> = None;
    let mut quat: Option<[f32; 4]> = None;
    // The finger, press time, roll and points of the pinch being drawn.
    let mut pen: Option<(String, f64, f64, Stroke)> = None;
    let mut out = Vec::new();
    for line in &lines {
        match line {
            Line::Quat { q, .. } => quat = Some(*q),
            Line::Gyro { stamp, raw, .. } => {
                let dt = last_stamp.map(|s| (*stamp as f64 - s as f64) / 1e6);
                last_stamp = Some(*stamp);
                let Some(dt) = dt.filter(|dt| *dt > 0.0 && *dt <= MAX_DT) else { continue };
                match &mut pen {
                    None => bias.learn(*raw, dt),
                    Some((_, _, roll, points)) => {
                        let step = bias.rate(*raw).map(|r| r * dt);
                        let [dx, dy] = draw::project(step, *roll);
                        let last = *points.last().expect("starts with a point");
                        points.push([last[0] + dx, last[1] + dy]);
                    }
                }
            }
            // A pinch the band ends with a synthetic release had no real release: not a stroke.
            Line::Gesture { finger, action, synthetic: true, .. } if action == "release" && pen.as_ref().is_some_and(|(f, ..)| f == finger) => {
                pen = None;
            }
            Line::Gesture { t, finger, action, synthetic: false, .. } if finger == "index" || finger == "middle" => {
                if action == "press" {
                    // Another press while a pinch is down: that one was never released.
                    pen = Some((finger.clone(), *t, p.roll_for(quat), vec![[0.0, 0.0]]));
                } else if action == "release" && pen.as_ref().is_some_and(|(f, ..)| f == finger) {
                    let (_, at, _, stroke) = pen.take().expect("checked");
                    let secs = t - at;
                    if secs >= 0.3 {
                        let mut step = step_at(&lines, at);
                        if step.starts_with("Get ready") {
                            step = step_at(&lines, *t);
                        }
                        let label = if step.starts_with("Get ready") { "Z" } else { label(&step) };
                        out.push(Recorded { label: label.to_owned(), at, secs, stroke });
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// The strokes with this label lasting at least `min_secs`.
fn pick(all: &[Recorded], label: &str, min_secs: f64) -> Vec<Stroke> {
    all.iter().filter(|r| r.label == label && r.secs >= min_secs).map(|r| r.stroke.clone()).collect()
}

fn dist(a: &Stroke, b: &Stroke) -> f64 {
    distance(&prepare(std::slice::from_ref(a)).expect("readable"), &prepare(std::slice::from_ref(b)).expect("readable"))
}

/// Labels, durations and pairwise distances, for the failure messages.
fn table(all: &[Recorded]) -> String {
    let clouds: Vec<_> = all.iter().map(|r| prepare(std::slice::from_ref(&r.stroke))).collect();
    let mut text = String::new();
    for (i, r) in all.iter().enumerate() {
        let row: Vec<String> = clouds
            .iter()
            .map(|other| match (&clouds[i], other) {
                (Some(a), Some(b)) => format!("{:5.2}", distance(a, b)),
                _ => "  -  ".into(),
            })
            .collect();
        text += &format!("\n{i:2} {:9} at {:6.3} for {:5.3} s: {}", r.label, r.at, r.secs, row.join(" "));
    }
    text
}

fn library(drawings: &[(&str, &Stroke)]) -> Library {
    let drawings: Vec<Drawing> =
        drawings.iter().map(|(name, stroke)| Drawing { name: (*name).into(), tries: vec![vec![(*stroke).clone()]] }).collect();
    Library::new(&drawings)
}

fn recognized(library: &Library, stroke: &Stroke) -> Option<String> {
    library.recognize(std::slice::from_ref(stroke), |_| true).map(|r| r.name)
}

#[test]
fn the_air_drawings_match_their_twins_and_not_other_shapes() {
    let all = strokes("rec2-air-drawings.log");
    let table = table(&all);
    // The 0.35 s accidental first circle is left out (strokes of 0.6 s or more).
    let shapes = ["Z", "CIRCLE", "CHECK", "LIGHTBULB", "STAR"].map(|label| (label, pick(&all, label, 0.6)));
    let counts: Vec<usize> = shapes.iter().map(|(_, s)| s.len()).collect();
    assert_eq!(counts, [2, 2, 2, 2, 1], "{table}");
    let [(_, z), (_, circle), _, (_, bulb), (_, star)] = &shapes;
    assert!(dist(&circle[0], &circle[1]) < 1.0, "{table}");
    assert!(dist(&bulb[0], &bulb[1]) < 1.3, "{table}");
    // z[0] is the get-ready pinch.
    assert!(dist(&z[0], &z[1]) < 1.3, "{table}");
    // Each twin is nearer its twin than any other shape.
    for (label, twins) in shapes.iter().filter(|(_, s)| s.len() == 2) {
        let twin = dist(&twins[0], &twins[1]);
        for (other, strokes) in shapes.iter().filter(|(other, _)| other != label) {
            for stroke in strokes {
                for mine in twins {
                    assert!(dist(mine, stroke) > twin, "{label} vs {other}: {table}");
                }
            }
        }
    }
    let lib = library(&[("circle", &circle[0]), ("lightbulb", &bulb[0]), ("z", &z[1]), ("star", &star[0])]);
    assert_eq!(recognized(&lib, &circle[1]).as_deref(), Some("circle"), "{table}");
    assert_eq!(recognized(&lib, &bulb[1]).as_deref(), Some("lightbulb"), "{table}");
    assert_eq!(recognized(&lib, &z[0]).as_deref(), Some("z"), "{table}");
}

#[test]
fn the_pen_grip_check_marks_match_and_its_zs_are_too_unlike_to_teach() {
    let all = strokes("rec6-table-pen-grip.log");
    let table = table(&all);
    // The second check mark was read as the middle finger and never released: not a stroke.
    let (z, check, bulb) = (pick(&all, "Z", 0.3), pick(&all, "CHECK", 0.3), pick(&all, "LIGHTBULB", 0.3));
    assert_eq!((z.len(), check.len(), bulb.len()), (3, 2, 1), "{table}");
    assert!(dist(&check[0], &check[1]) < draw::TEACH, "{table}");
    let lib = library(&[("check", &check[0]), ("lightbulb", &bulb[0])]);
    assert_eq!(recognized(&lib, &check[1]).as_deref(), Some("check"), "{table}");
    let tries: Vec<Vec<Stroke>> = z.iter().map(|s| vec![s.clone()]).collect();
    assert!(matches!(check_tries(&tries), Err(TeachError::NotAlike { .. })), "{table}");
}

#[test]
fn a_drawing_nearest_one_without_an_action_is_not_taken_for_an_allowed_one() {
    let all = strokes("rec2-air-drawings.log");
    let table = table(&all);
    let [z, circle, bulb, star] = ["Z", "CIRCLE", "LIGHTBULB", "STAR"].map(|label| pick(&all, label, 0.6));
    let lib = library(&[("circle", &circle[0]), ("lightbulb", &bulb[0]), ("z", &z[1]), ("star", &star[0])]);
    let only = |allowed: &str, stroke: &Stroke| lib.recognize(std::slice::from_ref(stroke), |name| name == allowed).map(|r| r.name);
    // The third circle is a circle, so not the z (its nearest allowed drawing) …
    assert_eq!(only("z", &circle[1]), None, "{table}");
    // … and the get-ready Z isn't the star.
    assert_eq!(only("star", &z[0]), None, "{table}");
    // Each is still itself where allowed.
    assert_eq!(only("circle", &circle[1]).as_deref(), Some("circle"), "{table}");
    assert_eq!(only("z", &z[0]).as_deref(), Some("z"), "{table}");
}

/// A recording through `Controls`: a draw session opened (`start_drawing`) at each press made
/// with none open, every line fed as its event; the strokes of every `DrawFinished`, in order.
fn session_strokes(name: &str) -> Vec<Stroke> {
    let lines = read(name);
    let mut c: Controls<String> = Controls::new(Options::default(), Profiles::single(Profile::new("a")));
    c.on_event(&Event::Connected, 0.0);
    c.on_event(&Event::Handedness(Hand::Right), 0.0);
    c.set_teaching(true);
    let mut out = Vec::new();
    let mut last = 0.0;
    for line in &lines {
        let t = match line {
            Line::Gyro { t, .. } | Line::Quat { t, .. } | Line::Gesture { t, .. } | Line::Step { t, .. } => *t,
        };
        last = t;
        if c.next_deadline().is_some_and(|due| due <= t) {
            out.extend(c.poll(t));
        }
        match line {
            Line::Gyro { stamp, raw, .. } => out.extend(c.on_event(&Event::Motion { timestamp_us: *stamp, gyro: *raw }, t)),
            Line::Quat { q, .. } => out.extend(c.on_event(&Event::Orientation(*q), t)),
            Line::Gesture { finger, action, derived, synthetic, sequence, band_us, .. } => {
                if !synthetic && (action == "press" || derived == "buttonPress") && !c.drawing() {
                    out.extend(c.start_drawing(t));
                }
                let message = GestureMessage {
                    sequence: *sequence,
                    timestamp_us: *band_us,
                    finger: finger.clone(),
                    action: action.clone(),
                    derived_action: derived.clone(),
                    synthetic: *synthetic,
                    received_at: t,
                };
                out.extend(c.on_event(&Event::Gesture(message), t));
            }
            Line::Step { .. } => {}
        }
    }
    out.extend(c.poll(last + 20.0));
    out.into_iter().filter_map(|o| match o { Output::DrawFinished { strokes } => Some(strokes), _ => None }).flatten().collect()
}

/// Each point less the stroke's first.
fn from_start(stroke: &Stroke) -> Stroke {
    stroke.iter().map(|p| [p[0] - stroke[0][0], p[1] - stroke[0][1]]).collect()
}

/// The recording's strokes as the session draws them: the same ones (a synthetic release, a
/// pinch never released and a tap aren't strokes), with nearly the same points (the session
/// doesn't learn the gyro bias between strokes; the fixture does).
fn assert_session_matches(name: &str) -> Vec<Recorded> {
    let fixture = strokes(name);
    let session = session_strokes(name);
    let table = table(&fixture);
    assert_eq!(session.len(), fixture.len(), "{name}: {table}");
    for (i, (mine, theirs)) in session.iter().zip(&fixture).enumerate() {
        let (mine, theirs) = (from_start(mine), from_start(&theirs.stroke));
        assert_eq!(mine.len(), theirs.len(), "{name} #{i}: points");
        let worst = mine.iter().zip(&theirs).map(|(a, b)| (a[0] - b[0]).hypot(a[1] - b[1])).fold(0.0, f64::max);
        assert!(worst < 0.5, "{name} #{i}: {worst:.3}° apart");
        assert!(dist(&mine, &theirs) < 0.2, "{name} #{i}: $P {:.3}", dist(&mine, &theirs));
    }
    fixture
}

#[test]
fn the_recordings_draw_the_same_strokes_through_the_session() {
    let air = assert_session_matches("rec2-air-drawings.log");
    assert_eq!(air.len(), 10);
    let table = assert_session_matches("rec6-table-pen-grip.log");
    assert_eq!(table.len(), 6);
    // The check mark after the middle finger's synthetic release is a stroke.
    assert!(table.iter().any(|r| (r.at - 44.30).abs() < 0.01 && (r.secs - 1.635).abs() < 0.01), "{table:?}");
}


/// How a stroke heads from `a` to `b`: (dx, dy) and its length.
fn leg(s: &Stroke, a: usize, b: usize) -> (f64, f64, f64) {
    let (dx, dy) = (s[b][0] - s[a][0], s[b][1] - s[a][1]);
    (dx, dy, dx.hypot(dy))
}

/// The owner's air Z's (rec2, y up as the pads draw it): top stroke left to right, the
/// diagonal down to the left, the bottom stroke left to right, below the top one. Not
/// upside down (as before 2026-10-26), not mirrored.
#[test]
fn the_air_zs_come_out_upright() {
    let zs: Vec<Recorded> = strokes("rec2-air-drawings.log").into_iter().filter(|r| r.label == "Z").collect();
    assert_eq!(zs.len(), 2);
    for z in &zs {
        let s = &z.stroke;
        let half = s.len() / 2;
        let right = (0..half).max_by(|&a, &b| s[a][0].total_cmp(&s[b][0])).expect("points");
        let left = (right..s.len()).min_by(|&a, &b| s[a][0].total_cmp(&s[b][0])).expect("points");
        let end = s.len() - 1;
        let (top, diagonal, bottom) = (leg(s, 0, right), leg(s, right, left), leg(s, left, end));
        assert!(top.0 > 10.0 && top.1.abs() < top.0 / 2.0, "top stroke left to right: {top:?} at {}", z.at);
        assert!(diagonal.0 < -10.0 && diagonal.1 < -3.0, "diagonal down to the left: {diagonal:?} at {}", z.at);
        assert!(bottom.0 > 10.0 && bottom.1.abs() < bottom.0 / 2.0, "bottom stroke left to right: {bottom:?} at {}", z.at);
        assert!(s[0][1].min(s[right][1]) > s[left][1].max(s[end][1]), "the top stroke sits above the bottom one at {}", z.at);
    }
}

/// The owner's air check marks (rec2): a short stroke down to the right, then a longer one up
/// to the right.
#[test]
fn the_air_check_marks_come_out_upright() {
    let checks: Vec<Recorded> = strokes("rec2-air-drawings.log").into_iter().filter(|r| r.label == "CHECK").collect();
    assert_eq!(checks.len(), 2);
    for check in &checks {
        let s = &check.stroke;
        let low = (0..s.len()).min_by(|&a, &b| s[a][1].total_cmp(&s[b][1])).expect("points");
        let (first, last) = (leg(s, 0, low), leg(s, low, s.len() - 1));
        assert!(first.0 > 3.0 && first.1 < -5.0, "down to the right first: {first:?} at {}", check.at);
        assert!(last.0 > 10.0 && last.1 > 5.0, "then up to the right: {last:?} at {}", check.at);
        assert!(last.2 > first.2, "the second stroke is the longer: {first:?} {last:?} at {}", check.at);
    }
}

/// The projection is the old one turned over (x → −x, y → −y): the same shapes the right way
/// up, so every $P distance (and the twins' tests above) stays as it was.
#[test]
fn the_projection_is_the_old_one_turned_over() {
    use band_core::controls::pinch::{from_forearm, to_forearm};
    let old = |step: [f64; 3], roll: f64| {
        let b = from_forearm(to_forearm(step, roll), -142.3);
        [-b[2], b[0]]
    };
    for step in [[1.0, 0.0, 0.0], [0.0, 0.0, 1.0], [0.3, -0.5, 0.8]] {
        for roll in [-142.3, -11.3, 2.3, 60.0] {
            let (was, now) = (old(step, roll), draw::project(step, roll));
            assert!((was[0] + now[0]).abs() < 1e-12 && (was[1] + now[1]).abs() < 1e-12, "{was:?} {now:?}");
        }
    }
}
