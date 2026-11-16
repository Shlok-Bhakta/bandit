# Gesture profiles (`np-profiles`, version 1)

A profile says what each band gesture does. The dongle keeps one **profile set**: a JSON file
(`.npprofiles`) that the Neural Playground Dongle app edits, imports, exports and sends to the dongle.
Hand-written files work too: write one, AirDrop it to the phone, and open it with the app.

Every connected host has **its own active profile**. The phone starts in `media`, a computer in
`media`, a TV in `tv` (see `start`), and each host remembers what you last chose for it. So
switching from the Mac (in `write`) to the TV and back brings `write` back.

The dongle checks the file with the same rules as the app ([`src/lib.rs`](src/lib.rs)). With no file
of yours, it uses the built-in set, [`profiles/default.json`](profiles/default.json), which does what
earlier firmware did.

## Example

```json
{
  "format": "np-profiles",
  "version": 1,
  "name": "My setup",
  "menu": { "m": "profile:media", "w": "profile:write", "p": "host:previous", "l": "host:next" },
  "start": { "phone": "media", "computer": "media", "tv": "media" },
  "profiles": [
    {
      "id": "media",
      "name": "Media",
      "buzz": 1,
      "gestures": {
        "index.hold": "menu",
        "index.doubleTap": "media:playPause",
        "middle.doubleTap": { "phone": "phoneMute", "computer": "key:cmd+shift+m" },
        "middle.hold": "media:voice",
        "swipe.right": "media:next",
        "swipe.left": "media:previous",
        "dial.cw": "media:volumeUp",
        "dial.ccw": "media:volumeDown"
      }
    },
    {
      "id": "write",
      "name": "Write",
      "hosts": ["computer"],
      "buzz": 3,
      "typing": true,
      "pointer": true,
      "gestures": {
        "index.hold": "menu",
        "index.doubleTap": "mouse:click",
        "middle.doubleTap": "key:enter",
        "swipe.up": "mouse:scrollUp",
        "swipe.down": "mouse:scrollDown",
        "swipe.right": "key:space",
        "swipe.left": "key:backspace"
      }
    }
  ]
}
```

## The file

| Field | | |
| --- | --- | --- |
| `format` | required | `"np-profiles"` |
| `version` | required | `1` |
| `name` | optional | Up to 40 characters, shown in the app |
| `menu` | optional | The letter menu: one letter or digit (`a`–`z`, `0`–`9`) → an action (anything but `hold:`, `mouse:point` and `menu`). Letters you write that aren't here get one long buzz |
| `start` | optional | The profile a host starts in, by `phone`, `computer` and `tv`. Each must allow that kind. Default: the first profile that allows it |
| `buzzes` | optional | Your own buzz patterns, by name (below). Up to 16 |
| `feedback` | optional | What the band buzzes by itself, by moment: a pattern's name, or `none` (below) |
| `everywhere` | optional | Gesture → binding, in every profile, winning over a profile's own (Modes, below; firmware 0.17) |
| `profiles` | required | 1–12 profiles |

**A profile:**

| Field | | |
| --- | --- | --- |
| `id` | required | 1–16 of `a`–`z`, `0`–`9`, `-`; unique |
| `name` | required | 1–24 characters |
| `buzz` | optional | Played when you switch to it, so you can tell where you landed: 1–4 short buzzes (default 1), or a pattern's name (`"rise"`) |
| `hosts` | optional | Who may use it: any of `phone`, `computer`, `mac`, `windows`, `linux`, `tv`. Default: everyone. Switching a host to a profile it can't use gets one long buzz |
| `typing` | optional | The band's handwriting is typed on the computer. The model sleeps after 90 s with nothing written; any gesture in this profile wakes it |
| `pointer` | optional | Pinch, hold and move the wrist moves the mouse pointer (computers; an iPhone with AssistiveTouch on, firmware 0.16). The dial and flicks are off where it points |
| `gestures` | optional | Gesture → action, below |
| `apps` | optional | Up to 16 Mac apps by bundle id (`com.google.Chrome`): a computer switches to this profile while one is in front (below). Each 1–64 of `A`–`Z`, `a`–`z`, `0`–`9`, `.`, `_`, `-`; an app in one profile only; only in a profile for computers |

