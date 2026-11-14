import BandKit
import BandLogging
import BandProtocol
import CoreGraphics
import Foundation
import Observation
import simd

/// Shared motion input for the demos: wrist twist (like turning a doorknob), forearm aim (where the
/// forearm points, for the air cursor), pinch hold, and a haptic ticker that never floods the band.
///
/// Geometry from kinesis's measurements (docs/cursor-orientation.md, 2026-09-24): the orientation
/// quaternion (wire order w, x, y, z) turns the band's frame into the world's (z up, following gravity).
/// The forearm runs along body +y on a right wrist and −y on a left wrist with the band set to left.
@MainActor
@Observable
final class MotionEngine {
    /// Wrist twist in degrees relative to `neutralTwist` (continuous, not wrapped).
    private(set) var twist: Double = 0
    /// Where the forearm points: compass (relative, no magnetometer) and elevation, degrees.
    private(set) var aim = SIMD2<Double>(0, 0)
    /// Turn rate from the gyro, degrees per second, lightly smoothed.
    private(set) var speed: Double = 0
    private(set) var indexHeld = false
    private(set) var middleHeld = false
    private(set) var hasOrientation = false
    var invertTwist = false

    @ObservationIgnored private var rawTwist: Double?
    @ObservationIgnored private var unwrappedTwist: Double = 0
    @ObservationIgnored private var neutralTwist: Double = 0
    @ObservationIgnored private var lastAim: SIMD2<Double>?
    @ObservationIgnored private var aimDelta = SIMD2<Double>(0, 0)
    @ObservationIgnored private var hapticBusy = false
    @ObservationIgnored private var lastHaptic = 0.0
    private let band: BandClient

    init(band: BandClient) {
        self.band = band
        let stream = band.events.subscribe(buffer: 4096)
        Task { @MainActor [weak self] in
            for await event in stream { self?.ingest(event) }
        }
    }

    // MARK: input

    private func ingest(_ event: BandEvent) {
        switch event {
        case .orientation(let q):
            orientation(w: Double(q.x), x: Double(q.y), y: Double(q.z), z: Double(q.w))
        case .motion(let gyro, _):
            let magnitude = simd_length(gyro)
            speed += (magnitude - speed) * 0.3
        case .rawGesture(let message):
            guard !message.synthetic else { return }
            let press = message.action == "press" || message.derivedAction == "buttonPress"
            let release = message.action == "release" || message.derivedAction == "buttonRelease"
                || message.derivedAction == "buttonHoldRelease"
            guard press || release else { return }
            if message.finger == "index" { indexHeld = press }
            if message.finger == "middle" { middleHeld = press }
        case .dialEngaged(let engaged):
            // band-core's pinch dial engages after an index pinch held ≥ 0.18 s: a backup signal.
            if engaged { indexHeld = true }
        case .phase(let phase) where phase != .streaming:
            indexHeld = false
            middleHeld = false
            hasOrientation = false
            lastAim = nil
        default:
            break
        }
    }

    private static func rotate(_ v: SIMD3<Double>, w: Double, u: SIMD3<Double>) -> SIMD3<Double> {
        v + 2 * w * simd_cross(u, v) + 2 * simd_cross(u, simd_cross(u, v))
    }

    private func orientation(w: Double, x: Double, y: Double, z: Double) {
        let u = SIMD3(x, y, z)
        let sign: Double = band.hand == .left ? -1 : 1
        let forearm = simd_normalize(Self.rotate(SIMD3(0, sign, 0), w: w, u: u))
        let bodyZ = Self.rotate(SIMD3(0, 0, 1), w: w, u: u)
        hasOrientation = true

        // Aim: compass angle around gravity and elevation above the horizon.
        let compass = atan2(forearm.y, forearm.x) * 180 / .pi
        let elevation = asin(max(-1, min(1, forearm.z))) * 180 / .pi
        let current = SIMD2(compass, elevation)
        if let lastAim {
            var delta = current - lastAim
            if delta.x > 180 { delta.x -= 360 }
            if delta.x < -180 { delta.x += 360 }
            aimDelta += delta
        }
        lastAim = current
        aim = current

        // Twist: the angle of the band's z-axis around the forearm, measured from "up".
        let up = SIMD3<Double>(0, 0, 1)
        var reference = up - simd_dot(up, forearm) * forearm
        var face = bodyZ - simd_dot(bodyZ, forearm) * forearm
        guard simd_length(reference) > 0.2, simd_length(face) > 0.2 else { return } // forearm vertical: twist undefined
        reference = simd_normalize(reference)
        face = simd_normalize(face)
        let angle = atan2(simd_dot(simd_cross(reference, face), forearm), simd_dot(reference, face)) * 180 / .pi
        if let rawTwist {
            var delta = angle - rawTwist
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            unwrappedTwist += delta
        } else {
            unwrappedTwist = angle
        }
        rawTwist = angle
        twist = (unwrappedTwist - neutralTwist) * (invertTwist ? -1 : 1)
    }

