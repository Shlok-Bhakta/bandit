import Foundation

public enum Hand: String, Sendable, Equatable, Codable { case right, left }

/// One recognized-gesture message as the band sent it. Names come from the band's enum tables;
/// unknown values read `unrecognized:<n>`.
public struct GestureMessage: Sendable, Equatable {
    public var sequence: UInt64
    public var timestampMicros: UInt64
    public var finger: String
    public var action: String
    public var derivedAction: String
    public var synthetic: Bool
    /// Host monotonic time (seconds) the message was decoded at.
    public var receivedAt: Double

    public init(sequence: UInt64, timestampMicros: UInt64, finger: String, action: String,
                derivedAction: String, synthetic: Bool, receivedAt: Double) {
        self.sequence = sequence
        self.timestampMicros = timestampMicros
        self.finger = finger
        self.action = action
        self.derivedAction = derivedAction
        self.synthetic = synthetic
        self.receivedAt = receivedAt
    }

    static let fingers = ["unknown", "thumb", "index", "middle", "notApplicable"]
    static let actions = ["unknown", "press", "release", "tap", "doubletap", "click", "up", "down", "left", "right",
                          "wake", "swipeIn", "swipeOut", "ia", "partialPress", "partialRelease", "partialClick",
                          "partialUp", "partialDown", "partialLeft", "partialRight"]
    static let derived = ["unknown", "singleTap", "doubleTap", "buttonHold", "buttonRelease", "buttonUp",
                          "buttonDown", "buttonLeft", "buttonRight", "buttonPress", "buttonHoldRelease"]

    static func name(_ table: [String], _ value: UInt64) -> String {
        value < UInt64(table.count) ? table[Int(value)] : "unrecognized:\(value)"
    }
}

/// `BatteryInfoResp.batteryData`: level 0–100 and an optional charging flag.
public struct BatteryStatus: Sendable, Equatable {
    public var level: Int
    public var charging: Bool?

    public init(level: Int, charging: Bool?) {
        self.level = level
        self.charging = charging
    }

    static func parse(response: [UInt8]) throws -> BatteryStatus {
        let rpc = try ProtoFields(parsing: response)
        guard try rpc.requiredInteger(2) == 1 else { throw perr("Battery status unavailable") }
        let inner = try ProtoFields(parsing: try rpc.bytes(3))
        let battery = try ProtoFields(parsing: try inner.bytes(1))
        let level = try battery.requiredInteger(1)
        guard level <= 100 else { throw perr("Invalid battery level") }
        var charging: Bool?
        if battery.contains(2) {
            let value = try battery.requiredInteger(2)
            guard value <= 1 else { throw perr("Invalid charging flag") }
            charging = value == 1
        }
        return BatteryStatus(level: Int(level), charging: charging)
    }
}

/// Dimensions from the band's `Config.emg` field. ADC calibration is unknown.
public struct EmgConfig: Sendable, Equatable {
    public var sampleRate: UInt64
    public var channels: UInt64
    public var adcBits: UInt64
    public var samplesPerBatch: UInt64
    public var encoding: UInt64

    public init(sampleRate: UInt64, channels: UInt64, adcBits: UInt64, samplesPerBatch: UInt64, encoding: UInt64) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.adcBits = adcBits
        self.samplesPerBatch = samplesPerBatch
        self.encoding = encoding
    }

    static func parse(response: [UInt8]) throws -> EmgConfig {
        let response = try ProtoFields(parsing: response)
        guard try response.requiredInteger(2) == 1 else { throw perr("The band rejected the EMG configuration read.") }
        let config = try ProtoFields(parsing: try response.bytes(6))
        let emg = try ProtoFields(parsing: try config.bytes(42))
        return EmgConfig(sampleRate: try emg.requiredInteger(1), channels: try emg.requiredInteger(2),
                         adcBits: try emg.requiredInteger(4), samplesPerBatch: try emg.requiredInteger(5),
                         encoding: try emg.requiredInteger(10))
    }

    /// The observed layout: 2048 Hz, 8 channels, 16-bit, 16 samples per batch, encoding 0.
    public var isSupported: Bool {
        sampleRate == 2048 && channels == 8 && adcBits == 16 && samplesPerBatch == 16 && encoding == 0
    }
}

/// One raw sEMG batch: 16 samples × 8 channels, little-endian u16, interleaved by sample then channel.
public struct EmgBatch: Sendable, Equatable {
    public static let channels = 8
    public static let samples = 16
    public var sequence: UInt64
    public var timestampMicros: UInt64
    /// `samples × channels` values, sample-major.
    public var values: [UInt16]

    public init(sequence: UInt64, timestampMicros: UInt64, values: [UInt16]) {
        self.sequence = sequence
        self.timestampMicros = timestampMicros
        self.values = values
    }