The app may add its own fields, like `description` or `symbol` (an SF Symbol). The dongle ignores
them, but they count towards the size limit. `color` (`#rrggbb`) is the app's too, and the
Cardputer's screen and LED show the profile in it (firmware 0.18; anything else there is ignored).

**Size:** at most **6144 bytes** once minified, nested at most 12 deep (a file is 5). Five
profiles take about 2.5 KB.

## Gestures

| Gesture | What you do |
| --- | --- |
| `index.tap` · `index.doubleTap` · `index.tripleTap` | Tap the index finger to the thumb, once, twice or three times |
| `middle.tap` · `middle.doubleTap` · `middle.tripleTap` | The same with the middle finger |
| `middle.hold` | Hold the middle finger to the thumb. A `hold:` chord stays pressed until you let go. Anything else happens at the start of the hold, with a short buzz |
| `index.hold` | Pinch, hold for a moment and let go **without turning** (or moving the pointer). Usually `menu` |
| `swipe.up` · `swipe.down` · `swipe.left` · `swipe.right` | Swipe the thumb along the side of the index finger |
| `dial.cw` · `dial.ccw` | Pinch and turn the wrist: one step per 9° detent, clockwise or anticlockwise. Mirrored on the left wrist, so "clockwise" is the same turn on either hand |
| `flick.up` · `flick.down` · `flick.left` · `flick.right` | Pinch, hold, and flick the wrist (the way the air mouse would go: bend the hand up or down, or swing it left or right). It fires during the hold, once per flick, so you can flick again before letting go. Firmware 0.15.0 |
| `band.<event>` · `band.<finger>.<event>` | Whatever the band itself reports, as it reports it (below). Firmware 0.15.0 |

**Flicks** need wrist motion, so the first flick of a pinch waits for it to start (a moment), and
the motion stays on for 30 s after a pinch in a profile with flicks. A flick back the other way
right after one isn't a second flick. A pinch that flicked or turned isn't `index.hold` when it
lets go. A `pointer` profile has no flicks on a computer or a phone: there the pinch moves the pointer.

### Band events (experimental)

