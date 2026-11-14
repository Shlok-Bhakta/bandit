# band-core

The Meta Neural Band protocol core of Air Gestures, in Rust and sans-IO. It covers:
- the AirShield encryption handshake;
- DataX framing;
- the protobuf fields the band speaks;
- gestures and the pinch-and-turn dial;
- battery and raw sEMG;
- firmware updates;
- the band's handwriting stream.

It never touches Bluetooth itself. A caller feeds it the bytes the band sent, and sends the
bytes it returns.

It is shared by both Air Gestures apps, which include it as a git submodule:
- [the Linux daemon](https://gitlab.com/896kb/air-gestures), at `band-core/`;
- [the Android app](https://gitlab.com/896kb/air-gestures-android), at `rust/band-core/`.

A change lands here once, then both apps move their submodule to it.

    cargo test
    cargo clippy --all-targets -- -D warnings

`tests/` runs every session against a simulated band (`responder.rs`, `sim.rs`), so no band
is needed.

## License

MIT, see [`LICENSE`](LICENSE). Parts of it started from
[callbacked/kinesis](https://github.com/callbacked/kinesis) (MIT), whose notice is in
[`LICENSE-kinesis`](LICENSE-kinesis).
