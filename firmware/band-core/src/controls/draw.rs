//! Drawings: strokes made with a pinch as the pen, matched with the $P point-cloud
//! recogniser (Vatavu, Anthony, Wobbrock 2012): resample to `POINTS`, normalise position and
//! size, then a greedy nearest-point matching. Order, direction and number of strokes don't
//! matter; the user's own drawings are the templates.

use crate::controls::pinch::{from_forearm, to_forearm};

pub const POINTS: usize = 32;
/// A match needs a $P distance under this.
pub const MATCH: f64 = 1.8;
/// …and the next other drawing must be at least this many times farther.
pub const LEAD: f64 = 1.25;
/// The tries of a drawing being taught must all be within this of each other.
pub const TEACH: f64 = 1.8;
/// A new drawing this close to an existing one looks like it.
pub const LIKE: f64 = 1.4;
/// A drawing smaller than this (degrees) both ways is too small to read.
pub const MIN_SPAN: f64 = 3.0;

/// One stroke: points in degrees (x right, y up).
pub type Stroke = Vec<[f64; 2]>;

/// The drawing frame: a stroke is the gyro's steps as the band would see them at this roll
/// about the forearm, x = z and y = −x of that frame (x right, y up). It's fixed, whatever the
/// hand's palm down or calibration: each stroke's own roll is taken out first (`to_forearm` at
/// its press), so this only says which way is up. Checked on the owner's air Z and check marks
/// (rec2, `tests/draw.rs`): upright and not mirrored, whether the hand is calibrated or not.
/// (Until 2026-10-26 the mapping was x = −z, y = x: the same frame turned over, and drawings
/// came out upside down on the pad.)
pub const FRAME_ROLL: f64 = -142.3;

/// A gyro step (band frame, degrees) as a drawing step, for a pinch at `roll` (see
/// `FRAME_ROLL`).
pub fn project(step: [f64; 3], roll: f64) -> [f64; 2] {
    let b = from_forearm(to_forearm(step, roll), FRAME_ROLL);
    [b[2], -b[0]]
}

/// A drawing ready to compare: `POINTS` points with their stroke number.
#[derive(Debug, Clone, PartialEq)]
pub struct Cloud(Vec<([f64; 2], usize)>);

/// Resampled and normalised; `None` for a drawing with no length or smaller than `MIN_SPAN`.
pub fn prepare(strokes: &[Stroke]) -> Option<Cloud> {
    let points: Vec<([f64; 2], usize)> =
        strokes.iter().enumerate().flat_map(|(id, s)| s.iter().map(move |p| (*p, id))).collect();
    let (min, max) = points.iter().fold(([f64::INFINITY; 2], [f64::NEG_INFINITY; 2]), |(lo, hi), (p, _)| {
        ([lo[0].min(p[0]), lo[1].min(p[1])], [hi[0].max(p[0]), hi[1].max(p[1])])
    });
    let span = (max[0] - min[0]).max(max[1] - min[1]);
    if !span.is_finite() || span < MIN_SPAN {
        return None;
    }
    let length: f64 = points.windows(2).filter(|w| w[0].1 == w[1].1).map(|w| dist(w[0].0, w[1].0)).sum();
    if length <= 0.0 {
        return None;
    }
    let step = length / (POINTS - 1) as f64;
    let mut out = vec![points[0]];
    let mut carried = 0.0;
    let mut previous = points[0];
    for &point in &points[1..] {
        if point.1 != previous.1 {
            previous = point;
            continue;
        }
        let mut from = previous.0;
        let mut d = dist(from, point.0);
        while carried + d >= step && out.len() < POINTS {
            let t = (step - carried) / d;
            let q = [from[0] + t * (point.0[0] - from[0]), from[1] + t * (point.0[1] - from[1])];
            out.push((q, point.1));
            from = q;
            d = dist(from, point.0);
            carried = 0.0;
        }
        carried += d;
        previous = point;
    }
    while out.len() < POINTS {
        out.push(*points.last().expect("not empty"));
    }
    // Same size (the larger side is 1), centred on the centroid.
    let scaled: Vec<([f64; 2], usize)> =
        out.iter().map(|(p, id)| ([(p[0] - min[0]) / span, (p[1] - min[1]) / span], *id)).collect();
    let n = scaled.len() as f64;
    let c = scaled.iter().fold([0.0, 0.0], |c, (p, _)| [c[0] + p[0] / n, c[1] + p[1] / n]);
    Some(Cloud(scaled.into_iter().map(|(p, id)| ([p[0] - c[0], p[1] - c[1]], id)).collect()))
}

fn dist(a: [f64; 2], b: [f64; 2]) -> f64 {
    (a[0] - b[0]).hypot(a[1] - b[1])
}

