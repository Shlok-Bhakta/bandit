import Foundation

// Names and short explanations of the profile vocabulary (PROFILES.md), for the app's pickers,
// its Reference screen and the brief it hands an AI assistant along with a file.

extension ProfileGesture {
    public enum Group: String, CaseIterable, Sendable {
        case index = "Index finger", middle = "Middle finger", swipe = "Thumb swipes", dial = "Pinch and turn"
    }

    public var group: Group {
        switch self {
        case .indexTap, .indexDoubleTap, .indexTripleTap, .indexHold: .index
        case .middleTap, .middleDoubleTap, .middleTripleTap, .middleHold: .middle
        case .swipeUp, .swipeDown, .swipeLeft, .swipeRight: .swipe
        case .dialCW, .dialCCW: .dial
        }
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
        }
    }

    public var detail: String {
        switch self {
        case .indexTap, .indexDoubleTap, .indexTripleTap: "Tap the index finger to the thumb. A single tap waits 0.4 s only if the double tap is bound too."
        case .middleTap, .middleDoubleTap, .middleTripleTap: "Tap the middle finger to the thumb."
        case .indexHold: "Pinch, hold a moment and let go without turning. Usually menu."
        case .middleHold: "Hold the middle finger to the thumb. A hold: chord stays pressed until you let go; anything else happens at the start."
        case .swipeUp, .swipeDown, .swipeLeft, .swipeRight: "Swipe the thumb along the side of the index finger."
        case .dialCW, .dialCCW: "Pinch and turn the wrist: one step per 9° detent (mirrored on the left wrist)."
        }
    }

    /// `hold:` works here only.
    public var allowsHold: Bool { self == .middleHold }
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
        ("none", "Nothing (beats a default)"),
        ("media:playPause · next · previous · volumeUp · volumeDown · mute", "Media keys, every host"),
        ("media:voice", "Dictation on a Mac, Siri on an iPhone"),
        ("phoneMute", "A headset's phone-mute button (phones)"),
        ("call:answer · call:end", "Answer the ringing call; decline it, or hang up (an iPhone sharing its notifications with the dongle). A ringing call buzzes the band"),
        ("key:<chord>", "A key with modifiers, pressed and released (computers, TVs): key:enter, key:cmd+shift+m, key:f5, key:]"),
        ("hold:<chord>", "Held while middle.hold lasts (push-to-talk), released with the finger or after 60 s"),
        ("type:<text>", "Types 1–64 printable ASCII characters (US layout)"),
        ("mouse:click · rightClick · middleClick", "Mouse buttons (computers)"),
        ("mouse:scrollUp · scrollDown, optionally :<1–20>", "Wheel steps (default 4)"),
        ("profile:<id> · profile:next · profile:previous", "Switch this host's profile"),
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
        This is an np-profiles file (version 1): gesture profiles for a Meta Neural Band remote dongle. Edit it as I ask and reply with the whole file as one JSON code block.

        Rules:
        - Top level: "format": "np-profiles", "version": 1, optional "name" (≤ 40 characters), optional "menu" (one letter a–z or digit 0–9 → an action other than hold: and menu), optional "start" ({"phone"|"computer"|"tv": profile id}; the profile must allow that kind), "profiles": 1–12 profiles.
        - A profile: "id" (1–16 of a–z, 0–9, -; unique), "name" (1–24 characters), optional "buzz" (1–4), "hosts" (any of phone, computer, mac, windows, linux, tv; default everyone), "typing" (handwriting is typed on computers), "pointer" (pinch-hold and move the wrist moves the mouse on computers; the dial is off), "gestures" (gesture → action), "apps" (up to 16 Mac bundle ids, like com.google.Chrome: a computer whose helper reports one of them in front switches to this profile; each app in one profile only). Optional app fields: "description", "symbol" (an SF Symbol name), "color" ("#rrggbb").
        - A gesture maps to one action string, or to an object by host kind: {"phone": …, "computer": …, "mac": …, "windows": …, "linux": …, "tv": …, "default": …}. The most specific kind wins (mac beats computer), then default.
        - At most \(maxBytes) bytes minified. Windows and Linux get cmd as Ctrl, so key:cmd+c copies everywhere.

        Gestures:
        \(gestures)

        Actions:
        \(actions)

        Chords: modifiers \(modifierNames.joined(separator: ", ")) (also command, win, super, option) joined with +, then one key: a–z (a capital adds Shift), 0–9, \(namedKeys.joined(separator: ", ")), or a US-keyboard symbol: \(symbolKeys). key:cmd++ is ⌘ and plus.
        """
    }
}
