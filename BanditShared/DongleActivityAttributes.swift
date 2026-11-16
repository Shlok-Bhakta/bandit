import ActivityKit
import Foundation
import SwiftUI

// Compiled into both Bandit and its widget extension: the app starts, updates and ends these
// Live Activities locally with ActivityKit (no push, no App Group); the extension draws them.

/// A dongle firmware update: Lock Screen and Dynamic Island while the package downloads, streams
/// over Bluetooth, is verified and the dongle restarts.
struct DongleUpdateAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable, Sendable {
        case downloading, sending, verifying, restarting, done, failed

        var title: String {
            switch self {
            case .downloading: "Downloading"
            case .sending: "Sending to the dongle"
            case .verifying: "Verifying"
            case .restarting: "Restarting"
            case .done: "Installed"
            case .failed: "Update failed"
            }
        }

        var symbol: String {
            switch self {
            case .downloading: "arrow.down.circle"
            case .sending: "dot.radiowaves.left.and.right"
            case .verifying: "checkmark.shield"
            case .restarting: "arrow.triangle.2.circlepath"
            case .done: "checkmark.seal.fill"
            case .failed: "exclamationmark.triangle.fill"
            }
        }

        var isFinal: Bool { self == .done || self == .failed }
    }

    struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
        /// 0–1 of the package committed on the dongle (downloading: unknown, 0).
        var progress: Double
        /// A short line under the phase (an error, the time left).
        var detail: String

        var percent: Int { Int((progress * 100).rounded()) }
    }

    /// The firmware version being installed.
    var version: String
}

/// What the dongle is doing now: the active host, its profile and the band.
struct DongleStatusAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var connected: Bool
        var hostName: String
        /// An SF Symbol for the host's kind.
        var hostSymbol: String
        var profileName: String
        /// An SF Symbol for the profile (its `symbol`, or a default).
        var profileSymbol: String
        var battery: Int?
        var charging: Bool
        /// `Live`, `Searching`, … (already readable).
        var bandState: String
        var bandLive: Bool
    }

    var dongleName: String
}

/// The few colours both targets draw with (the app's Theme isn't in the extension).
enum ActivityPalette {
    static let accent = Color(red: 0.38, green: 0.58, blue: 1.0)
    static let mint = Color(red: 0.2, green: 0.85, blue: 0.65)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.42)
    static let background = Color(red: 0.05, green: 0.06, blue: 0.12)

    static func color(_ phase: DongleUpdateAttributes.Phase) -> Color {
        switch phase {
        case .done: mint
        case .failed: danger
        case .restarting, .verifying: warn
        default: accent
        }
    }
}
