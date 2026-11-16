# Contributing

This is a personal project, and it doesn't take contributions: pull requests and feature requests
won't be reviewed or merged. You're welcome to fork it under the MIT license (see [LICENSE](LICENSE))
and build on it yourself.

If you do build it, the notes below are how it's put together.

## Building it yourself

| Part | Needs |
|---|---|
| iOS app (Bandit), NeuralBandKit | Xcode (iOS 17 SDK or later), [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| Dongle firmware | An M5Stack Cardputer ADV (any ESP32-S3 with 8 MB of flash runs it headless); `make dongle-setup` installs the Rust ESP toolchain (espup, espflash, ldproxy). The first build downloads ESP-IDF v5.3 (slow, once) |
| Host tools and tests | Rust stable (`dongle-pack`, `band-core` tests) |

- Local settings stay out of git: copy `.env.example` to `.env` (the release host) and
  `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (signing team).
- Toolchain not in espup's default places: copy `firmware/bandit/config.mk.example` to `config.mk`.
- Dongle updates are signed. `dongle-pack keygen` makes your own signing key (outside the repo,
  owner-only) and prints its public half: put that in `firmware/bandit/src/ota.rs`
  (`UPDATE_KEY`) and flash once over USB. From then on only your releases install.
- `make test`, `make dongle-build` and `make check` (secrets and personal data) before you publish
  anything.
