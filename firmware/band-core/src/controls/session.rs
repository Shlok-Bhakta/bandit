//! The draw session (the Draw band control, or `Controls::start_drawing`): every pinch is a
//! stroke. Its pen, strokes, cursor and timeouts; `Controls` feeds it presses, releases and
//! gyro steps, and matches and runs what it ends with.

use super::{HOLD_MIN, PINCH_MAX_AGE, draw};
use crate::controls::Finger;

/// The draw session ends this long after the last pen-up.
pub const DRAW_DONE: f64 = 1.0;
/// A draw session with no stroke for this long is cancelled.
pub const DRAW_IDLE: f64 = 10.0;

/// The pen of a draw session: a pinch being drawn.
#[derive(Debug, Clone)]
struct Pen {
    finger: Finger,
    pressed_at: f64,
    /// The pinch frame's roll at the press.
    roll: f64,
    stroke: draw::Stroke,
}

/// How a session ended by itself.
#[derive(Debug, Clone, PartialEq)]
pub enum Ended {
    /// Nothing was drawn.
    Cancelled,
    Finished(Vec<draw::Stroke>),
}

/// An open draw session.
#[derive(Debug, Clone)]
pub struct Session {
    strokes: Vec<draw::Stroke>,
    /// The stroke being drawn (the pen is down).
    pen: Option<Pen>,
    started_at: f64,
    last_pen_up: Option<f64>,
    /// Where the hand points (degrees, as the strokes): it follows the pen's stroke, and with
    /// the pen up the hand's movement once a stroke exists, so the next stroke starts where
    /// the hand moved to.
    cursor: [f64; 2],
    /// The last pen's roll (the cursor's without a fresh orientation).
    roll: f64,
}

impl Session {
    pub fn new(now: f64) -> Self {
        // `roll` is only read once a stroke exists, and every stroke's press sets it.
        Self { strokes: Vec::new(), pen: None, started_at: now, last_pen_up: None, cursor: [0.0, 0.0], roll: 0.0 }
    }

    /// The pen is down.
    pub fn pen_down(&self) -> bool {
        self.pen.is_some()
    }

    /// The number of the stroke being drawn, or of the next one (strokes kept so far).
    pub fn stroke(&self) -> usize {
        self.strokes.len()
    }

    /// A press of `finger`, the pinch frame at `roll`: the pen goes down at the cursor, and
    /// that's the stroke's first point. The band sends each press twice: the pen's own finger
    /// again is nothing (`None`). The other finger's press while the pen is down: normally
    /// the band sends the pen's synthetic release first; this is the fallback for a lost
    /// release, so the unfinished stroke is dropped and the other finger is the pen.
    pub fn press(&mut self, finger: Finger, roll: f64, now: f64) -> Option<[f64; 2]> {
        match self.pen.as_ref().map(|pen| pen.finger) {
            Some(pen) if pen == finger => return None,
            Some(_) => self.drop_pen(now),
            None => {}
        }
        self.roll = roll;
        self.pen = Some(Pen { finger, pressed_at: now, roll, stroke: vec![self.cursor] });
        Some(self.cursor)
    }

    /// A release of `finger`: the pen's lets it go. Its stroke is kept unless it was a tap
    /// (shorter than `HOLD_MIN`) or the release is the band's synthetic one (it lost the
    /// pinch). Another finger's release is nothing.
    pub fn release(&mut self, finger: Finger, synthetic: bool, now: f64) {
        match self.pen.take() {
            Some(pen) if pen.finger != finger => self.pen = Some(pen),
            Some(pen) if !synthetic && now - pen.pressed_at >= HOLD_MIN => {
                self.strokes.push(pen.stroke);
                self.last_pen_up = Some(now);
            }
            Some(_) => self.drop_pen(now),
            None => {}
        }
    }

