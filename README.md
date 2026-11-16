<img src="assets/icon.svg" width="72" height="72" alt="Bandit's mask">

# Bandit

**Your Meta Neural Band as a remote for everything you own.**

Bandit is a small Bluetooth dongle that holds a Meta Neural Band as its owner (no Meta glasses, no
Meta app) and turns your finger gestures into input for up to five devices at once: an iPhone, a
Mac, a Windows or Linux PC, a TV. Pinch to play/pause, swipe through slides, scroll, flick between
apps, turn an invisible dial for volume, write letters in the air to type, or hold a pinch and move
your wrist as a mouse. Gestures go to one device at a time, and you switch between them with a
gesture too.

To every device it's just a Bluetooth keyboard and mouse called **Bandit**. Nothing to install on
them.

> **Unofficial and experimental.** The band's protocol is reverse-engineered (see [Credits](#credits)).
> Meta doesn't support this and could break it with any band firmware update. Not affiliated with Meta.

## The pieces

| | What it is |
|---|---|
| [**The dongle**](firmware/bandit/README.md) | Rust firmware for an **M5Stack Cardputer ADV**: an ESP32-S3 with a screen and a keyboard. The screen shows the band, the device it's driving and the active profile in its colour; the keyboard switches them, plays media, or types on the computer. Any other ESP32-S3 with 8 MB of flash (a Seeed XIAO, say) runs the same firmware headless. |
| [**The iPhone app**](Bandit) | Bandit for iOS: devices and pairing, gesture profiles (edit, import, export, merge), logs, and signed firmware updates over Bluetooth with a Live Activity. |
| [**The Mac helper**](https://github.com/Shlok-Bhakta/homebrew-bandit) | `bandit-mac`, a menu bar app: tells the dongle which app is in front, so profiles follow the app (a browser profile in Chrome, an editor one in Xcode), and buzzes the band when a GitHub Copilot agent needs you. `brew install shlok-bhakta/bandit/bandit-mac` |

```
                  BLE + L2CAP, encrypted                            BLE HID (keyboard, mouse, media)
Meta Neural Band ────── owner key ──────▶  Bandit dongle  ──────────▶ iPhone · Mac · PC · TV
                                          (Cardputer ADV)                (the active one)
                                               ▲
                     Bandit iOS app, bandit-mac ── private control service: status, profiles, logs, updates
```

## What you can do with it

- **Profiles.** A profile maps gestures to actions: media keys, keyboard shortcuts, typed text,
  clicks and scrolling, switching profile or device, the letter menu, buzz patterns. Five come
  built in (Media, Slides, Write, Copilot, TV), and each device remembers its own. A profile set is
  one JSON file you can hand to an AI assistant to edit ([PROFILES.md](firmware/bandit-profiles/PROFILES.md)).
- **Modes.** Profiles can stack: flick up into an app's profile, flick down to go back, bindings
  that work everywhere.
- **Write in the air.** The band's handwriting model types on a computer; one letter in the menu
  runs anything you've put there.
- **Air mouse.** Hold a pinch and move your wrist.
- **Phone calls.** A ringing iPhone buzzes the band; a gesture answers or hangs up.
- **Copilot.** The band buzzes when an agent finishes, asks you something, or fails.
- **Updates over the air,** signed with your own key, with automatic rollback.

## Getting started

You need a Meta Neural Band, its **owner key**, and an M5Stack Cardputer ADV (or another ESP32-S3).

1. **Get the owner key.** Claim the band once with [air-gestures](https://github.com/896kb/air-gestures)
   on Linux and export it (`air-gestures-band.json`, whose `owner_key` the dongle wants). Keep that
   file private: whoever has it owns the band.
2. **Build and flash the dongle.**
   ```sh
   make dongle-setup        # once: the Rust ESP32 toolchain (espup, espflash, ldproxy)
   make dongle-flash        # build and flash over USB (the first build downloads ESP-IDF: slow, once)
   ```
   Then on its serial console: `OWNER <base64 owner key>`. Put the band in pairing mode and the dongle
   takes it from there ([firmware/bandit](firmware/bandit/README.md) has everything else, including
   building on another machine and flashing a dongle plugged into one).
3. **Pair your devices.** Each one connects to **Bandit** in its Bluetooth settings while a pairing
   window is open (the first 2 minutes after power-up, or the Cardputer's `A`/`I` keys).
4. **Install the app** (optional, recommended): copy `Config/Local.xcconfig.example` to
   `Config/Local.xcconfig`, set your signing team, then `make project` and run the **Bandit** scheme
   from Xcode.
5. **On a Mac,** `brew install shlok-bhakta/bandit/bandit-mac && brew services start bandit-mac`.

`make help` lists the rest: `make test` (host tests), `make dongle-release NOTES='…'` (sign and
publish an update for the app's update button), `make check` (secrets scan before you push).

## Repository layout

```
Bandit/                     the iOS app (SwiftUI): devices, profiles, pairing, firmware, settings
BanditWidgets/              its Live Activities (firmware update, dongle status); BanditShared/ is in both
NeuralBandKit/              Swift package: the dongle's control protocol and profile format (DongleProtocol),
                            logging and Bluetooth helpers, with their tests
firmware/bandit/            the dongle firmware (Rust, ESP-IDF): band session, HID hosts, profiles, OTA,
                            the Cardputer's screen and keyboard
firmware/bandit-profiles/   the profile format (PROFILES.md), its checker, the built-in set, shared test vectors
firmware/band-core/         the band's protocol in Rust (vendored from band-core, with fixes for newer band firmware)
firmware/dongle-pack/       host tool: your update signing key, signed packages, an offline Chrome flasher page
Config/, project.yml        Xcode settings and the XcodeGen project; ios-build.sh / ios-test.sh build and test it
```

## Security

- **The owner key** lives in the dongle's NVS and nowhere in this repository, logs or builds. Development
  builds don't encrypt NVS, so anyone holding the dongle could read the key: enable flash and NVS
  encryption before carrying one around.
- **Updates** install only with a valid ECDSA P-256 signature from your own key (kept outside the
  repo), pass a SHA-256 check, and roll back if the new image doesn't survive its first minute.
- Devices pair with "Just Works", but only inside a 2-minute pairing window.
- No analytics, no servers. See [SECURITY.md](SECURITY.md).

## Credits

The band's protocol comes from people who did the hard work first:
[band-core](https://gitlab.com/896kb/band-core) (the Rust protocol core, vendored in `firmware/band-core`),
[air-gestures](https://github.com/896kb/air-gestures) (claiming a band, the key file, hardware findings)
and [kinesis](https://github.com/callbacked/kinesis). All MIT licensed.

## License

MIT ([LICENSE](LICENSE)). Vendored code keeps its own license (band-core: MIT; esptool-js in
dongle-pack: Apache-2.0). A personal project: it doesn't take pull requests, but fork away
([CONTRIBUTING.md](CONTRIBUTING.md)).

The project started as *Neural Playground*, an iPhone app for poking at the band; that app is in
the git history.
