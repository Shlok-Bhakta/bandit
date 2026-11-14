#![allow(dead_code)]
//! The owner's recordings (2026-10-25): one line per sample or gesture message,
//! `<t> motion gyro <band µs> <x> <y> <z>`, `<t> motion quat <band µs> <w> <x> <y> <z>`,
//! `<t> G <finger> <action> <derived> seq=… band_us=… syn=…`, `<t> STEP <text>`.

#[derive(Debug, Clone, PartialEq)]
pub enum Line {
    Gyro { t: f64, stamp: u64, raw: [f64; 3] },
    Quat { t: f64, q: [f32; 4] },
    Gesture { t: f64, finger: String, action: String, derived: String, synthetic: bool, sequence: u64, band_us: u64 },
    Step { t: f64, text: String },
}

pub fn read(name: &str) -> Vec<Line> {
    let path = format!("{}/tests/fixtures/recordings/{name}", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    text.lines().filter_map(parse).collect()
}

fn parse(line: &str) -> Option<Line> {
    let p: Vec<&str> = line.split_whitespace().collect();
    let t: f64 = p.first()?.parse().ok()?;
    match (p.get(1).copied()?, p.get(2).copied()) {
        ("motion", Some("gyro")) => Some(Line::Gyro {
            t,
            stamp: p.get(3)?.parse().ok()?,
            raw: [p.get(4)?.parse().ok()?, p.get(5)?.parse().ok()?, p.get(6)?.parse().ok()?],
        }),
        ("motion", Some("quat")) => Some(Line::Quat {
            t,
            q: [p.get(4)?.parse().ok()?, p.get(5)?.parse().ok()?, p.get(6)?.parse().ok()?, p.get(7)?.parse().ok()?],
        }),
        ("G", Some(finger)) => Some(Line::Gesture {
            t,
            finger: finger.into(),
            action: (*p.get(3)?).into(),
            derived: (*p.get(4)?).into(),
            synthetic: p.contains(&"syn=true"),
            sequence: field(&p, "seq=").unwrap_or(0),
            band_us: field(&p, "band_us=").unwrap_or(0),
        }),
        ("STEP", _) => Some(Line::Step { t, text: p.get(2..)?.join(" ") }),
        _ => None,
    }
}

fn field(p: &[&str], key: &str) -> Option<u64> {
    p.iter().find_map(|w| w.strip_prefix(key))?.parse().ok()
}

/// The text of the step running at `t`.
pub fn step_at(lines: &[Line], t: f64) -> String {
    lines.iter().rev().find_map(|l| match l { Line::Step { t: s, text } if *s <= t => Some(text.clone()), _ => None }).unwrap_or_default()
}
