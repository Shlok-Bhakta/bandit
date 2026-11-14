import BandCredentials
import BandLogging
import BandProtocol
import BandTransport
import Foundation

// Hardware probe for the Neural Band from a Mac, driving the same session code as the app.
//
//   claim-probe  Runs the ownership ceremony only up to the band's nonce, then stops BEFORE any
//                Meta request. Without Meta's signed receipt the band can't change owner, so
//                this can't claim or alter the band.
//   legacy       The keyless startup (pairing-mode bands): subscribes and logs gestures.
//   owner        Connects as the owner with ~/.config/neural-playground/air-gestures-band.json
//                (or $NP_OWNER_FILE), subscribes, and logs gestures, motion rates, battery and EMG.
//   scan         Lists nearby bands.
//
// Usage: band-probe <claim-probe|legacy|scan> [seconds]

@MainActor
final class Probe {
    let mode: String
    let central = BandCentral()
    var link: BandLink?
    var session: BandSession?
    var connecting = false
    var timer: Timer?
    var streamingSince: Double?
    let start = ProcessInfo.processInfo.systemUptime
    let limit: Double
    var nextBattery = 0.0

    init(mode: String, seconds: Double) {
        self.mode = mode
        limit = seconds
    }

    var now: Double { ProcessInfo.processInfo.systemUptime }