    /// A gyro step (band frame, degrees). With the pen down, the stroke's next point (its
    /// number and the point); with it up after a stroke, the cursor moves (at `fresh_roll`,
    /// else the last pen's roll).
    pub fn motion(&mut self, step: [f64; 3], fresh_roll: Option<f64>) -> Option<(usize, [f64; 2])> {
        let Some(pen) = &mut self.pen else {
            if !self.strokes.is_empty() {
                let [dx, dy] = draw::project(step, fresh_roll.unwrap_or(self.roll));
                self.cursor = [self.cursor[0] + dx, self.cursor[1] + dy];
            }
            return None;
        };
        let [dx, dy] = draw::project(step, pen.roll);
        let [x, y] = *pen.stroke.last().expect("starts with a point");
        let point = [x + dx, y + dy];
        pen.stroke.push(point);
        self.cursor = point;
        Some((self.strokes.len(), point))
    }

    /// The band's clock skipped (the caller's `MOTION_LOST` or more) after a sample at
    /// `previous_at`: a pen pressed by then has unknown motion, its stroke is dropped.
    pub fn gap(&mut self, previous_at: f64, now: f64) {
        if self.pen.as_ref().is_some_and(|pen| previous_at >= pen.pressed_at) {
            self.drop_pen(now);
        }
    }

    /// Its timeouts: a pen down for `PINCH_MAX_AGE` is dropped; at the deadline it ends,
    /// with its strokes or cancelled with none.
    pub fn expire(&mut self, now: f64) -> Option<Ended> {
        if self.pen.as_ref().is_some_and(|pen| now - pen.pressed_at >= PINCH_MAX_AGE) {
            self.drop_pen(now);
        }
        if now < self.deadline() {
            return None;
        }
        Some(if self.strokes.is_empty() { Ended::Cancelled } else { Ended::Finished(std::mem::take(&mut self.strokes)) })
    }

    /// When it ends by itself: the pen dropped `PINCH_MAX_AGE` after its press, else
    /// `DRAW_DONE` after the last pen-up, else cancelled `DRAW_IDLE` after it started.
    pub fn deadline(&self) -> f64 {
        match (&self.pen, self.last_pen_up) {
            (Some(pen), _) => pen.pressed_at + PINCH_MAX_AGE,
            (None, Some(up)) if !self.strokes.is_empty() => up + DRAW_DONE,
            (None, _) => self.started_at + DRAW_IDLE,
        }
    }

