# band-dongle (Rust, ESP32-S3)

Your Meta Neural Band without a phone app. A Seeed XIAO ESP32-S3 connects to the band as its owner
using **band-core** (air-gestures' Rust protocol core, vendored in `../band-core` with fixes for
updated band firmware). It shows up as one Bluetooth device, **NP Band Remote**, that an iPhone and
a laptop can both be paired with. Gestures go to **one active host at a time**, never mirrored. It
works system-wide, in any app and on the lock screen. No software on the laptop.

```
Band ──BLE + L2CAP, encrypted, owner key──▶ XIAO ESP32-S3 ──BLE HID──▶ the active host (iPhone or laptop)
                                                  ▲
                    Neural Playground app ── control service: status, routing, logs, signed updates
```

## Hosts: up to five at once

| Type | Gets | Notes |
|---|---|---|
| **Phone** (iPhone, Android) | Media keys, Apple's microphone key, a headset's phone-mute button | No keyboard, on purpose: while one is connected, iOS hides its on-screen keyboard |
| **Mac** | Keyboard and mouse too: slides, Teams' ⌘⇧M, write mode, the Copilot app | |
| **Windows**, **Linux** | The same, with Ctrl wherever a Mac gets ⌘ (Teams' Ctrl+Shift+M, the Copilot app's Ctrl shortcuts) | Apple's microphone key may do nothing there |
| **TV** (Google/Android TV, Fire TV, most smart TVs that take a Bluetooth keyboard) | Swipes = arrow keys, index double tap = OK (Enter), middle double tap = Back (Escape), pinch-turn = volume, middle hold = voice | Modes don't apply |

All of them see the **band's** battery as NP Band Remote's (the Battery Service, read every 2
minutes while the band is connected; the last reading is kept over a reboot, 0% before the first).

Each host reads its own report map when it pairs and caches it: phones one without a keyboard (media keys,
and a mouse since 0.16), everything else the keyboard and mouse one. So a Mac, PC or TV can be relabelled later (the app: touch and hold
the host; or `kind <h> windows`), but a phone ↔ anything else needs pairing again. New devices pair
as phones. To pair anything else, plug the dongle into it (a Mac pairing window is open for 2
minutes after power-up), or open a window: the app's "Pair a computer or TV", holding the dongle's
BOOT button 2 s (a Mac), or `make cmd C='pair windows'` (`phone|mac|windows|linux|tv`). Then
connect **NP Band Remote** in its Bluetooth settings within 2 minutes. A device that just paired becomes the active host. Pairing is closed otherwise: an unknown device that
pairs outside a window is disconnected and its pairing deleted. (Pairings from before v0.6 were
adopted as phones.)

The first host to connect becomes active; the dongle remembers your last choice. Switch with the
letter menu (below): `p` for the previous host, `l` (or `1`) for the next; or tap the host in the
app. The band buzzes once for a phone, twice for a computer (three times: no host to switch to). When the active host leaves, gestures move to another one and
come back when it returns.

## Connecting fast (v0.10.1)

Plugged in with the band on, the band is live about **2.9 s** after power reaches the dongle; a
band that turns on (or comes back in range) is caught by its first advertisement and is live about
2 s later. What it takes, measured with `make connect-bench`:

| Step | Time |
| --- | --- |
| Dongle boot to its first scan | ~0.75 s (the self-test now runs 30 s later, in the background) |
| Link, encryption, L2CAP channel | ~0.25 s |
| Session handshake | ~1.8 s: the band's own key exchange and signature are ~1.45 s of it, the dongle's ~0.3 s |