fn cloud_distance(a: &Cloud, b: &Cloud, start: usize) -> f64 {
    let n = a.0.len();
    let mut matched = [false; POINTS];
    let mut sum = 0.0;
    for k in 0..n {
        let i = (start + k) % n;
        let (j, best) = (0..n)
            .filter(|&j| !matched[j])
            .map(|j| (j, dist(a.0[i].0, b.0[j].0)))
            .min_by(|x, y| x.1.total_cmp(&y.1))
            .expect("one left");
        matched[j] = true;
        sum += (1.0 - k as f64 / n as f64) * best;
    }
    sum
}

/// The $P distance between two prepared drawings (smaller is more alike).
pub fn distance(a: &Cloud, b: &Cloud) -> f64 {
    let n = a.0.len();
    let step = (n as f64).sqrt() as usize;
    (0..n).step_by(step.max(1)).map(|i| cloud_distance(a, b, i).min(cloud_distance(b, a, i))).fold(f64::INFINITY, f64::min)
}

/// A taught drawing: its name and the tries it was taught with.
#[derive(Debug, Clone, PartialEq)]
pub struct Drawing {
    pub name: String,
    pub tries: Vec<Vec<Stroke>>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Library {
    drawings: Vec<(String, Vec<Cloud>)>,
}

/// What a drawing matched.
#[derive(Debug, Clone, PartialEq)]
pub struct Recognized {
    pub name: String,
    pub distance: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TeachError {
    /// A try is too small or has no length.
    TooSmall(usize),
    /// Two tries don't look alike (their distance).
    NotAlike { first: usize, second: usize, distance: f64 },
    /// No tries at all.
    NoTries,
}

impl Library {
    /// The drawings' readable tries. Drawings with the same name are one drawing, with all
    /// their tries (in the order first seen).
    pub fn new(drawings: &[Drawing]) -> Self {
        let mut library = Self::default();
        for drawing in drawings {
            let clouds = drawing.tries.iter().filter_map(|t| prepare(t));
            match library.drawings.iter_mut().find(|(name, _)| *name == drawing.name) {
                Some((_, own)) => own.extend(clouds),
                None => library.drawings.push((drawing.name.clone(), clouds.collect())),
            }
        }
        library
    }

    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.drawings.iter().map(|(name, _)| name.as_str())
    }

    /// The nearest drawing, if it's near enough, clearly nearer than the next other drawing and
    /// `allowed`. Every drawing competes (one without an action too): a drawing nearest one
    /// that isn't allowed is nothing, not the nearest allowed one.
    pub fn recognize(&self, strokes: &[Stroke], allowed: impl Fn(&str) -> bool) -> Option<Recognized> {
        let cloud = prepare(strokes)?;
        let mut scored: Vec<(f64, &str)> = self
            .drawings
            .iter()
            .filter(|(_, clouds)| !clouds.is_empty())
            .map(|(name, clouds)| (clouds.iter().map(|c| distance(&cloud, c)).fold(f64::INFINITY, f64::min), name.as_str()))
            .collect();
        scored.sort_by(|a, b| a.0.total_cmp(&b.0));
        let (best, name) = *scored.first()?;
        let lead = scored.get(1).is_none_or(|next| next.0 >= best * LEAD);
        (best < MATCH && lead && allowed(name)).then(|| Recognized { name: name.to_owned(), distance: best })
    }