    /// Makes the current wrist rotation the zero point.
    func calibrateTwist() {
        neutralTwist = unwrappedTwist
        twist = 0
        logInfo(.games, "Wrist twist calibrated (neutral \(String(format: "%.1f", neutralTwist))°)")
    }

    /// Forearm aim change since the last call, in degrees (x = compass, y = elevation).
    func takeAimDelta() -> SIMD2<Double> {
        defer { aimDelta = .zero }
        return aimDelta
    }

    // MARK: haptics

    /// One vibration if the band is free and at least `spacing` seconds passed; otherwise it's dropped,
    /// so fast detents never queue up into a buzzing mess. Returns whether it was sent.
    @discardableResult
    func tick(durationMs: UInt64 = 25, amplitude: UInt8 = 140, spacing: Double = 0.06) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard band.phase == .streaming, !hapticBusy, now - lastHaptic >= spacing else { return false }
        hapticBusy = true
        lastHaptic = now
        Task { @MainActor in
            _ = await band.haptic(.vibrate(durationMs: durationMs, amplitude: amplitude))
            hapticBusy = false
        }
        return true
    }

    /// A pattern: (duration ms, amplitude, pause ms) steps, played in order.
    func pattern(_ steps: [(UInt64, UInt8, UInt64)]) {
        guard band.phase == .streaming else { return }
        Task { @MainActor in
            for (duration, amplitude, pause) in steps {
                hapticBusy = true
                _ = await band.haptic(.vibrate(durationMs: duration, amplitude: amplitude))
                hapticBusy = false
                try? await Task.sleep(for: .milliseconds(Int(duration + pause)))
            }
            lastHaptic = ProcessInfo.processInfo.systemUptime
        }
    }
}

/// The air cursor's transfer function (after kinesis AirCursor): stillness gate, acceleration and a
/// click guard, turning forearm aim changes into normalized screen movement while the pinch is held.
struct CursorFilter {
    /// Degrees of forearm turn to cross the full width / height at 1× sensitivity.
    var degreesAcross = 32.0
    var degreesDown = 42.0
    var sensitivity = 1.0
    private var clutchStart: Double?

    /// Normalized (0…1 screen) movement for this frame's aim delta.
    mutating func move(aimDelta: SIMD2<Double>, speed: Double, clutched: Bool, now: Double) -> CGVector {
        guard clutched else {
            clutchStart = nil
            return .zero
        }
        if clutchStart == nil { clutchStart = now }
        // The arm shifts 0.2–0.8° as the pinch lands: ignore the first 120 ms.
        guard now - (clutchStart ?? now) > 0.12 else { return .zero }
        // Still below ~0.9°/s, fully moving above ~1.5°/s (tremor stays put).
        let gate = max(0, min(1, (speed - 0.9) / 0.6))
        // Slow aiming is precise (0.6×), flicks travel (up to 1.6× at 30°/s).
        let acceleration = 0.6 + 1.0 * max(0, min(1, (speed - 4) / 26))
        let scale = gate * acceleration * sensitivity
        // Turning right lowers the compass angle; raising the arm moves the pointer up.
        return CGVector(dx: -aimDelta.x / degreesAcross * scale, dy: -aimDelta.y / degreesDown * scale)
    }
}
