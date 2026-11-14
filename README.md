<img src="assets/icon.svg" width="64" height="64" alt="">

# Neural Playground

Use a **Meta Neural Band** without Meta's glasses or app:

- **Neural Playground (iOS):** connects the band directly to an iPhone. Claim the band once, keep
  the owner key, and reuse it on Linux, Mac and iPhone. It also has a live gesture dashboard, a
  haptics lab, a raw EMG viewer and two games you play with your fingers.
- **Band remote dongle (ESP32-S3, Rust):** a ~$7 Seeed XIAO ESP32-S3 holds the band and shows up as
  one Bluetooth keyboard/remote, **NP Band Remote**, that up to five devices (iPhone, Mac, Windows,
  Linux, a TV) pair with at once. Gestures go to one of them at a time: media keys, slides, typing
  by handwriting, an air mouse, the GitHub Copilot app. See [firmware/band-dongle](firmware/band-dongle/README.md).
- **NP Dongle (iOS):** the dongle's own app. Hosts and pairing, switching each host's gesture
  profile, editing profiles (a JSON file you can export, hand to an AI assistant and import back;
  see [PROFILES.md](firmware/np-profiles/PROFILES.md)), logs, and signed firmware updates over
  Bluetooth with a Live Activity.

> Unofficial and experimental. The protocol is reverse-engineered. Meta doesn't support it and
> could change it with any firmware update. Not affiliated with Meta.

## Quick start

```sh
make help            # everything below, and more
make test            # protocol tests: Swift (NeuralBandKit) and Rust (band-core, dongle-pack)
make app             # build the Neural Playground iOS app (see "Build and install" for signing)
make dongle-app      # build the NP Dongle iOS app
make dongle-setup    # once: the Rust ESP32 toolchain (espup, espflash, ldproxy)
make dongle-flash    # build and flash the dongle over USB
make dongle-release NOTES='what changed'   # sign and publish an update for NP Dongle's update button
make check           # secrets and personal-data scan before you push
```

## Repository layout

```
NeuralPlayground/         SwiftUI iOS app, the band demo (Band, Playground, Games, Credentials, Diagnostics)
NPDongle/                 SwiftUI iOS app for the dongle (hosts, profiles, pairing, firmware, settings)
NPDongleWidgets/          its Live Activities (firmware update, dongle status); NPDongleShared/ is in both
NeuralBandKit/            Swift package: the protocol and transport SDK, plus DongleProtocol (incl. profiles)
firmware/band-dongle/     the dongle firmware (Rust, ESP-IDF): band session, HID hosts, OTA, control service
firmware/np-profiles/     gesture profiles: the format (PROFILES.md), its checker, the built-in set, test vectors
firmware/band-core/       the band protocol in Rust (vendored from gitlab.com/896kb/band-core, with fixes)
firmware/np-profiles/     gesture profiles: the np-profiles JSON format (PROFILES.md), its checker, test vectors
firmware/dongle-pack/     host tool: signing key, signed update packages, the offline Chrome flasher page
firmware/bci-bridge/      ESP-IDF (C): Apple BCI HID bridge for iOS Switch Control
firmware/band-link/       ESP-IDF (C): the first band-connection experiment (stage 1, kept for reference)
Config/                   Xcode build settings (your team id goes in the git-ignored Config/Local.xcconfig)
project.yml               XcodeGen project; ios-build.sh / ios-test.sh are the build and test recipes
```

## Where the protocol comes from

The protocol is not invented here. It's a Swift port of:

