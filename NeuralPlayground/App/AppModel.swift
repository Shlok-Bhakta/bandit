import BandKit
import BandLogging
import BandProtocol
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {
    enum Tab: Hashable { case band, playground, games, credentials, diagnostics }

    var tab: Tab = .band
    let band = BandClient()
    let eventLog: EventLogStore
    let sensors: LiveSensors
    let systemControl: SystemControl
    let motion: MotionEngine
    /// Shows simulation buttons; every simulated event is labeled SIMULATED wherever it appears.
    var simulationEnabled = false {
        didSet { logNotice(.app, "Simulation mode \(simulationEnabled ? "ON — simulated events are labeled" : "off")") }
    }

    init() {
        eventLog = EventLogStore(hub: band.events)
        sensors = LiveSensors(hub: band.events)
        systemControl = SystemControl(band: band)
        motion = MotionEngine(band: band)
        #if DEBUG
        // Screenshot/testing aid: `-NPTab playground|games|credentials|diagnostics`, `-NPSimulation YES`.
        switch UserDefaults.standard.string(forKey: "NPTab") {
        case "playground": tab = .playground
        case "games": tab = .games
        case "credentials": tab = .credentials
        case "diagnostics": tab = .diagnostics
        default: break
        }
        if UserDefaults.standard.bool(forKey: "NPSimulation") { simulationEnabled = true }
        #endif
        let device = UIDevice.current
        logNotice(.app, "Neural Playground \(Self.version) on \(Self.hardwareModel) \(device.systemName) \(device.systemVersion)")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static var hardwareModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Header for exported logs and reports.
    static var reportHeader: String {
        let device = UIDevice.current
        return """
        Neural Playground \(version)
        Device: \(hardwareModel), \(device.systemName) \(device.systemVersion)
        Exported: \(ISO8601DateFormatter().string(from: Date()))
        (Sanitized: no owner keys, Meta tokens, receipts or payloads are ever logged.)
        """
    }
}

/// A rolling, pausable log of band events for the playground.
@MainActor
@Observable
final class EventLogStore {
    struct Item: Identifiable {
        let id = UUID()
        let date: Date
        let uptime: Double
        let kind: String
        let detail: String
        let source: EventSource
    }

    private(set) var items: [Item] = []
    var paused = false
    var includeRawMessages = true
    let capacity = 500
    private(set) var dropped = 0

    init(hub: EventHub) {
        let stream = hub.subscribe()
        Task { @MainActor [weak self] in
            for await event in stream { self?.ingest(event) }
        }
    }

    private func ingest(_ event: BandEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let item: Item?
        switch event {
        case .gesture(let gesture):
            item = Item(date: gesture.date, uptime: gesture.uptime, kind: "Gesture", detail: gesture.gesture.title, source: gesture.source)
        case .rawGesture(let message) where includeRawMessages:
            item = Item(date: Date(), uptime: message.receivedAt, kind: "Raw",
                        detail: "#\(message.sequence) \(message.finger) · \(message.action) · \(message.derivedAction)", source: .band)
        case .dialEngaged(let on):
            item = Item(date: Date(), uptime: now, kind: "Pinch", detail: on ? "Pinch dial engaged" : "Pinch released", source: .band)
        case .battery(let level, let charging):
            item = Item(date: Date(), uptime: now, kind: "Battery", detail: "\(level)%\(charging == true ? " ⚡︎" : "")", source: .band)
        case .phase(let phase):
            item = Item(date: Date(), uptime: now, kind: "Link", detail: phase.title, source: .band)
        case .haptics(let result):
            item = Item(date: Date(), uptime: now, kind: "Haptics",
                        detail: "\(result.command) → \(result.rpcSuccess ? "ok" : "no confirm")\(result.roundTrip.map { " \(Int($0 * 1000)) ms" } ?? "")", source: .band)
        case .emgConfiguration(let config):
            item = Item(date: Date(), uptime: now, kind: "EMG", detail: "\(config.channels) ch @ \(config.sampleRate) Hz", source: .band)
        default:
            item = nil
        }
        guard let item else { return }
        guard !paused else { dropped += 1; return }
        items.insert(item, at: 0)
        if items.count > capacity { items.removeLast(items.count - capacity) }
    }

    func clear() {
        items.removeAll()
        dropped = 0
    }

    var csv: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows = items.reversed().map { item in
            "\(formatter.string(from: item.date)),\(String(format: "%.4f", item.uptime)),\(item.source.rawValue),\(item.kind),\"\(item.detail.replacingOccurrences(of: "\"", with: "'"))\""
        }
        return (["date,uptime_s,source,kind,detail"] + rows).joined(separator: "\n") + "\n"
    }
}

/// The latest motion state for the dashboard, throttled for SwiftUI.
@MainActor
@Observable
final class LiveSensors {
    struct Euler { var roll = 0.0, pitch = 0.0, yaw = 0.0 }

    private(set) var orientation: SIMD4<Float>?
    private(set) var euler = Euler()
    private(set) var gyro = SIMD3<Double>(repeating: 0)
    /// Recent gyro magnitudes per axis (°/s), oldest first.
    private(set) var gyroHistory: [SIMD3<Double>] = []
    private(set) var dialEngaged = false
    private(set) var dialAngle = 0.0
    private(set) var motionRate = 0.0
    private(set) var lastRaw: GestureMessage?

    @ObservationIgnored private var motionCount = 0
    @ObservationIgnored private var rateStart = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var lastUIUpdate = 0.0
    @ObservationIgnored private var pendingGyro = SIMD3<Double>(repeating: 0)

    init(hub: EventHub) {
        let stream = hub.subscribe(buffer: 4096)
        Task { @MainActor [weak self] in
            for await event in stream { self?.ingest(event) }
        }
    }

    private func ingest(_ event: BandEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case .motion(let value, _):
            motionCount += 1
            pendingGyro = value
            if now - lastUIUpdate >= 1.0 / 30 {
                lastUIUpdate = now
                gyro = pendingGyro
                gyroHistory.append(pendingGyro)
                if gyroHistory.count > 150 { gyroHistory.removeFirst(gyroHistory.count - 150) }
            }
            if now - rateStart >= 1 {
                motionRate = Double(motionCount) / (now - rateStart)
                motionCount = 0
                rateStart = now
            }
        case .orientation(let q):
            orientation = q
            euler = Self.euler(q)
        case .dialEngaged(let on):
            dialEngaged = on
        case .dialTurn(let delta):
            dialAngle += delta
        case .rawGesture(let message):
            lastRaw = message
        case .phase(let phase):
            if phase != .streaming { motionRate = 0 }
        default:
            break
        }
    }

    func resetDial() { dialAngle = 0 }

    /// (w, x, y, z) → roll/pitch/yaw in degrees. The band's axes aren't documented; this is the
    /// standard aerospace decomposition of the reported quaternion.
    static func euler(_ q: SIMD4<Float>) -> Euler {
        let w = Double(q.x), x = Double(q.y), y = Double(q.z), z = Double(q.w)
        let roll = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
        let pitch = asin(max(-1, min(1, 2 * (w * y - z * x))))
        let yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
        return Euler(roll: roll * 180 / .pi, pitch: pitch * 180 / .pi, yaw: yaw * 180 / .pi)
    }
}
