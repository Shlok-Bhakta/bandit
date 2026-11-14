import BandProtocol
import Foundation

public enum Wrist: String, Codable, Sendable, CaseIterable {
    case left, right
    public var hand: Hand { self == .left ? .left : .right }
    public var title: String { self == .left ? "Left wrist" : "Right wrist" }
}

/// App-side corrections for one wrist. These relabel recognized gestures; they cannot fix what the
/// band's own classifier recognizes (see `WristConfiguration` notes).
public struct WristProfile: Codable, Equatable, Sendable {
    /// Swap left/right thumb swipes.
    public var invertHorizontal: Bool
    /// Swap up/down thumb swipes.
    public var invertVertical: Bool
    /// Reverse the pinch-dial rotation (derived by the app from the gyro).
    public var invertDial: Bool

    public init(invertHorizontal: Bool = false, invertVertical: Bool = false, invertDial: Bool = false) {
        self.invertHorizontal = invertHorizontal
        self.invertVertical = invertVertical
        self.invertDial = invertDial
    }

    /// Defaults from kinesis's hardware notes: with the band's own hand setting matching the worn
    /// wrist, left-wrist swipes come out correct, while the gyro-derived dial turns the wrong way.
    public static func defaults(for wrist: Wrist) -> WristProfile {
        wrist == .left ? WristProfile(invertDial: true) : WristProfile()
    }
}

/// The app's wrist preference, separate from the band's persisted `is_left_handed` setting.
/// Changing it never writes to the band; `BandClient.syncWristToBand()` does that explicitly.
///
/// Why both exist: the band uses its hand setting itself (kinesis observed correct left-wrist
/// swipes only after setting the band to left). If the band is set to the wrong wrist, app-side
/// inversion can relabel directions, but it cannot make the band's classifier recognize a gesture
/// it misses or confuses — sync the band for that.
public struct WristConfiguration: Codable, Equatable, Sendable {
    public var wrist: Wrist
    public var left: WristProfile
    public var right: WristProfile

    public init(wrist: Wrist = .right, left: WristProfile = .defaults(for: .left), right: WristProfile = .defaults(for: .right)) {
        self.wrist = wrist
        self.left = left
        self.right = right
    }

    public var active: WristProfile {
        get { wrist == .left ? left : right }
        set { if wrist == .left { left = newValue } else { right = newValue } }
    }

    /// Band gesture → normalized gesture for the active wrist.
    public func normalize(_ gesture: RecognizedGesture) -> RecognizedGesture {
        guard case .swipe(let direction) = gesture else { return gesture }
        let profile = active
        switch direction {
        case .left where profile.invertHorizontal: return .swipe(.right)
        case .right where profile.invertHorizontal: return .swipe(.left)
        case .up where profile.invertVertical: return .swipe(.down)
        case .down where profile.invertVertical: return .swipe(.up)
        default: return gesture
        }
    }

    public func normalizeDial(_ degrees: Double) -> Double { active.invertDial ? -degrees : degrees }

    static let defaultsKey = "wrist.configuration.v1"

    public static func load(_ defaults: UserDefaults = .standard) -> WristConfiguration {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(WristConfiguration.self, from: $0) } ?? WristConfiguration()
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Progress of writing the band's hand setting and reading it back.
public enum HandSync: Equatable, Sendable {
    case idle
    case writing(Hand)
    case confirmed(Hand, Date)
    case failed(String)
}
