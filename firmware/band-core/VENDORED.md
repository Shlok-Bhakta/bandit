# Vendored band-core

Copied from https://gitlab.com/896kb/band-core at `4b59393` (2026-10-30, MIT, see LICENSE and
LICENSE-kinesis) so the dongle can carry fixes for updated band firmware (1054928927 and later).
Changes from upstream are listed below and marked `// neural-playground:` in the source.

- `session.rs` input: an unnamed frame shaped like an RPC answer is read as one even when the
  channel's last named kind was a log line or an error word (updated firmware sends those on the
  channels it answers on; the Neural Playground iPhone app hit this switching handwriting on).
- `session.rs` `stream_request`: the band's handwriting asks for stream flags 22 and 23 with the
  model output (4), as kinesis and rokid-lumen do.
- `session.rs` power (for the dongle, worn all day): `without_motion` / `set_motion` turn gyro and
  orientation off and on without touching gestures (the same stream flags an update quiets);
  turning the band's handwriting off restores `ConfigReq` fields 13 and 21 (standby-related, which
  turning it on sets to 0) as the config read reported them.
- `dial.rs` `arm_held` (through `BandSession::arm_dial`): with motion off until a hold, the pinch
  dial arms on the band's own hold report once gyro starts, instead of only on a press that came
  with motion already flowing.