- The dongle **scans continuously** while it has no band (it's on USB power), and matches the
  band's saved address as well as its name and service.
- The link starts **fast** (7.5–15 ms, no skipped events) for the handshake's round trips and moves
  to the low-power one once the band is live.
- The band's L2CAP PSM is saved after the first connect, so there's no GATT lookup (read again if
  it stops working). The CPU runs at 240 MHz and the P-256 code is built for speed.
- Host advertising pauses for the quarter second the band's link takes: a computer connecting at
  the same moment made it fail (0x3e) for seconds. With no computer connected it advertises every
  20–30 ms for 30 s, then every 100–150 ms.
- After a session that worked, it goes straight back to scanning; a band that keeps failing is
  retried after 0.5, 2, then 5 s.

Each connect logs `CONNECTED: … ms from seeing the band (link, encryption, L2CAP, handshake; band-core
… ms of it)`. `make connect-bench [ROUNDS=5]` releases and reclaims the band that many times;
`MODE=reboot` restarts the dongle each round instead (like plugging it in) and also times the first
computer.

## Battery (v0.10)

The band is worn all day, so the dongle keeps it as quiet as it can:

- **Wrist motion** (gyro and orientation, ~70 messages a second) streams only while a pinch hold
  uses it: the volume dial, Copilot's answer options, write mode's pointer. The rest of the time
  only gestures come through.
- **Handwriting** (the band's `hw_` model) runs only in write mode on a computer, or while the letter
  menu waits for a letter, and **sleeps after 90 s** with nothing written (one buzz). Any write-mode
  gesture wakes it (two buzzes). Turning it off also puts back the two standby settings turning it
  on disables, so the band can save power again.
- **The link** lets the band skip up to 4 connection events (30–50 ms each) while it has nothing to
  send; it still sends a gesture at the next one. Battery reads every 2 minutes, a quiet-link check
  every 5 s.
- Nothing else is asked for: no raw EMG, no orientation without motion.

**Measuring it:** `make power PHASES='wait:180 auto:15 motion:15 writing:15'` (dongle on USB, band
worn) waits until the band is off its charger, runs each state for that many minutes and writes
`target/power/<time>/summary.txt`: the band's own current draw (mA, from its battery reply, read
every 15 s while measuring) and voltage, its battery %/hour (1 % steps, so slow), and its radio
traffic (SDUs and bytes a second, gyro samples a second). `power
motion|writing on|auto` forces a state by hand; the dongle also logs the band's whole battery
reply (`band-core: battery reply: …`).

## Profiles (v0.11)

What every gesture does is a **profile**, and the profiles live in one JSON file: the format,
every gesture and every action are in [PROFILES.md](../np-profiles/PROFILES.md). The **NP Dongle**
app edits, imports, exports and sends it. Without a file of yours the dongle uses the built-in
set ([default.json](../np-profiles/profiles/default.json)): `media`, `slides`, `write`, `copilot`
and `tv`, which do what the modes below always did.

- **Each host has its own profile.** The phone starts in media, a computer in media, a TV in tv.
  Each host remembers what you last chose: the Mac in write, the TV in tv, and switching between
  them brings each back. Computers start in the mode earlier firmware had for all of them.
- **More gestures:** single and triple taps of either finger (`index.tap`, `middle.tripleTap`…)
  are bindable as well as doubles. A single tap waits 0.4 s for a second one only when the
  profile binds the double too, so double taps alone have no delay.
- **Any action on any gesture:** media keys, any key chord (`key:cmd+shift+m`), push-to-talk
  (`hold:alt+space` on `middle.hold`), typed text, clicks and scrolling, switching profile or host,
  and the letter menu. Each can be different per kind of host.
- **Battery:** wrist motion streams during a pinch hold only in a profile that uses it (the dial or
  the pointer), and handwriting only in a `typing` profile.
- **Handwriting on demand (v0.12):** the `write` action (on `index.tripleTap`, say) turns
  handwriting on with two buzzes; each typed letter restarts a 10 s timer, and one buzz says it
  went off.
- **Profiles that follow the app in front (v0.12):** with
  [np-appwatch](https://github.com/Shlok-Bhakta/homebrew-np) on a Mac (`brew install
  shlok-bhakta/np/np-appwatch`), a profile's `apps` (bundle ids) switch that Mac to it while one of
  them is in front, and any other app switches it back.
- **Every gesture, flicks and buzz patterns (v0.15):** profiles can bind `flick.up/down/left/right`
  (pinch, hold, flick the wrist: repeatable within one pinch, so `apps:next` on a flick walks the
  ⌘Tab switcher) and any raw band event (`band.thumb.swipeIn`, `band.index.click`, …). Every buzz
  is a pattern: the set's `buzzes` define them, `feedback` says which one each moment plays (an
  alert, a ringing call, a host switch …), a binding may have its own, and `buzz:<name>` plays one.
  `lab on` logs everything the band says, for the app's Gesture lab ([PROFILES.md](../np-profiles/PROFILES.md)).
- **Phone calls on an iPhone (v0.14):** the dongle reads the iPhone's notifications (Apple's ANCS,
  the way a watch does), so a ringing call buzzes the band (two long pulses every 3 s) and
  `call:answer` / `call:end` answer, decline or hang up. iOS asks once to share notifications.
- **Memory (v0.15.1):** it no longer runs out while the band streams wrist motion (a pinch, the
  gesture lab): one record of motion was hundreds of events in one 22–45 KB allocation, and every
  buffer from the band is now bounded (a band that floods the dongle is reconnected instead).
  Lowest free heap 63 → 137 KB, largest free block 31 → 90 KB; the log's `memory:` lines show
  where it goes (pools, each task's unused stack), and `make capture-cmd C='...'` sends a command
  through a running capture without resetting the dongle.
- **The air mouse as a mode (v0.16.2):** the pointer and flicks read the wrist's roll from the
  band's orientation instead of assuming palm down, so a turn left or right moves sideways however
  the palm faces (it went diagonal holding a phone). Switching to a `pointer` profile starts the
  gyro right away, and it stops 10 s after the last pinch (was 30), for the band's battery: a
  pointer profile you switch into and out of is the air mouse's mode.
- **No crash when a band session ends (v0.16.3):** the dongle no longer closes the band's L2CAP
  channel itself, only drops the link. When the band closed its end at the same moment, NimBLE
  freed the channel twice and the dongle crashed (LoadProhibited in `ble_hs_conn_delete_chan`),
  rebooted and did it again on the next session, every few seconds.
- **Straight air mouse and flicks (v0.16.4):** the pointer and flicks read the forearm's turn
  (left/right) and tilt (up/down) directly. They went through handwriting's frame, 37.7° off
  those axes: a turn left or right moved the pointer diagonally, and a clean swing never counted
  as a flick (it has to be 1.8× more one way than the other).
- **A volume dial that keeps up (v0.16.5):** a gap in the band's motion stream no longer drops the
  pinch (band-core's dial let go ~170 ms into most holds and stayed dead until the next pinch);
  6° a step (was 9°), steps up to ~16 a second, and a fast turn keeps its steps. Motion stays on
  45 s after a pinch in a profile with the dial or flicks (10 s in a pointer profile), so a turn
  doesn't wait ~0.8 s for it to start.
- **Siri on an iPhone (v0.16.1):** `media:voice` on `middle.hold` keeps Apple's voice key down on
  a phone while the finger is (at least 0.8 s), the way the side button starts Siri; 0.16.0 and
  earlier pressed it for 15 ms, which iOS ignored outside CarPlay. Computers still get a tap
  (dictation on a Mac).
- **A mouse for the iPhone (v0.16.0):** the phone's report map has the mouse now (still no
  keyboard, so the on-screen keyboard stays), with eight buttons instead of three. With
  AssistiveTouch on (Settings › Accessibility › Touch), a `pointer` profile's pinch-and-move points
  on the iPhone, `mouse:click` taps, and `mouse:button4`…`button8` do whatever AssistiveTouch's
  Devices screen gives them: Home, App Switcher, Control Center, Screenshot, a Shortcut... The
  phone's link is asked for 15 ms like a computer's. **A phone paired before 0.16 keeps its old
  map:** forget NP Band Remote on it and pair again.
- **Speed and links before RAM (v0.15.3):** 0.15.2's Bluetooth buffer cuts ran out in real use
  (volume swipes with wrist motion on: the band's credits couldn't be sent and the session
  dropped), so msys is 48+24 and ACL 24 again, and FreeRTOS, the heap and the Bluetooth controller
  are back in IRAM. The flash speed, compact crypto, stack and log-ring changes stay.
- **Memory and speed (v0.15.2):** free heap 159 → 239 KB, largest free block 92 → 209 KB, lowest
  free (self-test, a profile upload, `logs`, `profiles show`) 139 → 200 KB. Code the chip kept in
  RAM (FreeRTOS, the heap, the flash driver, the Bluetooth controller: 92 → 46 KB) runs from
  flash, Bluetooth's buffers live in the small RAM regions the heap otherwise only falls back to,
  and the log streams straight out of its ring. Flash is read 4x faster (QIO at 80 MHz: `make
  flash` used to leave it at 40), and the hashes and AES are built compact: a motion packet takes
  2 ms of the dongle, not 8 (`bench`), and the self-test 0.9 s, not 2.

## The letter menu (v0.8; letters from the profile set since v0.11)

**Pinch, hold until the band calls it a hold, then let go without turning** (within 3 s): that's
`index.hold`, bound to `menu` in the built-in profiles. Two buzzes: write **one letter** on any
surface within about 6 s. The built-in letters:

| Letter | Does | Buzz |
|---|---|---|
| `p` | Previous host | Once: phone, twice: computer |
| `l` (or `1`, `i`) | Next host | Once: phone, twice: computer |
| `m` | Media profile | Once |
| `s` | Slides profile | Twice |
| `w` | Write profile | Three times |
| `c` | Copilot profile | Four times |
| `t` | TV profile | Once |
| anything else, or nothing | Nothing changes | One long |

A file's `menu` maps any letter or digit to any action. A profile switch buzzes that profile's
`buzz` count, so you can tell where you landed without looking.

With two hosts, `p` and `l` both switch to the other one. Taps and pinches while the menu is open
are ignored (writing makes them). The band's handwriting is on only while the menu waits (in write
mode it's on anyway). If handwriting can't start, the pinch hold just switches to the next host.
Pinch, hold and **turn** is still volume (Copilot: answer options; write mode: the pointer).
Leaving write mode turns the band's handwriting off.

## Gestures: the built-in profiles

| Gesture | Phone | Computer: media | Computer: slides | Computer: write |
|---|---|---|---|---|
| Index **double** tap | Play / Pause | Play / Pause | Next slide (→) | Click |
| Thumb swipe right / left | Next / previous track | Next / previous track | Next / previous slide | Space / Backspace |
| Pinch, hold, **turn wrist** | Volume (9° per step) | Volume | Volume | Moves the pointer |
| Pinch, hold, let go (no turn) | Letter menu | Letter menu | Letter menu | Letter menu |
| Middle **hold** | Voice (Siri) | Voice (dictation) | Voice (dictation) | Voice (dictation) |
| Middle **double** tap | Phone mute (headset button) | Teams mute (⌘⇧M) | Teams mute (⌘⇧M) | Enter |
| Write with a finger | | | | Typed (lowercase; o/0 as "o") |
| Thumb swipe up / down | Nothing: scrolling a phone triggers them | Nothing | Nothing | Scroll |

### The copilot profile (v0.7, the GitHub Copilot app)

Shortcuts are the app's defaults, read out of GitHub Copilot app 1.3.0 (its command catalog).

| Gesture | Does | Key |
|---|---|---|
| Middle **hold** | Dictate into the prompt while held (push-to-talk; a buzz: speak) | ⌥Space held (set the app's dictation shortcut to it) |
| Middle **double** tap | Voice control: say a button on screen, a command, or an answer to the agent's question; tap again to stop listening | ⌃⇧Space (Settings › Experimental › Voice control) |
| Index **double** tap | Send the prompt / confirm the highlighted answer | Enter |
| Thumb swipe right / left | Next / previous session | ⌘⇧] / ⌘⇧[ |
| Thumb swipe up | Go to the agent's question | ⌘' |
| Thumb swipe down | Next unread session (the next agent that needs you) | ⌘U |
| Pinch, hold, turn | Move through the answer options | ↓ / ↑ |
| Pinch, hold, let go | Letter menu (`p`/`l` host, `m`/`s`/`w`/`c` mode) | |

### The write profile (v0.9.1: typing and an air mouse)

| Gesture | Does |
|---|---|
| Write with a finger | Typed (lowercase; o/0 as "o") |
| Pinch, **hold**, move the wrist | Moves the pointer (only while held: let go to stop) |
| Pinch, hold, let go without moving | Letter menu, as always |
| Index **double** tap | Click |
| Middle **double** tap | Enter |
| Thumb swipe up / down | Scroll |
| Thumb swipe right / left | Space / Backspace |
| Middle **hold** | Voice (dictation) |

The pointer reads the gyro the way band-core's drawing does, mirrored up/down on a left wrist
(v0.12.3), with its resting offset learned while you aren't pinching. Since v0.12.3 the gyro stays
on for 30 s after a pinch in a pointer profile, so the next pinch moves at once, and the dongle
asks each computer for a 15 ms link with no skipped events (macOS's own choice let it skip up to
22, a third of a second); the log's `links to hosts` line shows what each computer gave. The app's Air mouse section (shown in
write mode) sets speed, flips either axis (a left wrist may need it) and turns typing off.
**Unverified:** whether the band keeps sending wrist motion while it reads handwriting; if the
pointer stops with typing on, turn typing off.

Voice control covers the rest, PR review included ("go to review changes", "open pull request
review", "approve"...). Other defaults worth knowing: ⌘K command palette, ⌘\ review changes, ⌘⇧\
PR overview, ⌘⇧↩ open PR review, ⌘1–9 session by number, ⌘N new session.

Slides mode works in PowerPoint, Keynote and Google Slides (arrow keys). Write mode turns the band's
handwriting on only while a computer in write mode is the active host (it costs band battery); two
buzzes when it starts. Switch in the app, from the letter menu, or with `make cmd C='profile write'`. Teams' ⌘⇧M works
while Teams is the front window.

## Updates without a cable

The flash holds two app slots (`partitions.csv`). The app's **Dongle** screen checks
`https://<this mac>.ts.net/dongle/latest.json` (published by `make release`, served by a
localhost-only file server under launchd that Tailscale proxies; tailnet only) and streams the
package over Bluetooth ([CONTROL.md](CONTROL.md)). The dongle:

1. checks the package's **ECDSA P-256 signature** before writing anything (the key is on the build
   Mac only, `~/.config/neural-playground/dongle-signing.key`; `dongle-pack keygen` made it, and
   only its public half is in `src/ota.rs`),