    public static func parse(payload: [UInt8], config: EmgConfig) throws -> EmgBatch {
        guard config.isSupported else { throw perr("This EMG format isn't supported by the viewer yet.") }
        let fields = try ProtoFields(parsing: payload)
        let bytes = try fields.bytes(3, count: 256)
        var values: [UInt16] = []
        values.reserveCapacity(128)
        for index in stride(from: 0, to: 256, by: 2) {
            values.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
        }
        return EmgBatch(sequence: try fields.requiredInteger(1), timestampMicros: try fields.requiredInteger(2), values: values)
    }

    public func value(sample: Int, channel: Int) -> UInt16 { values[sample * Self.channels + channel] }
}

/// The band's DeviceInfoResp: firmware, hardware and serial number.
public struct DeviceInfo: Sendable, Equatable {
    public var firmware: String
    public var software: String
    public var hardware: String
    /// Identifies the physical band. Not a secret, but masked in diagnostic exports.
    public var serial: String
    public var releaseBranch: String
    /// The EMG model the band runs now: `cc_od_…` for gestures, `ia_od_…` for standby's wake model.
    public var model: String
    public var models: [String]

    public var hasHandwritingModel: Bool { models.contains { $0.hasPrefix("hw_") } }

    /// The DeviceInfoResp inside an RPC response: the nested message with a printable serial (field 6)
    /// and a firmware revision (field 2).
    static func find(_ fields: ProtoFields, depth: Int = 0) -> DeviceInfo? {
        if let serial = fields.text(6), (4...64).contains(serial.count),
           serial.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }),
           let firmware = fields.text(2) {
            return DeviceInfo(firmware: firmware, software: fields.text(3) ?? "", hardware: fields.text(4) ?? "",
                              serial: serial, releaseBranch: fields.text(13) ?? "", model: fields.text(5) ?? "",
                              models: fields.byteFields().filter { $0.0 == 10 }.compactMap { String(bytes: $0.1, encoding: .utf8) })
        }
        guard depth < 3 else { return nil }
        for (_, bytes) in fields.byteFields() {
            if let inner = try? ProtoFields(parsing: bytes), let info = find(inner, depth: depth + 1) { return info }
        }
        return nil
    }
}

/// Everything a session reports.
public enum SessionEvent: Sendable {
    /// Input streams are live (first subscription ack or first sensor data).
    case connected
    /// Authenticated traffic arrived while streaming (at most every 0.2 s).
    case heartbeat
    /// A decoded sensor frame arrived.
    case dataSeen
    case gesture(GestureMessage)
    /// The pinch dial armed or let go.
    case dialState(Bool)
    /// Relative wrist rotation (degrees) while the dial is armed, coalesced to ≥ 20 ms.
    case dialTurn(Double)
    /// One gyro sample: the band's clock (µs) and the raw axes (× 0.07 = °/s).
    case motion(timestampMicros: UInt64, gyro: SIMD3<Double>)
    /// A unit quaternion (w, x, y, z) that turns the band's frame into the room's.
    case orientation(SIMD4<Float>)
    case handedness(Hand)
    case handednessFailure(String)
    case hapticsFinished(sequence: UInt32, rpcSuccess: Bool, hapticsSuccess: Bool?)
    /// nil = unknown (timed out, rejected or unsupported).
    case batteryStatus(BatteryStatus?)
    case deviceInfo(DeviceInfo)
    case rawEmgFrame([UInt8])
    case rawEmgConfiguration(EmgConfig)
    case rawEmgState(Bool)
    case rawEmgFailure(String)
    case ceremonyStage(String)
    /// The session needs an ownership HTTP exchange; resume with `ceremonyPairRequestCompleted` / `ceremonyPairCompleted`.
    case ceremonyHttp(CeremonyHttpRequest)
    /// The band confirmed this host as owner. Persist the identity; trust setup continues.
    case ceremonyCompleted(OwnerIdentity)
    /// Mutual trust with a stored owner key succeeded.
    case ownerTrusted(bandVerified: Bool)
    /// Handwriting (band model) capture progress.
    case modelCaptureState(ModelCaptureStatus)
    /// One output sample of the band's on-device model (handwriting: 100 log-probabilities).
    case inferenceSample(InferenceSample)
    /// Progress of the read-only band survey (settings, config, update status).
    case surveyUpdated(BandSurveyReport)
    /// The stream flags the band reports after an experimental stream change (field → 0/1).
    case probeStreams([UInt32: UInt64])
    /// A line of the band's own firmware log (kind 0x02000316).
    case firmwareLog(String)
    /// Firmware update progress.
    case otaProgress(OtaReport)
}

/// Where a firmware update step stands.
public struct OtaReport: Sendable, Equatable {
    public var mode: OtaMode
    public var version: UInt64
    public var running: Bool
    /// New log lines since the last report.
    public var lines: [String]
    public var items: [OtaItemProgress]
    public var status: OtaStatus?
    /// Commit was sent (the band may be rebooting into the new firmware).
    public var committed: Bool
    /// The band answered the Commit with OK.
    public var commitAccepted: Bool
    public var cancellable: Bool
}