    /// The existing drawing these tries look like, if any (for "looks like Circle").
    pub fn looks_like(&self, tries: &[Vec<Stroke>]) -> Option<String> {
        let clouds: Vec<Cloud> = tries.iter().filter_map(|t| prepare(t)).collect();
        self.drawings
            .iter()
            .filter_map(|(name, own)| {
                let d = clouds.iter().flat_map(|a| own.iter().map(move |b| distance(a, b))).fold(f64::INFINITY, f64::min);
                (d < LIKE).then_some((d, name))
            })
            .min_by(|a, b| a.0.total_cmp(&b.0))
            .map(|(_, name)| name.clone())
    }
}

/// Whether these tries (normally 3) can teach a drawing: at least one, each readable, all
/// alike.
pub fn check_tries(tries: &[Vec<Stroke>]) -> Result<(), TeachError> {
    if tries.is_empty() {
        return Err(TeachError::NoTries);
    }
    let mut clouds = Vec::new();
    for (i, t) in tries.iter().enumerate() {
        clouds.push(prepare(t).ok_or(TeachError::TooSmall(i))?);
    }
    for first in 0..clouds.len() {
        for second in first + 1..clouds.len() {
            let d = distance(&clouds[first], &clouds[second]);
            if d > TEACH {
                return Err(TeachError::NotAlike { first, second, distance: d });
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn circle(r: f64, start: f64, steps: usize) -> Stroke {
        (0..=steps).map(|i| {
            let a = start + i as f64 / steps as f64 * std::f64::consts::TAU;
            [r * a.cos(), r * a.sin()]
        }).collect()
    }

    fn zigzag(s: f64) -> Stroke {
        vec![[0.0, s], [s, s], [0.0, 0.0], [s, 0.0]]
    }

    #[test]
    fn the_same_shape_at_another_size_and_start_is_close() {
        let a = prepare(&[circle(10.0, 0.0, 60)]).unwrap();
        let b = prepare(&[circle(25.0, 1.0, 40)]).unwrap();
        assert!(distance(&a, &b) < 0.3, "{}", distance(&a, &b));
    }

    #[test]
    fn different_shapes_are_far() {
        let a = prepare(&[circle(10.0, 0.0, 60)]).unwrap();
        let z = prepare(&[zigzag(20.0)]).unwrap();
        assert!(distance(&a, &z) > MATCH, "{}", distance(&a, &z));
    }

    #[test]
    fn too_small_or_empty_is_not_a_drawing() {
        assert!(prepare(&[circle(1.0, 0.0, 30)]).is_none());
        assert!(prepare(&[vec![[0.0, 0.0]]]).is_none());
        assert!(prepare(&[]).is_none());
    }

    #[test]
    fn prepare_gives_the_fixed_number_of_points_over_several_strokes() {
        let cloud = prepare(&[vec![[0.0, 0.0], [10.0, 0.0]], vec![[0.0, 5.0], [10.0, 5.0]]]).unwrap();
        assert_eq!(cloud.0.len(), POINTS);
        assert!(cloud.0.iter().any(|(_, id)| *id == 1));
    }

    /// Where the strokes sit against each other is part of the drawing (the session lays them
    /// out with the movement between them).
    #[test]
    fn strokes_in_place_match_in_any_order_and_their_layout_tells_shapes_apart() {
        let (across, down) = (vec![[0.0, 5.0], [10.0, 5.0]], vec![[5.0, 10.0], [5.0, 0.0]]);
        let plus = prepare(&[across.clone(), down.clone()]).unwrap();
        let plus_other_way = prepare(&[down, across]).unwrap();
        assert!(distance(&plus, &plus_other_way) < 0.5, "{}", distance(&plus, &plus_other_way));
        let equals = prepare(&[vec![[0.0, 0.0], [10.0, 0.0]], vec![[0.0, 5.0], [10.0, 5.0]]]).unwrap();
        let minus = prepare(&[vec![[0.0, 0.0], [10.0, 0.0]]]).unwrap();
        assert!(distance(&equals, &minus) > MATCH, "{}", distance(&equals, &minus));
    }

    #[test]
    fn drawings_with_the_same_name_are_one_drawing() {
        let lib = Library::new(&[
            Drawing { name: "circle".into(), tries: vec![vec![circle(10.0, 0.0, 60)]] },
            Drawing { name: "z".into(), tries: vec![vec![zigzag(20.0)]] },
            Drawing { name: "circle".into(), tries: vec![vec![circle(12.0, 1.0, 60)]] },
        ]);
        assert_eq!(lib.names().collect::<Vec<_>>(), ["circle", "z"]);
        // Its two circles don't compete with each other for the lead.
        assert_eq!(lib.recognize(&[circle(15.0, 2.0, 50)], |_| true).map(|r| r.name), Some("circle".into()));
    }

    #[test]
    fn the_library_matches_only_allowed_drawings_near_enough() {
        let lib = Library::new(&[
            Drawing { name: "circle".into(), tries: vec![vec![circle(10.0, 0.0, 60)]] },
            Drawing { name: "z".into(), tries: vec![vec![zigzag(20.0)]] },
        ]);
        let drawn = [circle(15.0, 2.0, 50)];
        assert_eq!(lib.recognize(&drawn, |_| true).map(|r| r.name), Some("circle".into()));
        assert_eq!(lib.recognize(&drawn, |name| name == "z"), None);
    }

    #[test]
    fn teaching_needs_alike_readable_tries_and_spots_lookalikes() {
        assert_eq!(check_tries(&[vec![circle(10.0, 0.0, 60)], vec![circle(12.0, 1.0, 60)], vec![circle(9.0, 2.0, 60)]]), Ok(()));
        assert!(matches!(check_tries(&[vec![circle(10.0, 0.0, 60)], vec![zigzag(20.0)]]), Err(TeachError::NotAlike { .. })));
        assert_eq!(check_tries(&[vec![circle(1.0, 0.0, 60)]]), Err(TeachError::TooSmall(0)));
        assert_eq!(check_tries(&[]), Err(TeachError::NoTries));
        let lib = Library::new(&[Drawing { name: "circle".into(), tries: vec![vec![circle(10.0, 0.0, 60)]] }]);
        assert_eq!(lib.looks_like(&[vec![circle(20.0, 0.5, 60)]]), Some("circle".into()));
        assert_eq!(lib.looks_like(&[vec![zigzag(20.0)]]), None);
    }
}
