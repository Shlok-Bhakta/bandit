import Foundation

/// Haptics RPCs on the configuration service (band-core `haptics.rs`).
///
/// `RpcRequest { 1: sequence, 17: HapticsReq { 1: Vibrate { 1: duration_ms, 3: amplitude }, 2: Perform { 1: pattern } } }`.
/// Only patterns 1 and 2 (the gesture-feedback patterns) are verified by band-core.
public enum HapticsCommand: Sendable, Equatable {
    case vibrate(durationMs: UInt64, amplitude: UInt8)
    case perform(patternID: UInt32)

    public static let verifiedPatterns: [UInt32] = [1, 2]
    public static let maxDurationMs: UInt64 = 2000

    public func encodeRPC(sequence: UInt32) throws -> [UInt8] {
        guard sequence != 0 else { throw perr("Haptics RPC sequence must be nonzero") }
        let haptics: [UInt8]
        switch self {
        case .vibrate(let duration, let amplitude):
            guard duration > 0 else { throw perr("Vibration duration must be positive") }
            haptics = Proto.field(1, bytes: Proto.field(1, duration) + Proto.field(3, UInt64(amplitude)))
        case .perform(let pattern):
            guard Self.verifiedPatterns.contains(pattern) else {
                throw perr("Only verified gesture-feedback patterns 1 and 2 are supported")
            }
            haptics = Proto.field(2, bytes: Proto.field(1, UInt64(pattern)))
        }
        return Proto.field(1, UInt64(sequence)) + Proto.field(17, bytes: haptics)
    }

    /// The field of `HapticsResp` that answers this command.
    var responseField: UInt32 {
        switch self {
        case .vibrate: 2
        case .perform: 3
        }
    }
}
