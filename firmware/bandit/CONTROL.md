# Dongle control protocol (v1)

The dongle ("Bandit") is a Bluetooth HID device for one or more hosts (an iPhone, a
laptop) and also exposes a private **control service** for the Bandit app: status,
logs, routing, and firmware updates. Every control characteristic requires an encrypted
(bonded) link, so only a paired host can use it. Firmware packages are additionally signed
(ECDSA P-256); the dongle refuses unsigned or altered ones.

The control service UUID is in the dongle's scan response, so the app can find the dongle by
scanning for it. iOS shares the link the system already holds for the HID remote; the app can
also use `retrieveConnectedPeripherals(withServices: [service])`.

| | UUID | Properties |
|---|---|---|
| Service | `4e500100-3c1a-4e0b-9d1e-6f2b5a7c8d90` | |
| Status | `4e500101-3c1a-4e0b-9d1e-6f2b5a7c8d90` | read (encrypted) |
| Command | `4e500102-3c1a-4e0b-9d1e-6f2b5a7c8d90` | write with response (encrypted) |
| Log | `4e500103-3c1a-4e0b-9d1e-6f2b5a7c8d90` | notify (encrypted) |
| Update | `4e500104-3c1a-4e0b-9d1e-6f2b5a7c8d90` | write, write without response, notify (encrypted) |
| Changed | `4e500105-3c1a-4e0b-9d1e-6f2b5a7c8d90` | notify (since 0.11.1) |

New characteristics only ever go at the end: hosts cache the handles, and iOS doesn't always
rediscover them after an update.

## Status (read)

Compact JSON, always at most 512 bytes. With many hosts it sheds, in order: host names (shortened, then left out), error texts, host `p`, then `heap`, `mouse`, an idle `upd` and `pe`, and last the hosts other than the active one. Poll it (every 1–2 s while a dongle screen is visible). Since 0.11.1 a subscriber to Changed gets a one-byte notification, `?`, when anything but `up` and `heap` changes and once a minute: the status doesn't fit in a notification, so read it then. (0.11.0 sent it on Status itself.)

```json
{"fw":"0.11.0","id":"3fa2c1d0","slot":"ota_0","verify":false,"up":123,"heap":81234,
 "band":{"s":"live","bat":80,"chg":false,"hand":"right","mv":3912,"ma":14},
 "mode":"media","ph":"builtin","mouse":{"sp":5,"fx":false,"fy":false,"ty":true},"pair":0,"you":1,
 "hosts":[{"h":1,"k":"phone","n":"iPhone","act":true,"p":"media"},{"h":2,"k":"computer","n":"Work Mac","p":"write"},{"h":3,"k":"computer","os":"windows","n":"Gaming PC","p":"media"},{"h":4,"k":"tv","n":"TV","p":"tv"}],
 "upd":{"s":"idle","got":0,"of":0,"e":""}}
```