2. writes the spare slot, checks the image's SHA-256 and ESP-IDF's image check, switches slots,
3. boots the new image **on probation**: it confirms itself after 60 s of running; a crash or reboot
   before then makes the bootloader go back to the old slot.

Fallback without Bluetooth: each release also has a self-contained **Chrome flasher** page (Web
Serial, esptool-js inlined, works offline). The app shares it (AirDrop it to the laptop); open it in
desktop Chrome or Edge with the dongle plugged in over USB. It writes the bootloader, partition
table, a blank otadata and the app, and leaves NVS (owner key, pairings) alone. The ROM bootloader
it talks to can't be broken by bad firmware (if the port doesn't show up: hold BOOT while plugging in).

## After a band firmware update: pair again

A band firmware update clears the band's Bluetooth pairings, so the dongle's saved keys stop working
("encryption timed out"). After two of those in a row the dongle forgets its pairing by itself
(or send `UNPAIR`). Then:

1. Disconnect the band from the phone app (the band talks to one device at a time).
2. Put the band in pairing mode. The dongle pairs within seconds and connects with the same owner
   key (the update keeps ownership; there's nothing to re-provision).
3. Updated firmware negotiates encryption scheme 26, whose rules are guessed: the dongle tries
   guess 0 (the one verified by air-gestures) and moves on by itself if a guess authenticates nothing,
   keeping the one that works.

A phone paired with v5 keeps working with v0.6 (same phone layout). If a host acts up after an
update, forget **NP Band Remote** on it and pair again (in a pairing window).

## Verified

- v4 (2026-11-11, old band firmware): handshake, owner trust, reconnects, media keys, heap stable over
  10 forced reconnects. See git history for the details.
- v5 (2026-11-12): pairs with the updated band (firmware 1054928927) found by scan (it advertises
  FD5F from a new address in pairing mode), scheme 26 guess 0 authenticates, owner trust accepted,
  battery and hand read, and it reconnects by itself after a reboot. **Not yet verified:** the voice
  key (dictation / Siri) and the phone-mute button.
- v0.6 (2026-11-12): the two-slot layout flashed over USB keeps the owner key and pairings; the
  band comes back as owner. A signed package pushed through the update path (`make ota-test`, the
  app's protocol over serial) was signature-checked, written to `ota_1`, SHA-checked, booted on
  probation, reconnected to the band and confirmed itself after 60 s; a package with a flipped
  signature bit was refused before any flash write (`make ota-tamper-test`); a corrupted image
  failed the SHA check and the slot didn't change. **Not yet verified:** the Bluetooth transport
  from the app, a second host (laptop), per-host report maps, the pinch-hold switch, slides keys.

## Build, flash, serial

```sh
cd firmware/band-dongle
make setup                # once: espup, espflash, ldproxy (or point config.mk at your toolchain)
make help                 # all targets
make serve                # once: serve releases to your tailnet at https://<this mac>.ts.net/dongle/
make flash                # build + flash over USB (first build ~45 min: ESP-IDF + Rust std)
make release NOTES='...'  # build, sign, publish for the app's update button
make status               # status JSON over serial;  make log SECS=60 for the log
make profiles-get          # the dongle's profile set into target/profiles.json (FILE=… for another)
make profiles-put          # that file onto the dongle; the phone app then: Get the dongle's set
make cmd C='key playpause'
make ota-test             # push the published package over serial through the real update path
```

### The dongle on another machine

The firmware builds on this Mac (or another machine, below), and the dongle can be plugged into
any Linux box you can ssh to. With `REMOTE = kiwi` in config.mk (or `make … REMOTE=kiwi`), `make
flash` copies the images there and flashes with espflash, and `log`, `status`, `cmd`,
`profiles-get`/`-put`, `connect-bench` and the OTA tests run there too (`power` doesn't: it
keeps its results here). Once:

```sh
make remote-setup                        # espflash (the same version as here) and the tools, in ~/np-dongle
ssh -t kiwi sudo sh np-dongle/setup-access.sh   # lets you open the port; ModemManager leaves it alone
```

`make release` doesn't need the dongle at all: the phone app installs it over the air.

### Building on another machine

The build is mostly disk-bound (ESP-IDF is thousands of small files), so it can run on a Linux box
with a fast internal disk. With `BUILD_HOST = crabcake` in config.mk, `make build` sends git's
files (committed or not) to `~/np-build/repo` there, builds, and brings the ELF and bootloader
back, so `flash`, `release` and addr2line work as before. Once, on that machine (no sudo needed):

```sh
curl -LsSf https://astral.sh/uv/install.sh | sh && uv python install 3.12   # a python3 with venv
mkdir -p ~/np-build/bin && ln -s "$(uv python find 3.12)" ~/np-build/bin/python3 && ln -s python3 ~/np-build/bin/python
cargo install espup ldproxy --locked
espup install --toolchain-version 1.97.0.0 --targets esp32s3 --export-file ~/np-build/export-esp.sh
```

Serial commands (type a line, then Enter):

| Command | Effect |
|---|---|
| `OWNER <base64>` | Store the owner key, the `owner_key` field of air-gestures-band.json (NVS, never compiled in) |
| `FORGET` | Delete the stored owner key (and the scheme-26 guess) |
| `PAUSE` / `RESUME` | Release or reclaim the band (same as the BOOT button) |
| `UNPAIR` | Forget the Bluetooth pairing with the band (put the band in pairing mode to pair again) |
| anything else | An app control command ([CONTROL.md](CONTROL.md)): `status`, `target next`, `profile slides`, `pair computer`, `key teamsmute`, ... |

## Security notes

- The band's Bluetooth address is learned when it first connects (and saved in NVS), not compiled in.
- The owner key sits in NVS **unencrypted** in this dev build, so anyone holding the dongle could read it. Before carrying it around, enable flash encryption plus NVS encryption.
- Hosts pair with "Just Works" (no passkey), but only inside a pairing window (or while no host is known).
- Updates must carry this dongle's signature; the private key never leaves the build Mac.
- The bond with the band and the owner key survive reflashing. They're erased only by `FORGET` or `espflash erase-flash`.
