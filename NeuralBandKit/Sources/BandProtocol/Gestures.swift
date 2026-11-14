import Foundation

/// Relative wrist rotation while an index pinch is held (band-core `dial.rs`).
struct PinchDial: Sendable {
    /// A tap is over well under this; only a pinch that outlasts it arms the dial.
    static let armDelay = 0.18

    private(set) var engaged = false
    private var indexPressed: Double?
    private var middlePressed: Double?
    private var indexCanArm = false
    private var lastGyroAt: Double?
    private var lastDeviceTime: UInt64?
    private var bias = SIMD3<Double>(repeating: 0)
    private var integral = SIMD3<Double>(repeating: 0)
    private var axis: Int?

    private mutating func release() {
        engaged = false
        integral = .zero
        axis = nil
    }

    private func motionFresh(_ now: Double) -> Bool { lastGyroAt.map { now - $0 < 0.35 } ?? false }

    mutating func tick(_ now: Double) {
        if let at = lastGyroAt, now - at >= 0.35 {
            indexPressed = nil
            middlePressed = nil
            release()
        }
        if let at = middlePressed, now - at >= 10 { middlePressed = nil }
        if let at = indexPressed, now - at >= 10 {
            indexPressed = nil
            release()
        }
        if !engaged, indexCanArm, let at = indexPressed, now - at >= Self.armDelay, motionFresh(now) {
            release()
            engaged = true
        }
    }

    mutating func gesture(_ gesture: GestureMessage, now: Double) {
        tick(now)
        let index: Bool
        switch gesture.finger {
        case "index": index = true
        case "middle": index = false
        default: return
        }
        if gesture.synthetic { return }
        let press = gesture.action == "press" || gesture.derivedAction == "buttonPress"
        let released = gesture.action == "release" || gesture.derivedAction == "buttonRelease"
            || gesture.derivedAction == "buttonHoldRelease"
        if press {
            if index, indexPressed == nil {
                indexPressed = now
                indexCanArm = motionFresh(now)
            } else if !index, middlePressed == nil {
                middlePressed = now
            }
        }
        if released {
            if index {
                indexPressed = nil
                indexCanArm = false
                release()
            } else {
                middlePressed = nil
            }
        }
    }

    /// One gyro sample (band clock µs, raw int16 axes). Returns degrees to apply while engaged.
    mutating func gyro(timestamp: UInt64, values: SIMD3<Double>, now: Double) -> Double? {
        tick(now)
        let previous = lastDeviceTime
        lastDeviceTime = timestamp
        lastGyroAt = now
        guard let previous, timestamp > previous, timestamp - previous <= 50_000 else {
            if engaged {
                indexPressed = nil
                release()
            }
            return nil
        }
        let dt = Double(timestamp - previous) / 1e6
        let idle = indexPressed == nil && middlePressed == nil
        let offset = values - bias
        if idle, abs(offset.x) < 45, abs(offset.y) < 45, abs(offset.z) < 45 {
            let k = 1 - exp(-dt / 2)
            bias += offset * k
        }
        // Observed 0.07 °/s gyro scale; a relative, experimental estimate.
        let delta = (values - bias) * (0.07 * dt)
        guard engaged else { return nil }
        integral += delta
        if axis == nil {
            var dominant = 0
            for i in 1..<3 where abs(integral[dominant]) < abs(integral[i]) { dominant = i }
            if abs(integral[dominant]) >= 0.25 {
                axis = dominant
                return integral[dominant]
            }
        }
        return axis.map { delta[$0] }
    }
}

public enum SwipeDirection: String, Sendable, CaseIterable, Codable { case left, right, up, down }

public enum Finger: String, Sendable, CaseIterable, Codable { case index, middle }

public enum TapKind: String, Sendable, CaseIterable, Codable { case tap, doubleTap, hold }

/// A user-level gesture, emitted at most once per physical gesture.
public enum RecognizedGesture: Sendable, Hashable, Codable {
    case swipe(SwipeDirection)
    case tap(Finger, TapKind)

    public var title: String {
        switch self {
        case .swipe(let direction): "Thumb swipe \(direction.rawValue)"
        case .tap(let finger, .tap): "\(finger.rawValue.capitalized) tap"
        case .tap(let finger, .doubleTap): "\(finger.rawValue.capitalized) double tap"
        case .tap(let finger, .hold): "\(finger.rawValue.capitalized) hold"
        }
    }

    public static let all: [RecognizedGesture] =
        SwipeDirection.allCases.map { .swipe($0) }
        + Finger.allCases.flatMap { finger in TapKind.allCases.map { .tap(finger, $0) } }
}

/// The band reports many gestures twice (raw action and derived action) and may repeat messages;
/// this yields each gesture once (band-core `GestureRouter`). `reset` on reconnect.
public struct GestureRouter: Sendable {
    private var seen: [String] = []
    private var last: [RecognizedGesture: (derived: Bool, at: Double)] = [:]

    public init() {}

    public mutating func reset() {
        seen.removeAll()
        last.removeAll()
    }

    private static func swipe(named name: String) -> SwipeDirection? {
        switch name {
        case "left": .left
        case "right": .right
        case "up": .up
        case "down": .down
        default: nil
        }
    }

    private static func derivedSwipe(_ name: String) -> SwipeDirection? {
        switch name {
        case "buttonLeft": .left
        case "buttonRight": .right
        case "buttonUp": .up
        case "buttonDown": .down
        default: nil
        }
    }

    private static func derivedTap(_ name: String) -> TapKind? {
        switch name {
        case "singleTap": .tap
        case "doubleTap": .doubleTap
        case "buttonHold": .hold
        default: nil
        }
    }

    private static func tapAction(_ name: String) -> TapKind? {
        switch name {
        case "tap": .tap
        case "doubletap": .doubleTap
        case "hold": .hold
        default: nil
        }
    }

    public mutating func route(_ message: GestureMessage, now: Double) -> RecognizedGesture? {
        let age = now - message.receivedAt
        guard !message.synthetic, (-0.1...0.35).contains(age) else { return nil }
        let gesture: RecognizedGesture
        let fromDerived: Bool
        let derivedDirection = Self.derivedSwipe(message.derivedAction)
        if let direction = derivedDirection ?? Self.swipe(named: message.action), message.finger == "thumb" {
            gesture = .swipe(direction)
            fromDerived = derivedDirection != nil
        } else {
            let mapped = Self.derivedTap(message.derivedAction)
            guard let kind = mapped ?? Self.tapAction(message.action),
                  let finger = Finger(rawValue: message.finger) else { return nil }
            gesture = .tap(finger, kind)
            fromDerived = mapped != nil
        }
        let identity = "\(message.sequence):\(message.timestampMicros):\(message.finger):\(message.action):\(message.derivedAction)"
        guard !seen.contains(identity) else { return nil }
        seen.append(identity)
        if seen.count > 128 { seen.removeFirst() }
        if let previous = last[gesture], previous.derived != fromDerived, abs(message.receivedAt - previous.at) < 0.18 {
            return nil
        }
        last[gesture] = (fromDerived, message.receivedAt)
        return gesture
    }
}
