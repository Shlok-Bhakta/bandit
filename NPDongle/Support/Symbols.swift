import DongleProtocol
import SwiftUI

extension DongleCommand.HostType {
    var symbol: String {
        switch self {
        case .phone: "iphone"
        case .mac: "laptopcomputer"
        case .windows: "pc"
        case .linux: "desktopcomputer"
        case .tv: "tv"
        }
    }

    var caption: String {
        switch self {
        case .phone: "Phone · media keys"
        case .tv: "TV · arrows, OK, Back, volume"
        default: "\(label) · keyboard, mouse, media keys"
        }
    }

    /// How to connect "NP Band Remote" from this kind of device, once the pairing window is open.
    var pairingSteps: [String] {
        let name = "“\(DongleGATT.advertisedName)”"
        return switch self {
        case .phone: [
            "On the other phone, open Settings › Bluetooth.",
            "Tap \(name) under Other Devices and confirm the pairing.",
            "Android: Settings › Connected devices › Pair new device.",
        ]
        case .mac: [
            "Open System Settings › Bluetooth.",
            "Find \(name) under Nearby Devices and click Connect.",
            "If macOS asks you to identify the keyboard, close that window: it isn't needed.",
        ]
        case .windows: [
            "Open Settings › Bluetooth & devices › Add device.",
            "Choose Bluetooth, then \(name).",
            "Windows gets Ctrl where a Mac gets ⌘, so key:cmd+c still copies.",
        ]
        case .linux: [
            "Open your desktop's Bluetooth settings and pair \(name),",
            "or in a terminal: bluetoothctl, then scan on, pair <address>, trust <address>, connect <address>.",
            "Linux gets Ctrl where a Mac gets ⌘.",
        ]
        case .tv: [
            "Open the TV's settings: Remotes & Accessories, or Bluetooth devices.",
            "Add a Bluetooth device (a keyboard or remote) and choose \(name).",
            "Gestures send arrows, OK, Back and volume.",
        ]
        }
    }
}

extension DongleStatus.Host {
    var displayName: String { name.isEmpty ? "Host \(handle)" : name }
}

extension ProfileGesture {
    var symbol: String {
        switch self {
        case .indexTap: "hand.point.up"
        case .indexDoubleTap: "hand.tap"
        case .indexTripleTap: "hand.tap.fill"
        case .indexHold: "hand.pinch"
        case .middleTap: "hand.point.up.left"
        case .middleDoubleTap: "hand.tap"
        case .middleTripleTap: "hand.tap.fill"
        case .middleHold: "hand.raised"
        case .swipeUp: "arrow.up"
        case .swipeDown: "arrow.down"
        case .swipeLeft: "arrow.left"
        case .swipeRight: "arrow.right"
        case .dialCW: "arrow.clockwise"
        case .dialCCW: "arrow.counterclockwise"
        default: rawValue.hasPrefix("flick.") ? "hand.draw" : "waveform.path"
        }
    }

    var tint: Color {
        switch group {
        case .index: Theme.accent
        case .middle: Theme.mint
        case .swipe: Theme.violet
        case .dial: Theme.warn
        case .flick: Theme.mint
        case .band: Theme.violet
        }
    }
}

extension ProfileHosts {
    var symbol: String {
        switch self {
        case .phone: "iphone"
        case .computer: "desktopcomputer"
        case .mac: "laptopcomputer"
        case .windows: "pc"
        case .linux: "terminal"
        case .tv: "tv"
        }
    }
}

extension GestureProfile {
    static let defaultSymbol = "hand.wave"

    /// Its own symbol, else one for the built-in ids (the firmware's file has none), else a hand.
    var displaySymbol: String { symbol.flatMap { $0.isEmpty ? nil : $0 } ?? Self.builtinSymbols[id] ?? Self.defaultSymbol }

    static let builtinSymbols = ["media": "music.note", "slides": "play.rectangle", "write": "pencil.and.scribble",
                                 "copilot": "sparkles", "tv": "tv"]
    /// Its own colour, else one for the built-in ids, else the accent.
    var tint: Color { Theme.color(hex: color ?? Self.builtinColors[id]) ?? Theme.accent }

    static let builtinColors = ["media": "#ff616b", "slides": "#ffb840", "write": "#bf80ff", "copilot": "#4cc9f0", "tv": "#a6e05a"]

    /// "Everyone", or the kinds it's for.
    var hostsSummary: String {
        hosts.isEmpty ? "Every host" : hosts.map { ProfileHosts(rawValue: $0)?.title ?? $0 }.joined(separator: ", ")
    }
}

enum BandState {
    static func describe(_ state: String) -> String {
        switch state {
        case "live": "Live"
        case "connecting": "Connecting"
        case "searching": "Searching for the band"
        case "paused": "Released for Neural Playground"
        case "no-owner": "No owner key on the dongle"
        default: state
        }
    }

    static func color(_ state: String?) -> Color {
        switch state {
        case "live": Theme.mint
        case "connecting", "searching": Theme.accent
        case "paused": Theme.warn
        case nil: .gray
        default: Theme.danger
        }
    }
}

/// SF Symbols that suit a profile, for the editor's picker.
enum ProfileSymbols {
    static let suggestions = [
        "hand.wave", "music.note", "play.rectangle", "rectangle.on.rectangle", "pencil.and.scribble", "keyboard",
        "computermouse", "sparkles", "tv", "gamecontroller", "mic", "phone", "video", "book", "terminal",
        "paintbrush", "camera", "headphones", "airplayaudio", "lightbulb", "star", "bolt", "house", "car",
    ]
}