The band's own gesture messages name a finger (`thumb`, `index`, `middle`) and an event. The
named gestures above are built from them; `band.` gestures are the messages themselves, so you can
try everything the band can say. `band.index.click` fires when a message from the index finger
says `click`; `band.click` fires for any finger. Both fire alongside the named gestures, so
`band.index.singleTap` and `index.tap` are the same tap. Events (the band's two tables):

- `press` `release` `tap` `doubletap` `click` `up` `down` `left` `right` `wake` `swipeIn`
  `swipeOut` `ia` `partialPress` `partialRelease` `partialClick` `partialUp` `partialDown`
  `partialLeft` `partialRight`
- `singleTap` `doubleTap` `buttonHold` `buttonRelease` `buttonUp` `buttonDown` `buttonLeft`
  `buttonRight` `buttonPress` `buttonHoldRelease`

Many of these are never sent, or only in some band states: the app's **Gesture lab** shows what
yours sends as you do it. The same message repeated within 0.15 s fires once.

**Taps wait only when they must.** The band reports every tap. A single tap acts at once unless
the same profile also binds the double tap of that finger. Then it waits 0.4 s to rule out a second
tap. Likewise a double tap waits only if the triple tap is bound. Double taps alone, as in the
built-in profiles, have no delay.

**Wrist motion** costs the band battery, so it streams only during a pinch hold, and only in a
profile that uses it: `pointer`, or a bound `dial.cw` or `dial.ccw`.

## Actions

A gesture maps to one action string, or to an object of them by kind of host:

```json
"middle.doubleTap": { "phone": "phoneMute", "computer": "key:cmd+shift+m", "tv": "none", "default": "media:mute" }
```

The most specific kind wins (`mac` beats `computer`), then `default`. `"none"` means nothing, even
when there's a default. Keys are `phone`, `computer`, `mac`, `windows`, `linux`, `tv` and `default`.

| Action | Does | Hosts |
| --- | --- | --- |
| `none` | Nothing | |
| `media:playPause` · `media:next` · `media:previous` · `media:volumeUp` · `media:volumeDown` · `media:mute` | Media keys | All |
| `media:voice` | Apple's microphone key: dictation on a Mac, Siri on an iPhone | All |
| `phoneMute` | A headset's phone-mute button (mutes a call) | Phone |
| `call:answer` · `call:end` | Answers the ringing call; declines it, or hangs up the call in progress. iPhone (it shares its notifications with the dongle: see below) | Phone |
| `call:toggle` | One gesture for both: answers a ringing call, else hangs up the one in progress. Works whichever host is active (firmware 0.17) | Phone |
| `key:<chord>` | A key with modifiers, pressed and released: `key:enter`, `key:cmd+shift+m`, `key:ctrl+alt+delete`, `key:f5`, `key:]` | Computer, TV |
| `hold:<chord>` | Pressed while `middle.hold` lasts (push-to-talk), released with the finger, or after 60 s | Computer, TV |
| `type:<text>` | Types 1–64 printable ASCII characters (US layout) | Computer, TV |
| `mouse:click` · `mouse:rightClick` · `mouse:middleClick` | Mouse buttons | Computer, iPhone (AssistiveTouch on; firmware 0.16) |
| `mouse:point` | `middle.hold` only: the air mouse while the finger is held (turn the forearm to move it), off when it lets go. Index taps in the next 3 s click where it stopped (firmware 0.17) | Computer, iPhone (AssistiveTouch on) |
| `mouse:button4` … `mouse:button8` | Extra mouse buttons. A computer: 4 is back, 5 forward. An iPhone with AssistiveTouch: give each one an action (Settings › Accessibility › Touch › AssistiveTouch › Devices: Home, App Switcher, Control Center, Notification Center, Screenshot, Lock Screen, Siri, a Shortcut...). Firmware 0.16 | Computer, iPhone |
| `mouse:scrollUp` · `mouse:scrollDown`, optionally `:<1–20>` | Wheel steps (default 4) | Computer, iPhone |
| `profile:<id>` · `profile:next` · `profile:previous` | Switch this host's profile (`next`/`previous` skip profiles it can't use, and stay on the same level: see Modes) | |
| `profile:back` · `profile:home` · `profile:app` | Modes (firmware 0.17): back down to the profile this one was entered from (home if none; at home, home's buzz again); straight home; up into the profile listing the computer's app in front | |
| `host:next` · `host:previous` | Send gestures to the next or previous connected host | |
| `host:<kind>` | To the first connected host of a kind: `host:phone`, `host:computer`, `host:mac`, `host:tv`, … | |
| `menu` | Opens the letter menu | |
| `write` · `write:<3–60>` | Handwriting on (two buzzes): what you write is typed. Each letter restarts the timer; one buzz when it turns off, 10 s (or the given seconds) after the last. Again while it's on: off now | Computer, TV |
| `buzz:<pattern>` | Plays a buzz pattern (a built-in one or one of the file's `buzzes`) | All |
| `apps:next` · `apps:previous` | The app switcher: ⌘Tab (Alt+Tab on Windows and Linux), or with Shift. On a flick, ⌘ stays down until the pinch lets go, so each flick moves one app and letting go picks it. Elsewhere it's one ⌘Tab: back to the last app | Computer |

**A binding's own buzz:** the object form may add `"buzz"`, a pattern played when its action runs:
`"flick.left": { "default": "media:previous", "buzz": "tick" }`. Without one, the set's
`feedback.gesture` plays (none by default).

**Chords:** modifiers `cmd` (also `command`, `win`, `super`), `ctrl`, `alt` (also `option`) and
`shift`, joined with `+`, then one key. Windows and Linux get `cmd` as Ctrl, so `key:cmd+c` copies
everywhere. Keys:

- `a`–`z` and `0`–`9`; a capital letter adds Shift;
- `enter`, `escape`, `backspace`, `tab`, `space`, `delete` (forward), `insert`;
- `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`;
- `f1`–`f12`, `capslock`, `printscreen`, `menu`;
- any US-keyboard symbol: `- = [ ] \ ; ' ` , . /`, and their shifted versions `_ + { } | : " ~ < > ? ! @ # $ % ^ & * ( )`.

`key:cmd++` is ⌘ and plus.

## Modes and `everywhere`

Firmware 0.17 treats profiles as modes, with a way back. **Home** is the host's start profile
(`start`). Going up, to a profile by id, `profile:app` or the menu, remembers where you came
from (two levels at most); `profile:back` goes back down one, and from anywhere, backing out
enough lands at home, which plays home's own `buzz` (give it a pattern nothing else uses).
`profile:next` / `previous` move sideways, on the same level. The app in front still switches a
computer's profile by itself; back from there goes to where it was, and `profile:app` goes up
into it again.

`everywhere` (optional, at the top of the file) binds gestures in every profile, the way a
profile's `gestures` do, and wins over a profile's own binding for the kinds of host it covers
(a `computer`-only one leaves the phone the profile's own). Keep it for what must never change:

```json
"everywhere": {
  "flick.down": "profile:back",
  "flick.up": { "computer": "profile:app" },
  "middle.tripleTap": "call:toggle"
}
```

Profile ids can't be `next`, `previous`, `back`, `home` or `app` (they mean those targets).

## Buzz patterns

A pattern is pulses and pauses, in milliseconds: `250 _200 250*90` is a 250 ms pulse, a 200 ms
pause, and a 250 ms pulse at strength 90. Strength is 1–100 (default 70). Pulses are 20–2000 ms,
pauses 20–3000 ms, at most 16 steps, 8 s and 120 characters; a pattern starts and ends with a
pulse. The band takes each pulse as its own request, so pauses under about 100 ms may stretch.

Built in (a file's `buzzes` may redefine any of them, and the new one is used everywhere):

| Name | Pattern | Name | Pattern |
| --- | --- | --- | --- |
| `tick` | `40*55` | `done` | `250*78 _200 250*78` |
| `tap` | `60*63` | `question` | `70*67 _130 70*67 _130 380*86` |
| `double` | `60*63 _190 60*63` | `error` | `900*90` |
| `triple` | three taps | `ring` | `600*90 _300 600*90` |
| `quad` | four taps | `heartbeat` | `90*85 _110 70*45` |
| `long` | `400*78` | `rise` · `fall` | four pulses getting stronger · weaker |
| `nudge` | `30*50` | | |

Names are 1–16 of `a`–`z`, `0`–`9` and `-` (not `none`).

```json
"buzzes": { "zap": "40*100 _60 40*100", "done": "120 _80 120 _80 300*95" },
"feedback": { "alert.question": "zap", "connected": "none", "gesture": "tick" }
```

**`feedback`** says what the band buzzes by itself. Each moment takes a pattern's name or `none`:

| Moment | When | Default |
| --- | --- | --- |
| `connected` | The band connected to the dongle | `tap` |
| `refused` | Something didn't work: a profile this host can't use, no host to switch to, a letter the menu doesn't know, no call to answer | `long` |
| `host.phone` · `host.computer` | Gestures now go to a phone · a computer or TV | `tap` · `double` |
| `alert.done` · `alert.question` · `alert.error` | A computer's helper (np-appwatch): an agent finished, asks something, failed | `done` · `question` · `error` |
| `call.ringing` | An iPhone call rings (again every 3 s, or after the pattern if it's longer) | `ring` |
| `write.on` · `write.off` | Handwriting on: write now · off | `double` · `tap` |
| `menu.ready` | The letter menu is ready for its letter | `double` |
| `hold.start` | `middle.hold` began (speak now) | `tick` |
| `gesture` | Any gesture that ran an action, unless its binding has its own `buzz` | `none` |

Switching profile plays that profile's `buzz` instead of `host.*`. Over the control service,
`buzz <name>` plays a pattern of the dongle's set and `buzz try <pattern>` plays one you're
designing (the app's pattern editor).

## The letter menu

Pinch, hold and let go (the default `index.hold`). After **two buzzes**, write one letter on any
surface: the band's handwriting model is on for just that letter, for up to 6 s. What happens next:

- **A letter in `menu`:** its action runs. Switching profile buzzes that profile's `buzz` count, and
  switching host buzzes once for a phone and twice for a computer.
- **A letter not in `menu`, or no letter:** one long buzz.

The model often reads `l`, `1`, `i` and `|` as each other, so the menu treats them as one letter (it
looks up `l`).

**Switching without the menu:** bind `profile:next` to `index.hold` for one pinch per profile, with
no handwriting and no wait.

## Handwriting on demand

The band's handwriting model costs battery, so a `typing` profile puts it to sleep after 90 s with
nothing written. `write` is the short version for any profile: bind it to, say, `index.tripleTap`,
and handwriting is on just while you write. Two buzzes: write. Stop for 10 s (`write:20` for 20)
and one buzz says it's off. Doing it again while it's on turns it off at once. Switching host or
profile turns it off too.

Binding `index.tripleTap` makes that finger's double tap wait 0.4 s (to rule out a third tap), so
a profile that uses the index double tap for something quick may prefer `middle.tripleTap`.

## Phone calls (iPhone)

Since dongle firmware 0.14.0 the dongle reads a connected iPhone's notifications, through Apple's
Notification Center Service (ANCS, what watches and fitness bands use). It only looks at calls:

- A ringing call buzzes the band: two long pulses, again every 3 s, until it stops ringing (or
  60 s).
- `call:answer` answers it. `call:end` declines it, or hangs up the call in progress.
- With no call, either one gives the long "didn't work" buzz.

iOS asks once whether to share notifications with "NP Band Remote". If you said no, turn on
Settings › Bluetooth › NP Band Remote (ⓘ) › Share System Notifications. An Android phone has no
ANCS: these do nothing there.

## Following the app in front (np-appwatch)

A Mac running [np-appwatch](https://github.com/Shlok-Bhakta/homebrew-np) (`brew install
shlok-bhakta/np/np-appwatch`) tells the dongle which app is in front (dongle firmware 0.12.0 on):

- An app a profile lists in `apps` comes to the front: that Mac switches to the profile (no buzz:
  it follows every app switch).
- Any other app: the Mac goes back to the profile it had before.
- Switching by hand sticks until the next listed app.
- Pausing or quitting np-appwatch puts the Mac back in its own profile.

Only that Mac changes: the phone and the TV keep theirs. Automatic switches aren't saved; the
helper says which app is in front again whenever it reconnects.

## Sending a file to the dongle

The app does this. Over the control service ([CONTROL.md](../band-dongle/CONTROL.md)):

1. `profiles begin <bytes> <sha>`: `<sha>` is the first 8 hex digits of the file's SHA-256.
2. `profiles data <offset> <base64>`, repeated until every byte is sent.
3. `profiles commit`. The dongle checks the length, the hash and the file, saves it, and applies it
   to every host.

The status then shows `ph`, the stored file's hash (`builtin` for the built-in set). The log says
`PROFILES: saved …` or `PROFILES: refused: <reason>`. `profiles reset` goes back to the built-in set.

`profiles show` (0.12.1) reads the set back. Over USB, `make profiles-get` and `make
profiles-put` in `firmware/band-dongle` read and write it; the app's **Get the dongle's set** then
takes it onto the phone. The set lives in the dongle's settings storage, so firmware updates keep it.

## Test vectors

[`tests/valid`](tests/valid) holds files both checkers must accept. [`tests/invalid`](tests/invalid)
holds files they must refuse, and `expected.tsv` gives the path of each one's error.