    func run() {
        logNotice(.app, "band-probe \(mode): limit \(Int(limit)) s")
        central.onChange = { [weak self] in self?.discovered() }
        central.startScan()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func discovered() {
        guard !connecting, mode != "scan", let band = central.discovered.values.filter(\.isBand).max(by: { ($0.rssi ?? -127) < ($1.rssi ?? -127) }) else { return }
        connecting = true
        central.stopScan()
        logNotice(.app, "Probing \(band.name) (\(band.id)), rssi \(band.rssi.map(String.init) ?? "?")")
        link = central.openLink(to: band.id) { [weak self] event in self?.handle(event) }
    }

    func handle(_ event: TransportEvent) {
        switch event {
        case .stage(let stage): logInfo(.app, "Stage: \(stage)")
        case .systemPairingPrompt: logNotice(.app, ">>> macOS is asking to pair with the band: click Connect / Pair on the Mac <<<")
        case .l2capOpened:
            let sessionMode: SessionMode
            switch mode {
            case "claim-probe": sessionMode = .ceremony
            case "owner":
                guard let identity = Probe.loadOwner() else { finish("no usable owner key file"); return }
                logNotice(.app, "Connecting as owner \(identity.fingerprint)")
                sessionMode = .enrolled(identity)
            default: sessionMode = .legacy
            }
            let session = BandSession(mode: sessionMode, rawEmg: ProcessInfo.processInfo.environment["NP_EMG"] == "1")
            session.logFrames = true
            session.dumpSetupPayloads = true
            self.session = session
            do { link?.write(try session.request()) } catch { finish("request failed: \(error.localizedDescription)") }
        case .bytes(let bytes):
            guard let session, let link else { return }
            if session.authenticatedPackets == 0 {
                logDebug(.l2cap, "rx \(bytes.count)B before/at first auth: \(bytes.prefix(48).map { String(format: "%02x", $0) }.joined())\(bytes.count > 48 ? "…" : "")")
            }
            do {
                let result = try session.feed(bytes, time: now)
                drain()
                link.write(result.outgoing)
                for event in result.events { handle(event) }
            } catch {
                drain()
                finish("session ended: \(BandLog.describe(error))")
            }
        case .closed(let error):
            finish("link closed: \(error.map(BandLog.describe) ?? "on request")")
        default: break
        }
    }

    static func loadOwner() -> OwnerIdentity? {
        let path = ProcessInfo.processInfo.environment["NP_OWNER_FILE"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/neural-playground/air-gestures-band.json").path
        do {
            return try AirGesturesFile.parse(Data(contentsOf: URL(fileURLWithPath: path))).identity
        } catch {
            logError(.credentials, "Owner key file unusable: \(error.localizedDescription)")
            return nil
        }
    }

    var motionCount = 0
    var lastRateLog = 0.0

    func handle(_ event: SessionEvent) {
        switch event {
        case .ceremonyStage(let stage): logNotice(.ownership, "Ceremony stage: \(stage)")
        case .ceremonyHttp(.pairRequest(let request)):
            logNotice(.ownership, "RESULT: the band answered the identity read (serial \(BandLog.mask(request.identity.serial)), certificate \(request.identity.deviceCertificate.count)B) and gave its ownership nonce (\(request.nonce.count)B). A real claim would now ask Meta; the probe stops here. Nothing was claimed.")
            finish("claim-probe reached the Meta step")
        case .connected:
            streamingSince = now
            logNotice(.app, "RESULT: streaming WITHOUT an owner key. Make gestures now.")
        case .gesture(let message):
            logNotice(.gestures, "Gesture #\(message.sequence): \(message.finger) \(message.action) \(message.derivedAction)")
        case .deviceInfo(let info):
            logNotice(.app, "Device info: firmware \(info.firmware), software \(info.software), hardware \(info.hardware), model \(info.model), models \(info.models)")
        case .batteryStatus(let status): logInfo(.app, "Battery: \(status.map { "\($0.level)%" } ?? "unknown")")
        case .handedness(let hand): logInfo(.app, "Hand: \(hand.rawValue)")
        case .dialState(let on): logInfo(.gestures, "Pinch dial \(on ? "engaged" : "released")")
        case .ownerTrusted(let verified): logNotice(.ownership, "RESULT: the band accepted the owner key (band proof verified: \(verified))")
        case .motion:
            motionCount += 1
            if now - lastRateLog >= 5 {
                logInfo(.app, "Motion: \(motionCount) gyro samples in the last \(Int(now - lastRateLog)) s")
                motionCount = 0
                lastRateLog = now
            }
        case .rawEmgConfiguration(let config): logNotice(.emg, "EMG config: \(config.channels) ch @ \(config.sampleRate) Hz, \(config.adcBits)-bit, enc \(config.encoding)")
        case .rawEmgState(let on): logNotice(.emg, "EMG streaming confirmed: \(on)")
        case .rawEmgFailure(let message): logWarning(.emg, "EMG failed: \(message)")
        default: break
        }
    }

    func drain() {
        for note in session?.takeNotes() ?? [] {
            switch note.level {
            case .debug: logDebug(.session, note.text)
            case .info: logInfo(.session, note.text)
            case .notice: logNotice(.session, note.text)
            case .warning: logWarning(.session, note.text)
            }
        }
    }

    func tick() {
        if let session, let link {
            for event in session.tick(time: now) { handle(event) }
            if session.streamsEnabled, now >= nextBattery {
                nextBattery = now + 5
                link.write((try? session.queryBatteryStatus(time: now)) ?? [])
            }
        }
        if mode == "scan", now - start > 8 {
            for device in central.discovered.values where device.isBand {
                logNotice(.app, "Band: \(device.name) \(device.id) rssi \(device.rssi.map(String.init) ?? "?")")
            }
            finish("scan done")
        }
        if now - start > limit { finish("time limit reached") }
    }

    var finished = false

    func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        logNotice(.app, "band-probe done: \(reason)")
        if let session, let link, session.streamsEnabled {
            link.write((try? session.stop()) ?? [])
        }
        let link = self.link
        self.link = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                link?.close(reason: "probe finished")
                exit(0)
            }
        }
    }
}

BandLog.shared.echoesToStandardOutput = true
let arguments = CommandLine.arguments.dropFirst()
let probe = Probe(mode: arguments.first ?? "claim-probe", seconds: Double(arguments.dropFirst().first ?? "") ?? 75)
probe.run()
RunLoop.main.run()