    /// The pen's stroke is dropped (a tap, the band's synthetic release, another finger's
    /// press, a gap in the motion, too old): the pen is up. Before the first stroke the
    /// cursor goes back to the start.
    fn drop_pen(&mut self, now: f64) {
        self.pen = None;
        self.last_pen_up = Some(now);
        if self.strokes.is_empty() {
            self.cursor = [0.0, 0.0];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A pen at the drawing frame's roll: `step` draws `[dx, dy]` (see `draw::project`).
    const DOWN: f64 = draw::FRAME_ROLL;

    fn step([dx, dy]: [f64; 2]) -> [f64; 3] {
        [-dy, 0.0, dx]
    }

    /// The pen down at `at`, `n` steps of `[dx, dy]`, let go at `up`.
    fn stroke(s: &mut Session, finger: Finger, at: f64, d: [f64; 2], n: usize, up: f64) {
        s.press(finger, DOWN, at);
        for _ in 0..n {
            s.motion(step(d), None);
        }
        s.release(finger, false, up);
    }

    /// A point to 1e-9 (the frame's rotation isn't exact in floating point).
    fn round([x, y]: [f64; 2]) -> [f64; 2] {
        [(x * 1e9).round() / 1e9, (y * 1e9).round() / 1e9]
    }

    fn finished(s: &mut Session, now: f64) -> Vec<draw::Stroke> {
        match s.expire(now) {
            Some(Ended::Finished(strokes)) => strokes.into_iter().map(|stroke| stroke.into_iter().map(round).collect()).collect(),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_press_and_release_is_a_stroke_and_it_finishes_after_draw_done() {
        let mut s = Session::new(0.0);
        assert_eq!(s.press(Finger::Index, DOWN, 1.0), Some([0.0, 0.0]));
        assert_eq!(s.press(Finger::Index, DOWN, 1.01), None, "the band's second press");
        assert_eq!(s.motion(step([1.0, 0.0]), None).map(|(n, p)| (n, round(p))), Some((0, [1.0, 0.0])));
        s.release(Finger::Middle, false, 1.2);
        assert!(s.pen_down(), "another finger's release");
        s.release(Finger::Index, false, 1.5);
        assert!(!s.pen_down());
        assert_eq!(s.deadline(), 1.5 + DRAW_DONE);
        assert_eq!(s.expire(2.4), None);
        assert_eq!(finished(&mut s, 2.5), [vec![[0.0, 0.0], [1.0, 0.0]]]);
    }

    #[test]
    fn a_tap_and_a_synthetic_release_drop_the_stroke() {
        let mut s = Session::new(0.0);
        stroke(&mut s, Finger::Index, 1.0, [1.0, 0.0], 3, 1.2);
        assert_eq!(s.stroke(), 0, "a tap");
        s.press(Finger::Middle, DOWN, 2.0);
        s.motion(step([1.0, 0.0]), None);
        s.release(Finger::Middle, true, 2.5);
        assert!(!s.pen_down() && s.stroke() == 0, "the band lost it");
        assert_eq!(s.expire(DRAW_IDLE), Some(Ended::Cancelled));
    }

    #[test]
    fn the_other_fingers_press_takes_over_the_pen() {
        let mut s = Session::new(0.0);
        s.press(Finger::Middle, DOWN, 1.0);
        s.motion(step([5.0, 0.0]), None);
        // Its first point is the start again: the dropped stroke was the first.
        assert_eq!(s.press(Finger::Index, DOWN, 1.5), Some([0.0, 0.0]));
        s.motion(step([0.0, 2.0]), None);
        s.release(Finger::Middle, false, 1.8);
        s.release(Finger::Index, false, 2.0);
        assert_eq!(finished(&mut s, 3.0), [vec![[0.0, 0.0], [0.0, 2.0]]]);
    }

    #[test]
    fn the_cursor_moves_with_the_pen_up_once_a_stroke_exists() {
        let mut s = Session::new(0.0);
        // Before any stroke the hand's movement isn't the drawing's.
        s.motion(step([3.0, 3.0]), None);
        stroke(&mut s, Finger::Index, 1.0, [2.0, 0.0], 5, 1.5);
        s.motion(step([0.0, 4.0]), None);
        assert_eq!(s.press(Finger::Index, DOWN, 1.8).map(round), Some([10.0, 4.0]));
        s.motion(step([1.0, 0.0]), None);
        s.release(Finger::Index, false, 2.2);
        let strokes = finished(&mut s, 3.2);
        assert_eq!(strokes[1], [[10.0, 4.0], [11.0, 4.0]]);
    }

    #[test]
    fn a_gap_after_the_press_drops_the_stroke() {
        let mut s = Session::new(0.0);
        s.press(Finger::Index, DOWN, 1.0);
        s.gap(0.9, 1.1);
        assert!(s.pen_down(), "the gap ended before the press");
        s.gap(1.2, 1.6);
        assert!(!s.pen_down());
    }

    #[test]
    fn expire_drops_an_old_pen_and_cancels_an_idle_session() {
        let mut s = Session::new(0.0);
        s.press(Finger::Index, DOWN, 1.0);
        assert_eq!(s.deadline(), 1.0 + PINCH_MAX_AGE);
        assert_eq!(s.expire(1.0 + PINCH_MAX_AGE), Some(Ended::Cancelled));
        let mut s = Session::new(0.0);
        assert_eq!(s.expire(DRAW_IDLE - 0.1), None);
        assert_eq!(s.expire(DRAW_IDLE), Some(Ended::Cancelled));
    }
}