| Source | Used for |
|---|---|
| [band-core](https://gitlab.com/896kb/band-core) (Rust, 2026-10-30) | Session state machine, AirShield crypto incl. **scheme-26 firmware** (8 key guesses), DataX framing, ownership ceremony, haptics RPC, raw EMG, battery, hand, pinch dial, gesture router |
| [kinesis](https://github.com/callbacked/kinesis) (Swift/macOS) | CoreBluetooth transport (service `FEB8`, PSM characteristic → L2CAP PSM 255), Meta sign-in chain, ownership HTTP client |
| [air-gestures](https://github.com/896kb/air-gestures) | `air-gestures-band.json` format (`transfer.rs`), pending/confirmed key rules, hardware findings (scheme 26, padding, tagged channels) |
| [rokid-lumen](https://github.com/beyondlevi/rokid-lumen) | Cross-checked the Android side of the same JSON key format |

All four are MIT licensed.

### How connecting and ownership work

1. **Bluetooth:** the band advertises as `Meta Band XXXX` with service `FEB8`. Reading characteristic
   `2D41DA7C-…` returns `FF 00` (PSM 255). That read also makes iOS bond with the band, so you'll see a pairing prompt.
2. **L2CAP + AirShield:** a P-256 ECDH handshake, then HKDF-derived AES-256-CBC with an HMAC-SHA256
   tag on every record. Older firmware uses scheme 3. Firmware from September 2026 on negotiates
   scheme 26, which band-core guesses (guess 0 has been verified on hardware). The guess that works
   is saved as `scheme_guess`.
3. **Ownership (once):** with the band in pairing mode, you sign in on Meta's own page (auth.meta.com).
   The band's certificate and nonce go to `graph.facebook-hardware.com/pair_request`, the band signs
   a pending receipt, and `/pair` returns the final receipt. The band then commits a newly generated
   P-256 **owner key**.
4. **Every later connection:** the app signs an `EnableTrust` proof with the owner key, the band
   proves itself back, and the app subscribes to gestures, gyro and orientation. Meta isn't involved.

## Build and install

Requirements: Xcode with an iOS SDK that supports your iPhone's iOS version, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM (+ a unique bundle id for a free team)
xcodegen generate
open NeuralPlayground.xcodeproj                          # choose your iPhone, then Run
```

The project has two app schemes: **NeuralPlayground** (the band demo) and **NPDongle** (the
dongle's app, bundle id `dev.neuralplayground.dongle`, with its Live Activity extension
`dev.neuralplayground.dongle.widgets`; neither needs extra entitlements).

`Config/Local.xcconfig` is git-ignored. The protocol tests run on the Mac:

```sh
cd NeuralBandKit && swift test
```

## First run on the iPhone

1. Allow Bluetooth when asked.
2. **If the band is already claimed on Linux or Android:** run `air-gestures export` there, then on
   the iPhone go to **Band → Import air-gestures-band.json**. Next, run `air-gestures disconnect` on
   Linux, wake the band, scan, tap the band and choose **Connect with the saved owner key**. The
   first time, iOS asks to pair. If the band dropped its pairing with this phone, use Settings ›
   Bluetooth › Forget This Device and put the band in pairing mode (hold the button ~3 s).
3. **To claim it with this iPhone:** put the band in pairing mode (factory reset first, by holding
   the button ~16 s, if it belongs to another account or the Meta AI app). Then on the Band tab, tap
   the band, choose **Claim this band with Meta…**, sign in, and accept the pairing prompt.
   When it finishes, the app asks you to back up the key.
4. **Back up:** go to **Credentials → Export / Share air-gestures-band.json** (works with air-gestures and
   Android), or **Create encrypted backup** (`.npbackup`, password protected). For air-gestures to reconnect on Linux,
   enter the band's Bluetooth address (from `bluetoothctl devices`) under Credentials first:
   iOS never exposes it.

## Wrist, signals and System Control

- **Wrist:** Playground › Wrist picks left or right instantly with no reconnect. It applies app-side
  corrections (invert horizontal, vertical, dial) per wrist. The band's own stored hand setting is
  shown separately and only changes when you tap **Set band …**, which writes it and verifies it by reading it back.
- **Live signals:** raw 8-channel sEMG traces, gyro, orientation, and every message type the band sends, with rates.
- **System Control (BCI HID):** normalized gestures are mapped per wrist to Apple's BCI button actions
  and encoded as real BCI HID reports (`BandAccessibility`, with tests against Apple's descriptor).
  An iPhone app can't inject system input itself (the iOS SDK has no public virtual-HID API), so the
  reports go to an ESP32 acting as Apple's BCI HID device: see [`firmware/bci-bridge`](firmware/bci-bridge/README.md).

## Logs

Every layer writes to one shared log, which you can paste straight into a bug report:
**Diagnostics → Logs** (filter by level or category, **Copy all**, share), **Copy full log**, or
**Share sanitized diagnostic report**. Each launch is also written to `Application Support/Logs/`,
and the log is mirrored to Console.app (subsystem `dev.neuralplayground.band`). Turn on **Log every
frame header** for per-frame channel, type word and size.

Logs never contain owner keys, Meta tokens, receipts, certificates or decrypted payloads, and serial numbers are masked.

## Architecture

```
NeuralBandKit/            Swift package: the reusable SDK
  BandLogging             shared log (ring buffer + per-launch file + os.Logger)
  BandProtocol            sans-IO: AirShield, DataX, protobuf, BandSession, ceremony, gestures, haptics, EMG
  BandCredentials         Keychain stores, air-gestures JSON codec, encrypted backup
  BandTransport           CoreBluetooth central, GATT discovery, bonding, L2CAP stream
  BandKit                 BandClient façade (lifecycle, retries, ceremony, haptics queue), typed EventHub, Meta auth
NeuralPlayground/         SwiftUI app: pairing, credentials, playground, haptics, EMG, games, diagnostics
```

`BandProtocol` has no I/O and no platform UI, which keeps a later standalone Swift SDK, or a swap
back to the Rust band-core over FFI, straightforward.

## Security

- The owner key is stored in the Keychain (`…AfterFirstUnlockThisDeviceOnly`: not synced to iCloud,
  not included in device backups). Revealing, copying, exporting and deleting it all need Face ID or the passcode.
- The Meta session has its own Keychain item, separate from the owner key, and is only used for claiming.
- No secrets are stored in UserDefaults or the source code, and there are no analytics or backends. The only
  network traffic is to Meta during sign-in and claiming.
- Before any unencrypted export, the app warns you. Copied keys stay on this device (no Universal
  Clipboard) and clear after 60 s. Temporary share files are deleted when the share sheet closes.
- `.gitignore` excludes `*band.json`, `*.npbackup`, `owner.key` and `meta-session.json`.

## License

A personal project: it doesn't take contributions, but you're welcome to fork it ([CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md)). MIT licensed ([LICENSE](LICENSE));
vendored code keeps its own license (band-core: MIT; esptool-js in dongle-pack: Apache-2.0).

## Status

Tested without hardware: 17 protocol tests pass (band-core crypto vectors, plus full sessions against a
simulated scheme-26 band covering trust, the ownership ceremony, gestures, haptics, battery, the pinch dial
and rejection codes). The app builds for iOS with no warnings.
Not yet tested on real hardware: everything that touches a real band or Meta's servers.
