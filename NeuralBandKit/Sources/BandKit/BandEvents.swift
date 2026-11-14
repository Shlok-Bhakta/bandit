import BandProtocol
import Foundation

/// Where an event came from. Games and the playground show simulated events with a clear label.
public enum EventSource: String, Sendable, Codable { case band, simulated, touch }

public struct GestureEvent: Identifiable, Sendable {
    public let id = UUID()
    /// The gesture after wrist normalization (what apps should act on).
    public let gesture: RecognizedGesture
    /// What the band reported, before wrist normalization (nil for simulated/touch input).
    public let raw: RecognizedGesture?
    public let source: EventSource
    public let date: Date
    /// Monotonic host time (seconds) the band message was decoded, for latency measurements.
    public let uptime: Double
    /// The band's own clock in µs (unrelated epoch to the host).
    public let bandTimestampMicros: UInt64?
    public let sequence: UInt64?

    public init(gesture: RecognizedGesture, source: EventSource, uptime: Double = ProcessInfo.processInfo.systemUptime,
                bandTimestampMicros: UInt64? = nil, sequence: UInt64? = nil, raw: RecognizedGesture? = nil) {
        self.gesture = gesture
        self.raw = raw
        self.source = source
        self.date = Date()
        self.uptime = uptime
        self.bandTimestampMicros = bandTimestampMicros
        self.sequence = sequence
    }
}

public struct HapticsResult: Sendable {
    public let command: HapticsCommand
    public let delivered: Bool
    public let rpcSuccess: Bool
    public let hapticsSuccess: Bool?
    public let roundTrip: Double?
    public let error: String?
}

/// Typed events fanned out to every subscriber (playground, games, log, recorders).
public enum BandEvent: Sendable {
    case gesture(GestureEvent)
    /// Every raw gesture message, including presses/releases the router doesn't surface.
    case rawGesture(GestureMessage)
    case dialEngaged(Bool)
    /// Degrees of relative wrist rotation while pinching.
    case dialTurn(Double)
    /// Gyro in degrees per second (raw × 0.07).
    case motion(gyro: SIMD3<Double>, bandTimestampMicros: UInt64)
    case orientation(SIMD4<Float>)
    case emg(EmgBatch, receivedAt: Double)
    case emgConfiguration(EmgConfig)
    case battery(level: Int, charging: Bool?)
    case phase(ConnectionPhase)
    case haptics(HapticsResult)
    /// Handwriting capture progress (switching the band's model on, ready, restoring, finished).
    case handwritingState(ModelCaptureStatus)
    /// One band model output sample (handwriting: 100 log-probabilities per frame).
    case inference(InferenceSample)
}

public enum ConnectionPhase: Equatable, Sendable {
    case idle
    case bluetoothUnavailable(String)
    case connecting(String)
    /// iOS is showing (or about to show) its Bluetooth pairing request.
    case pairingPrompt
    case authenticating(String)
    case claiming(String)
    case streaming
    case reconnecting(attempt: Int, delay: Double)
    case failed(BandFailure)

    public var isActive: Bool {
        switch self {
        case .connecting, .pairingPrompt, .authenticating, .claiming, .streaming: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .idle: "Not connected"
        case .bluetoothUnavailable(let reason): "Bluetooth \(reason)"
        case .connecting(let stage): stage
        case .pairingPrompt: "Accept the Bluetooth pairing request"
        case .authenticating(let stage): stage
        case .claiming(let stage): stage
        case .streaming: "Connected — streaming"
        case .reconnecting(let attempt, let delay): "Reconnecting in \(Int(delay.rounded())) s (attempt \(attempt))"
        case .failed(let failure): failure.title
        }
    }
}

public struct BandFailure: Equatable, Sendable {
    public enum Kind: String, Sendable { case bluetooth, pairing, encryption, ownerKeyRejected, wrongAccount, claimRejected, metaSession, meta, timeout, protocolError, busy, credentials }
    public let kind: Kind
    public let title: String
    public let detail: String
    public let suggestion: String?
    public let code: UInt32?
}

/// A multi-subscriber event stream on the main actor.
@MainActor
public final class EventHub {
    private var continuations: [UUID: AsyncStream<BandEvent>.Continuation] = [:]

    public init() {}

    public func subscribe(buffer: Int = 1024) -> AsyncStream<BandEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BandEvent>.makeStream(bufferingPolicy: .bufferingNewest(buffer))
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations[id] = nil } }
        continuations[id] = continuation
        return stream
    }

    public var subscriberCount: Int { continuations.count }

    func publish(_ event: BandEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }
}