- `fw`: firmware version. `id`: first 8 hex digits of the running image's ELF SHA-256 (unique per build). `slot`: running partition. `verify`: true while a fresh update is still on probation (it is confirmed after ~60 s of healthy running; a crash before then rolls back).
- `band.s`: `live`, `connecting`, `searching`, `paused` (released for the phone app), `no-owner`. `bat`/`chg`/`hand` may be null.
- `mode`: the active host's profile id (0.11+; before, one of `media`, `slides`, `write`, `copilot` for every computer). Profiles: [PROFILES.md](../bandit-profiles/PROFILES.md).
- `ph` (0.11+): the profile set: `builtin`, or the first 8 hex digits of the stored file's SHA-256. `pe`: why the last upload was refused (only after one was).
- `mouse` (0.9+): write mode's air mouse speed (`sp`, 1–10), flipped axes (`fx`, `fy`) and whether handwriting is typed (`ty`; off: write mode is only the mouse).
- `pair`: seconds left in a pairing window (0 = closed; while closed, unknown devices can't pair).
- `you`: the connection handle of the host reading the status (the app's own host).
- `hosts`: connected hosts (up to 5). `k`: `phone` (media keys only), `computer` (also a keyboard and mouse) or `tv` (the keyboard map: arrows, Enter, Escape). `os` (computers; default `mac`): `windows` or `linux`, where ⌘ shortcuts are sent with Ctrl. `n`: name (default ""). `act` (default false): the one host gestures go to. `p` (0.11+): its profile id (each host remembers its own; left out, for every host, only when five hosts with long profile ids wouldn't fit otherwise: the active one's is still `mode`).
- `upd.s`: `idle`, `receiving`, `verifying`, `done`, `error` (`e` holds the reason).

## Commands (UTF-8 text writes)

| Command | Effect |
|---|---|
| `hello <name>` | The app registers its own host: kind `phone`, display name `<name>` |
| `target <h>` / `target next` | Send gestures to host `<h>` / the next connected host (the band buzzes once for a phone, twice for a computer) |
| `profile <id>` / `profile next` / `profile previous` | Switch the active host's profile (the band buzzes the profile's `buzz` count). `next`/`previous` skip profiles it can't use |
| `profile <h> <id>` | Switch host `<h>`'s profile |
| `buzz done\|question\|error` | (0.13) The band buzzes a pattern of its own: done two firm pulses, question two taps and a long one, error one very long. Buzzes that come close together play one after another, half a second apart (0.13.1; up to 4 wait). bandit-mac sends it for Copilot's hooks |
| `buzz <pattern>` / `buzz try <pattern text>` | (0.15) Plays one of the set's buzz patterns by name (built-in or the file's `buzzes`), or a pattern given in full (`buzz try 250 _200 250*90`, see PROFILES.md): the app's pattern editor previews with it. The `alert.*` feedback patterns are what `done`/`question`/`error` play |
| `lab on` / `lab off` | (0.15) The gesture lab: every band gesture message is logged in full (`LAB fields <finger> <action> <derived>: …`) and every pinch's wrist swings (`LAB flick <dir> <peak °/s>` when it flicked, `LAB swing <dir> <peak>` when it didn't), with wrist motion on during pinches. Off by itself after 10 minutes. Every message is always logged briefly as `gesture #<n>: <finger> <action> <derived>` |
| `app [bundle id]` | From a computer's helper (bandit-mac, 0.12): the app now in front on the computer that wrote it. A profile whose `apps` lists it becomes that computer's profile; another app (or none) brings back the one it had before. Not saved |
| `mode <id>` | Before 0.11 the computer mode; now the same as `profile <id>` (`mode mouse` means write) |
| `profiles begin <bytes> <sha8>` | Start sending a profile set: its length (≤ 6144, minified) and the first 8 hex digits of its SHA-256 |
| `profiles data <offset> <base64>` | A chunk of it (≤ 150 bytes a chunk keeps the command under 240 bytes). Order doesn't matter |
| `profiles commit` | Check the length, hash and file, save it and apply it to every host. Success: `ph` becomes the hash; refused: `pe` says why |
| `profiles reset` | Back to the built-in profiles |
| `profiles show` | (0.12.1) The set it runs, as the file it was sent as, in log lines: `PROFILES: show begin <bytes> <sha8> [builtin]`, `PROFILES: show data <offset> <base64>`… (150 bytes each), `PROFILES: show end` |
| `mouse speed <1-10>` / `mouse flipx [on\|off]` / `mouse flipy [on\|off]` / `mouse type [on\|off]` | Air mouse settings (no on/off: toggle) |
| `pair phone` / `pair mac` / `pair windows` / `pair linux` / `pair tv` (`pair computer` = `pair mac`) | Open a 120 s window: the next new device to pair becomes that kind |
| `kind <h> mac\|windows\|linux\|tv` | Say what a connected computer or TV is (a phone ↔ the rest needs pairing again: hosts cache their report map) |
| `pair close` | Close the window |
| `name <h> <text>` | Rename a host |
| `forget <h>` | Forget host `<h>` (deletes its pairing) |
| `band pause` / `band resume` | Release the band to the phone app / reclaim it |
| `key <name>` | Send a key to the active host: `playpause next previous volup voldown voice phonemute teamsmute right left blank` |
| `power motion on\|auto` / `power writing on\|auto` | Power measurements: keep wrist motion or the handwriting model on regardless of gestures (not saved; `auto` = as gestures need) |
| `logs` | Resend the log backlog over the Log characteristic |
| `bench` | (0.15.2) Time the band's hot path on the dongle: a simulated band's motion packets through band-core and the gesture controller, logged as `BENCH: … us a packet` (for comparing builds; a band on its charger sends no motion) |
| `reboot` | Restart the dongle |

## Log (notify)

UTF-8 text fragments; concatenate them and split on `\n`. After `logs`, the backlog (about the
last 200 lines) is sent first.

## Update

A package (`.banditfw`) is a 256-byte header followed by the ESP32 app image:

| Bytes | Field |
|---|---|
| 0..8 | magic `NPDFW\x01\x00\x00` |
| 8..12 | image length, u32 little-endian |
| 12..16 | reserved (0) |
| 16..64 | version string, NUL-padded |
| 64..96 | SHA-256 of the image |
| 96..160 | ECDSA P-256 signature (SHA-256, r‖s) over bytes 0..96 |
| 160..256 | zero |

The app streams the **whole package** (header included):

App → dongle (Update characteristic):
- `01 <total u32>`: BEGIN, write **with** response. `total` = package length.
- `02 <offset u32> <bytes>`: DATA, write **without** response, `offset` into the package. Chunk size = `maximumWriteValueLength(for: .withoutResponse) - 5`.
- `03`: ABORT.

Dongle → app (notifications):
- `80`: READY (send data from offset 0).
- `81 <next u32>`: ACK, everything below `next` is committed (sent every 4 KB and at the end).
- `82 <next u32>`: RESEND from `next` (a chunk was out of order or dropped).
- `83`: DONE, verified and the boot slot switched; the dongle reboots in about 1.5 s.
- `84 <utf8 reason>`: FAIL.

Flow control: keep at most 8 KB sent beyond the last ACK; on RESEND, continue from `next`; if
no ACK arrives for 5 s, resend from the last ACK. The header is checked (signature) as soon as
its 256 bytes arrive, before anything is written to flash. After DONE the dongle reboots into
the new firmware, which reconnects to the host by itself; read `id` to confirm it changed.

## Release index (Tailscale)

`https://<your-mac>.<tailnet>.ts.net/dongle/latest.json` (`make serve` sets it up):

```json
{"version":"0.6.0","id":"3fa2c1d0","file":"bandit-3fa2c1d0.banditfw","size":1650000,
 "sha256":"<hex of the whole .banditfw>","notes":"…","flasher":"bandit-3fa2c1d0-flasher.html"}
```

`file` and `flasher` are relative to the index. `flasher` is a self-contained HTML page that
flashes the dongle over USB from desktop Chrome (the fallback when Bluetooth updates can't).
