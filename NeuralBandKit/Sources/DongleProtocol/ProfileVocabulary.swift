import Foundation

// Names and short explanations of the profile vocabulary (PROFILES.md), for the app's pickers,
// its Reference screen and the brief it hands an AI assistant along with a file.

extension ProfileGesture {
    public enum Group: String, CaseIterable, Sendable {
        case index = "Taps", middle = "Holds", swipe = "Swipes", dial = "Dial", flick = "Flicks", band = "Band events (experimental)"
    }

    public var group: Group {
        if rawValue.hasPrefix("band.") { return .band }
        if rawValue.hasPrefix("flick.") { return .flick }
        if rawValue.hasSuffix("hold") { return .middle }
        if rawValue.hasPrefix("swipe.") { return .swipe }
        if rawValue.hasPrefix("dial.") { return .dial }
        return .index
    }

    public var title: String {
        switch self {
        case .indexTap: "Index tap"
        case .indexDoubleTap: "Index double tap"
        case .indexTripleTap: "Index triple tap"
        case .indexHold: "Index pinch-hold"
        case .middleTap: "Middle tap"
        case .middleDoubleTap: "Middle double tap"
        case .middleTripleTap: "Middle triple tap"
        case .middleHold: "Middle hold"
        case .swipeUp: "Swipe up"
        case .swipeDown: "Swipe down"
        case .swipeLeft: "Swipe left"
        case .swipeRight: "Swipe right"
        case .dialCW: "Turn clockwise"
        case .dialCCW: "Turn anticlockwise"
        default: rawValue.hasPrefix("flick.") ? "Flick " + rawValue.dropFirst(6) : rawValue
        }
    }

    public var detail: String {
        switch self {
        case .indexTap, .indexDoubleTap, .indexTripleTap: "Tap the index finger to the thumb. A single tap waits 0.4 s only if the double tap is bound too."
        case .middleTap, .middleDoubleTap, .middleTripleTap: "Tap the middle finger to the thumb."
        case .indexHold: "Pinch, hold a moment and let go without turning. Usually menu."
        case .middleHold: "Hold the middle finger to the thumb. A hold: chord stays pressed until you let go, and mouse:point moves the pointer until then; anything else happens at the start."
        case .swipeUp, .swipeDown, .swipeLeft, .swipeRight: "Swipe the thumb along the side of the index finger."
        case .dialCW, .dialCCW: "Pinch and turn the wrist: one step per 9° detent (mirrored on the left wrist)."
        default: rawValue.hasPrefix("flick.") ? "Pinch, hold and flick the wrist. Repeat during the hold. Firmware 0.15.0. Air mouse takes priority on computers." : "Raw band event, alongside named gestures. Firmware 0.15.0. Discover events in Gesture lab."
        }
    }

    /// `hold:` works here only.
    public var allowsHold: Bool { self == .middleHold }
    /// `mouse:point` works here only.
    public var allowsPoint: Bool { self == .middleHold }
}

extension ProfileTarget {
    /// The `profile:` words that aren't profile ids (`ProfileFormat.reservedIDs`), with their titles.
    public static let words: [(word: String, title: String)] = [
        ("next", "Next profile"), ("previous", "Previous profile"),
        ("back", "Back"), ("home", "Home"), ("app", "Up into the app's mode"),
    ]

    /// What `profile:back`, `home` and `app` do, for pickers.
    public static func detail(_ word: String) -> String? {
        switch word {
        case "back": "Down to the profile this one was entered from. Home if there is none; at home, home's buzz again."
        case "home": "Straight to this host's start profile, whatever was entered on the way."
        case "app": "Up into the profile that lists the computer's app in front (its apps). Computers with bandit-mac."
        case "next", "previous": "Sideways, on the same level, skipping profiles this host can't use."
        default: nil
        }
    }
}

extension ProfileAction {
    /// `mouse:point` in pickers and lists.
    public static let pointTitle = "Air mouse while held"
}

extension ProfileHosts {
    public var title: String {
        switch self {
        case .phone: "Phone"
        case .computer: "Any computer"
        case .mac: "Mac"
        case .windows: "Windows"
        case .linux: "Linux"
        case .tv: "TV"
        }
    }
}

extension MediaKey {
    public var title: String {
        switch self {
        case .playPause: "Play/Pause"
        case .next: "Next track"
        case .previous: "Previous track"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .mute: "Mute"
        case .voice: "Voice (dictation, Siri)"
        }
    }
}

extension MouseButton {
    public var title: String {
        switch self {
        case .left: "Click"
        case .right: "Right click"
        case .middle: "Middle click"
        case .button4: "Button 4"
        case .button5: "Button 5"
        case .button6: "Button 6"
        case .button7: "Button 7"
        case .button8: "Button 8"
        }
    }
}

extension ProfileFormat {
    /// Key names `key:` and `hold:` take besides letters, digits and symbols.
    public static let namedKeys = ["enter", "escape", "backspace", "tab", "space", "delete", "insert",
                                   "left", "right", "up", "down", "home", "end", "pageup", "pagedown",
                                   "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
                                   "capslock", "printscreen", "menu"]
    public static let modifierNames = ["cmd", "ctrl", "alt", "shift"]
    public static let symbolKeys = "- = [ ] \\ ; ' ` , . / _ + { } | : \" ~ < > ? ! @ # $ % ^ & * ( )"

