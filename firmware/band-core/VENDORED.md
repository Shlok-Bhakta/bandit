# Vendored band-core

Copied from https://gitlab.com/896kb/band-core at `4b59393` (2026-10-30, MIT, see LICENSE and
LICENSE-kinesis) so the dongle can carry fixes for updated band firmware (1054928927 and later).
Changes from upstream are listed below and marked `// bandit:` in the source.

- `session.rs` input: an unnamed frame shaped like an RPC answer is read as one even when the
  channel's last named kind was a log line or an error word (updated firmware sends those on the
  channels it answers on; the iPhone app (since retired) hit this switching handwriting on).
- `session.rs` `stream_request`: the band's handwriting asks for stream flags 22 and 23 with the
  model output (4), as kinesis and rokid-lumen do.
- `session.rs` power (for the dongle, worn all day): `without_motion` / `set_motion` turn gyro and
  orientation off and on without touching gestures (the same stream flags an update quiets);
  turning the band's handwriting off restores `ConfigReq` fields 13 and 21 (standby-related, which
  turning it on sets to 0) as the config read reported them.
- `dial.rs` `arm_held` (through `BandSession::arm_dial`): with motion off until a hold, the pinch
  dial arms on the band's own hold report once gyro starts, instead of only on a press that came
  with motion already flowing.
- Memory (for the dongle's ~100 KB heap; a burst of motion aborted it out of memory):
  `BandSession::feed_into` hands each event to a callback instead of collecting a record's
  events in one `Vec` (a record of a few KB of gyro was hundreds of 176-byte events, a 22–45 KB
  block); `Event`'s ceremony variants are boxed (an event is now a gesture's size); DataX frames
  are read one at a time (`DataXReceiver::push` / `next_frame`) and a frame claiming more than
  `MAX_FRAME` (8 KB) is an error instead of a wait; setup messages are capped at 2 KB, waiting
  diagnostics at 128 lines, skipped-record notes at 64, input channels at 64, handwriting tokens
  at 128, and the recent records kept for the log at 256 bytes each.
