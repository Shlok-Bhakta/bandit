# Changelog

## Unreleased

- An update status the band never answers (`ota_status`) is given up after 5 s, as the other
  requests are, so haptics no longer stop until a reconnect.

## 0.5.0

- `controls`: the gesture layer both apps used to keep in their own controllers. Its parts:
  - single, double and triple taps, and the hold;
  - the pinch-and-turn dial;
  - controls on/off;
  - handedness;
  - profiles: an app's own profile, next/previous, and a call layer on top;
  - a practice mode that reports without acting.

  Band controls: Controls on/off, Next profile and Previous profile sit on one gesture each
  (`Profiles::band`), above every profile, the call layer and an app's own profile.
  `BandControls::standard()` puts them on the middle hold, the index triple tap and the
  middle triple tap, and Draw on the index hold (all in every position). Profiles and the
  call layer hold `Binding`s (an action, with optional palm overrides); an action on a
  band-control gesture is kept but doesn't run (`Profiles::paused`, `Profiles::uses`).
  The warnings, `NoControls` and `NoWayOut`, are for the whole set.
  A slow triple tap no longer runs its finger's single tap first, whatever the triple does.
- Writing in a text field (`Controls::set_writing`, `writing`), apart from practice: gestures
  are reported for editing (each followed by `Unused::Writing`) and nothing acts but the
  Controls on/off band control, so the middle hold turns the controls off while writing;
  no runs, dial or slider steps, next, previous or Draw. With the controls off nothing is
  for editing (`Unused::ControlsOff`). `Controls::writes` (writing, the controls on, the band
  live) says whether handwritten symbols type: the apps drop what `take_written` gives while
  it's false. Writing wins over practice; teaching drags and an open draw session keep their
  own rules.
- The pinch: index and middle each have a hold, a dial (turn) and six drags (left, right,
  toward, away, up, down) as gestures or sliders (`FingerSetup`, `DragMode`). A pinch is the
  hold when let go before 15° of movement; the hold acts at the band's hold message when the
  finger's dial and drags do nothing. Drags are read in the forearm frame from
  `Event::Motion` / `Event::Orientation`, against prototypes measured on the owner's band.
- What each gesture did, exactly, for "gesture · palm → what it did": `Output::Gesture` is
  `{ gesture, palm }` (the palm it was resolved in); a gesture that did nothing is followed by
  `Output::Unused { gesture, why }` (`Unused::{Unbound, ControlsOff, Paused(Builtin), TooSoon,
  Teaching, Drawing}`); a pinch that stepped a dial or slider ends with `Output::PinchEnded {
  finger, class, palm, up, down, practiced }` when let go or dropped (too old, paused, a draw
  session or drag teaching starting; its steps still come as `Run`s, or `Practiced`);
  `ControlStatus::last_palm`. `pinch::Class` is exported as `controls::Class`. Without a fresh
  orientation the pen is taken to be palm down.
- Palm down and up the right way round (2026-10-26): the right hand's defaults are palm down
  −11.3°, palm up −142.3° (`palm::RIGHT_PALM_DOWN_ROLL`, `RIGHT_PALM_UP_ROLL`); the recording
  they came from had its palm-down and palm-up steps labelled the wrong way round. A pinch
  with no orientation is read palm down. Drags taught before without a calibration carry the
  old value as their `palm_down_roll` (`palm::SWAPPED_RIGHT_PALM_DOWN_ROLL`): read them as
  taught at palm down. Drawings come out the right way up: `draw::project` is the old
  projection turned over, in a fixed frame (`draw::FRAME_ROLL`); it and `Session::motion` no
  longer take a palm-down roll. Templates taught before are upside down: turned over
  (every point negated) they match again, exactly for those taught without a palm
  calibration (Linux does this when it loads them); teach a drawing again if it still
  doesn't match well.
- Palm position: `Palm::{Down, Side, Up}` from the band's roll about the forearm against a
  `PalmCalibration` (right-hand defaults measured; the left hand has none until calibrated,
  so it's always palm down). Each gesture binds a `Binding` (a normal action plus up to two
  palm overrides); band controls can be limited to positions (`PalmSet`). A gesture's palm is
  the one at its press; a triple's is its first tap's.
- Drawings: `Builtin::Draw` opens a drawing session where any pinch is the pen, in the air or
  pen-grip on a table; it ends 1 s after the last stroke and matches the user's taught
  drawings ($P recogniser, `controls::draw`), running the drawing's action (a profile's own,
  else the shared one). The strokes keep their places (the hand's movement between them); a
  tap or a pinch the band lost isn't a stroke. `Output::DrawPoint` feeds a live pad; teaching
  reports the strokes and `draw::check_tries` / `Library::looks_like` check them.
  `Controls::start_drawing` / `cancel_drawing` open and close a session from the app; Draw on
  a triple tap or a drag can't cancel its session (`Invalid::DrawCantCancel`; a hold can't
  either, but isn't shown as wrong), and
  on a single tap a short pinch cancels it (`Warning::DrawOnTap`).
- Teach your drags: `Controls::set_drag_teaching` reports each pinch's direction
  (`Output::DragSample`) and acts on nothing; `Prototypes::taught` builds a hand's prototypes
  from one sample per direction, refusing lookalikes.
- `Controls::set_calibration` swaps the palm calibration and taught drags. The apps keep one
  of each per band and hand and pass the ones for the band and hand now in use, e.g. after a
  hand change. Unlike `set_options` it keeps the hand (a runtime one from `request_hand`
  too) and any request for it, and writes nothing to the band. The palm is read afresh from
  the last orientation. Any change of the drag directions or the palm calibration in effect
  (this, `set_options`, the band reporting another hand) loses a pinch in progress, as if
  its motion stopped; a still finger's hold still comes.
- `Controls::palm`: the palm position now (down without a fresh orientation or a
  calibration).
- For the apps' UI: `Output::Pen { down }` tells the pad when the pen goes down and up (a
  dropped stroke too), and `Profiles::hold_waits` says whether a finger's hold waits for the
  release in a profile and palm position: the engine's own rule, without its runtime dial,
  turns-only drags, the call layer or an app holding its profile.
- The simulated band (`Responder`) sends 3-axis gyro and orientation (`gyro3`,
  `orientation`), as `SimBand` does.
- A band busy with another device now says so, instead of "Missing protobuf integer".

## 0.4.0

- One band-core for both apps. Until now Linux and Android each kept a copy. This one
  starts from the Android copy, which already had:
  - firmware updates and the band's handwriting stream (by David Ljung Madison Stellar);
  - the newer-firmware record padding;
  - the stream probe;
  - the ACTIVE state on every connect.
- `BandSession::write_config` from the Linux copy: it writes a `ConfigReq`, to put back
  settings the band keeps across connections.