    /// Every action form, with what it does (the Reference screen and the assistant brief).
    public static let actionReference: [(action: String, meaning: String)] = [
        ("buzz:<pattern>", "Play a built-in or custom buzz pattern"),
        ("apps:next · apps:previous", "Computer app switcher. Best on flicks: keep pinching to browse, release to choose"),
        ("none", "Nothing (beats a default)"),
        ("media:playPause · next · previous · volumeUp · volumeDown · mute", "Media keys, every host"),
        ("media:voice", "Dictation on a Mac, Siri on an iPhone"),
        ("phoneMute", "A headset's phone-mute button (phones)"),
        ("call:answer · call:end", "Answer the ringing call; decline it, or hang up (an iPhone sharing its notifications with the dongle). A ringing call buzzes the band"),
        ("call:toggle", "One gesture for both: answers a ringing call, else hangs up the one in progress. Works whichever host is active. Firmware 0.17"),
        ("key:<chord>", "A key with modifiers, pressed and released (computers, TVs): key:enter, key:cmd+shift+m, key:f5, key:]"),
        ("hold:<chord>", "Held while middle.hold lasts (push-to-talk), released with the finger or after 60 s"),
        ("type:<text>", "Types 1–64 printable ASCII characters (US layout)"),
        ("mouse:click · rightClick · middleClick", "Mouse buttons (computers; an iPhone with AssistiveTouch on)"),
        ("mouse:button4 … button8", "Extra mouse buttons. A computer: 4 back, 5 forward. An iPhone: AssistiveTouch gives each one an action, like Home, App Switcher, Control Center, Screenshot or a Shortcut. Firmware 0.16"),
        ("mouse:scrollUp · scrollDown, optionally :<1–20>", "Wheel steps (default 4)"),
        ("mouse:point", "middle.hold only: the air mouse while the finger is held (turn the forearm to move it). Index taps in the next 3 s click where it stopped. Computers; an iPhone with AssistiveTouch on. Firmware 0.17"),
        ("profile:<id> · profile:next · profile:previous", "Switch this host's profile. To an id goes up a level (back remembers where from); next and previous move sideways, skipping profiles it can't use"),
        ("profile:back · profile:home · profile:app", "Modes (firmware 0.17): back down to where this profile was entered from (home if none; at home, home's buzz again); straight home (the start profile); up into the profile listing the computer's app in front"),
        ("host:next · host:previous · host:<kind>", "Send gestures to another connected host"),
        ("menu", "The letter menu: write one letter next"),
        ("write · write:<3–60>", "Handwriting on (two buzzes), typed on the computer; off (one buzz) after 10 s, or the given seconds, with nothing written. Again while on: off now"),
    ]

    /// A self-contained description of the format to paste into an AI assistant with a file, so it
    /// can edit it without the docs.
    public static var assistantBrief: String {
        let gestures = ProfileGesture.allCases.map { "- `\($0.rawValue)`: \($0.detail)" }.joined(separator: "\n")
        let actions = actionReference.map { "- `\($0.action)`: \($0.meaning)" }.joined(separator: "\n")
        return """
        This is a bandit-profiles file (version 1): gesture profiles for a Meta Neural Band remote dongle. Edit it as I ask and reply with the whole file as one JSON code block.

        Rules:
        - Top level: "format": "bandit-profiles", "version": 1, optional "name" (≤ 40 characters), optional "menu" (one letter a–z or digit 0–9 → an action other than hold:, mouse:point and menu), optional "start" ({"phone"|"computer"|"tv": profile id}; the profile must allow that kind; it's also that host's home), optional "everywhere" (gesture → action, like a profile's "gestures": in every profile, winning over the profile's own for the host kinds it covers; e.g. "flick.down": "profile:back"), "profiles": 1–12 profiles.
        - A profile: "id" (1–16 of a–z, 0–9, -; unique; not next, previous, back, home or app), "name" (1–24 characters), optional "buzz" (1–4 or a pattern name), "hosts" (any of phone, computer, mac, windows, linux, tv; default everyone), "typing" (handwriting is typed on computers), "pointer" (pinch-hold and move the wrist moves the mouse on computers, and on an iPhone with AssistiveTouch on (firmware 0.16); the dial and flicks are off there), "gestures" (gesture → action), "apps" (up to 16 Mac bundle ids, like com.google.Chrome: a computer whose helper reports one of them in front switches to this profile; each app in one profile only). Optional app fields: "description", "symbol" (an SF Symbol name), "color" ("#rrggbb").
        - A gesture maps to one action string, or to an object by host kind: {"phone": …, "computer": …, "mac": …, "windows": …, "linux": …, "tv": …, "default": …}. The most specific kind wins (mac beats computer), then default.
        - At most \(maxBytes) bytes minified. Windows and Linux get cmd as Ctrl, so key:cmd+c copies everywhere.

        Buzzes: optional top-level "buzzes" maps up to 16 names (1–16 of a–z, 0–9, -, except none) to pattern strings. Built-ins: \(builtinBuzzes.map(\.name).joined(separator: ", ")). A pattern is pulses ms or ms*strength (1–100, default 70), and pauses _ms; e.g. 250 _200 250*90. Pulses 20–2000 ms, pauses 20–3000 ms, up to 16 steps, 8000 ms, 120 bytes; start/end with a pulse. Built-ins may be redefined.
        Optional "feedback" maps moments (\(BuzzFeedback.all.map(\.name).joined(separator: ", "))) to a pattern name or none. A binding object may also contain "buzz": "tick".

        Gestures:
        \(gestures)

        Actions:
        \(actions)

        Chords: modifiers \(modifierNames.joined(separator: ", ")) (also command, win, super, option) joined with +, then one key: a–z (a capital adds Shift), 0–9, \(namedKeys.joined(separator: ", ")), or a US-keyboard symbol: \(symbolKeys). key:cmd++ is ⌘ and plus.
        """
    }
}
