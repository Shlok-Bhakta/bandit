import BandCredentials
import BandLogging
import BandProtocol
import BandTransport
import CoreBluetooth
import Foundation
import Observation

/// Live diagnostics for the developer screen and the sanitized report. Nothing secret.
public struct LinkDiagnostics: Sendable {
    public var peripheralID: UUID?
    public var peripheralName: String?
    public var gatt: [GATTServiceInfo] = []
    public var deviceInformation: [String: String] = [:]
    public var psm: UInt16?
    public var maxWriteLength: Int?
    public var l2capOpenedAt: Date?
    public var bytesIn = 0
    public var bytesOut = 0
    public var sessionStage = "—"
    public var ownershipMode = "—"
    public var ownerFingerprint: String?
    public var bandVerified = false
    public var schemeGuess: Int?
    public var peerParameters: UInt64?
    public var newerFirmwareScheme = false
    public var authenticatedPackets = 0
    public var framesDecoded = 0
    public var decodeFailures = 0
    public var skippedTransportRecords = 0
    public var unknownKinds: [String: Int] = [:]
    /// Field shape (no byte contents) of each undecoded message kind.
    public var unknownShapes: [String: String] = [:]
    public var gestureMessages = 0
    public var recognizedGestures = 0
    public var motionMessages = 0
    public var orientationMessages = 0
    public var emgFrames = 0
    /// Every decoded frame by message kind (type word), for the Signals screen.
    public var messageCounts: [String: Int] = [:]
    public var connectAttempts = 0
    public var reconnects = 0
    public var startedAt: Date?
    public var streamingSince: Date?
    public var timeToStreaming: Double?
    public var lastError: String?
    public var errors: [(date: Date, message: String)] = []
    /// Host decode → hub publish, in ms (pure app-side latency).
    public var lastGestureDispatchMs: Double?
    /// Intervals between consecutive recognized gestures (s), last 50.
    public var gestureIntervals: [Double] = []
    public var lastGestureAt: Double?
    public var hapticsSent = 0
    public var hapticsAcknowledged = 0
}

/// The façade apps use. One band at a time; runs on the main actor (CoreBluetooth uses the main queue).
@MainActor
@Observable
public final class BandClient {
    public enum Operation: Equatable {
        case connect, claim
        /// No owner key: the startup kinesis used before enrollment existed (pairing-mode bands only).
        case legacy
    }

    // MARK: observable state
    public private(set) var phase: ConnectionPhase = .idle
    public private(set) var storedBand: StoredBand?
    public private(set) var ownerFingerprint: String?
    public private(set) var ownerHasBandKey = false
    public private(set) var hasPendingKey = false
    public private(set) var hasMetaSession = false
    public private(set) var battery: Int?
    public private(set) var charging: Bool?
    public private(set) var rssi: Int?
    public private(set) var deviceInfo: DeviceInfo?
    public private(set) var hand: Hand?
    public private(set) var emgConfig: EmgConfig?
    public private(set) var emgStreaming = false
    public private(set) var emgError: String?
    public private(set) var diagnostics = LinkDiagnostics()
    public private(set) var discovered: [DiscoveredDevice] = []
    public private(set) var isScanning = false
    public private(set) var bluetoothState = "starting"
    /// Set after a successful claim so the UI can prompt for a backup.
    public var claimJustCompleted = false
    public var autoReconnect = true
    public var ceremonyStage: String?
    /// The app's wrist preference and per-wrist corrections. Applies to the next event; never writes to the band.
    public var wrist = WristConfiguration.load() {
        didSet {
            guard wrist != oldValue else { return }
            wrist.save()
            let p = wrist.active
            logNotice(.gestures, "Wrist profile: \(wrist.wrist.title); invert horizontal \(p.invertHorizontal), vertical \(p.invertVertical), dial \(p.invertDial) (app only; band setting unchanged)")
        }
    }
    /// Writing the band's own hand setting, with readback verification.
    public private(set) var handSync: HandSync = .idle
    /// The band's handwriting model capture.
    public private(set) var handwriting: ModelCaptureStatus = .idle
    @ObservationIgnored private var disconnectAfterRestore = false
    /// The read-only band survey: settings, config, update status.
    public private(set) var survey = BandSurveyReport()
    /// Experimental stream flags asked for, what the band last reported for them, and any refusal.
    public private(set) var probeRequested: Set<UInt32> = []
    public private(set) var probeReported: [UInt32: UInt64] = [:]
    public private(set) var probeError: String?
    /// The running (or last) firmware update step, its log, and an install followed across the restart.
    public private(set) var ota: OtaReport?
    public private(set) var otaLog: [String] = []
    public private(set) var otaError: String?
    public private(set) var firmwareInstall = FirmwareInstall.load()
    public var otaRunning: Bool { ota?.running == true }
    /// The band's own firmware log lines (kind 0x02000316), newest last.
    public private(set) var firmwareLog: [(date: Date, text: String)] = []
    /// Set while the band's settings may be in the capture's mode; cleared once restoration is verified.
    private static let handwritingRecoveryKey = "handwriting.needsRecovery"

    public let events = EventHub()

    // MARK: collaborators
    @ObservationIgnored public let central = BandCentral()
    @ObservationIgnored public let store: CredentialStore
    @ObservationIgnored public let metaStore: MetaSessionStore

    // MARK: attempt state
    @ObservationIgnored private var link: BandLink?
    @ObservationIgnored private var session: BandSession?
    @ObservationIgnored private var operation: Operation?
    @ObservationIgnored private var targetID: UUID?
    @ObservationIgnored private var schemeGuess = 0
    @ObservationIgnored private var usingPendingKey = false
    @ObservationIgnored private var pendingSavedThisRun = false
    @ObservationIgnored private var claimCompleted = false
    @ObservationIgnored private var metaSession: MetaSession?
    @ObservationIgnored private var deadline = Double.infinity
    @ObservationIgnored private var userWantsConnection = false
    @ObservationIgnored private var everStreamed = false
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var nextBatteryQuery = 0.0
    @ObservationIgnored private var lastSensorAt = 0.0
    @ObservationIgnored private var lastStatusQuery = 0.0
    @ObservationIgnored private var lastPacketAt = 0.0
    @ObservationIgnored private var lastDiagnosticsRefresh = 0.0
    @ObservationIgnored private var router = GestureRouter()
    /// Raw EMG as the user asked for it (the band's confirmation is `emgStreaming`).
    public private(set) var wantsEmg = false
    @ObservationIgnored private var nextEmgOffRetry = 0.0
    @ObservationIgnored private var hapticsQueue: [(HapticsCommand, CheckedContinuation<HapticsResult, Never>)] = []
    @ObservationIgnored private var hapticsInFlight: (command: HapticsCommand, sequence: UInt32, sentAt: Double, continuation: CheckedContinuation<HapticsResult, Never>)?
    @ObservationIgnored private var lastOrientationPublish = 0.0
    /// When the current attempt started, and whether the Bluetooth link itself came up.
    @ObservationIgnored private var attemptStartedAt = 0.0
    @ObservationIgnored private var linkUp = false
    /// Searching by name because the remembered iOS identity didn't answer (stale after "Forget This Device").
    @ObservationIgnored private var rediscoveringSince: Double?
    /// Identifies the current attempt; transport events from older links are ignored.
    @ObservationIgnored private var attempt = 0

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    public init(store: CredentialStore = CredentialStore(), metaStore: MetaSessionStore = MetaSessionStore()) {
        self.store = store
        self.metaStore = metaStore
        central.onChange = { [weak self] in self?.syncCentral() }
        reloadCredentials()
        logNotice(.app, "BandClient ready. Stored band: \(storedBand?.name ?? "none"); owner key: \(ownerFingerprint ?? "none"); pending key: \(hasPendingKey)")
    }

    private func syncCentral() {
        discovered = central.discovered.values.sorted {
            if $0.isBand != $1.isBand { return $0.isBand }
            return ($0.rssi ?? -127) > ($1.rssi ?? -127)
        }
        isScanning = central.isScanning
        bluetoothState = central.stateDescription
        continueRediscovery()
    }

    /// The remembered identity didn't connect within 8 s, typically because iOS forgot the band and gave
    /// it a new identifier. Abandon that attempt, scan, and connect to the band found by name.
    private func startRediscovery() {
        logWarning(.bluetooth, "The remembered band identity isn't answering after 8 s; scanning for \(storedBand?.name ?? "a Meta Band") instead")
        rediscoveringSince = now
        attempt += 1 // the abandoned link's events are ignored
        let old = link
        link = nil
        session = nil
        old?.close(reason: "stale identity; rediscovering")
        setPhase(.connecting("Looking for your band (put it in pairing mode if it doesn't appear)"))
        central.clearDiscovered()
        central.startScan()
    }

    private func continueRediscovery() {
        guard let since = rediscoveringSince, userWantsConnection else { return }
        let name = storedBand?.name
        if let device = discovered.first(where: { $0.isBand && (name == nil || $0.name == name) && $0.id != targetID }) {
            rediscoveringSince = nil
            central.stopScan()
            logNotice(.bluetooth, "Found \(device.name) under a new iOS identity \(device.id); connecting with the saved owner key")
            connect(to: device.id)
        } else if now - since > 60 {
            rediscoveringSince = nil
            central.stopScan()
            userWantsConnection = false
            fail(BandFailure(kind: .bluetooth, title: "Band not found",
                             detail: "The band didn't answer at its remembered identity and didn't show up in a scan.",
                             suggestion: "Put the band in pairing mode (hold ~3 s until it flashes), then tap it under Nearby.", code: nil))
        }
    }

    public func reloadCredentials() {
        storedBand = store.loadBand()
        let owner = try? store.loadOwner()
        ownerFingerprint = owner?.fingerprint
        ownerHasBandKey = owner?.verifiesBand ?? false
        hasPendingKey = store.hasPending
        hasMetaSession = metaStore.load() != nil
    }

    public var hasOwnerKey: Bool { ownerFingerprint != nil || hasPendingKey }

    // MARK: scanning

    public func startScan() { central.startScan() }
    public func stopScan() { central.stopScan() }

    // MARK: public operations

    /// Connect as the stored owner. `id` picks the band (needed after importing a key from another device).
    public func connect(to id: UUID? = nil) {
        guard let target = id ?? storedBand?.peripheralID else {
            fail(BandFailure(kind: .credentials, title: "Choose your band", detail: "This iPhone hasn't connected to the band yet.",
                             suggestion: "Scan, then tap your band to connect with the saved owner key.", code: nil))
            return
        }
        guard hasOwnerKey else {
            fail(BandFailure(kind: .credentials, title: "No owner key on this iPhone", detail: "Connecting needs the band's owner key.",
                             suggestion: "Import air-gestures-band.json, or claim the band with a Meta sign-in.", code: nil))
            return
        }
        userWantsConnection = true
        reconnectAttempt = 0
        schemeGuess = storedBand?.schemeGuess ?? 0
        usingPendingKey = store.hasPending
        begin(.connect, target: target)
    }

    /// Experimental: connect a band in pairing mode without any owner key (kinesis's original
    /// startup). Older firmware may stream gestures this way without being claimed.
    public func connectWithoutKey(to id: UUID) {
        userWantsConnection = true
        reconnectAttempt = 0
        schemeGuess = storedBand?.schemeGuess ?? 0
        begin(.legacy, target: id)
    }

    /// Claim a band in pairing mode with a fresh owner key. The caller must have confirmed with the
    /// user when a key already exists: a successful claim replaces it.
    public func claim(_ id: UUID, metaSession: MetaSession) {
        userWantsConnection = true
        reconnectAttempt = 0
        schemeGuess = 0
        self.metaSession = metaSession
        claimCompleted = false
        pendingSavedThisRun = false
        begin(.claim, target: id)
    }

    public func disconnect() {
        userWantsConnection = false
        rediscoveringSince = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        guard let session, let link else {
            attempt += 1
            stopTimerIfIdle()
            setPhase(.idle)
            return
        }
        if session.handwritingActive, !disconnectAfterRestore {
            // Put the band's settings back before letting go; disconnect when that finishes.
            disconnectAfterRestore = true
            session.stopHandwriting(time: now)
            logNotice(.app, "Disconnect requested: restoring the band's handwriting settings first")
            return
        }
        disconnectAfterRestore = false
        logNotice(.app, "Disconnect requested by user")
        do {
            let bytes = try session.stop()
            if bytes.isEmpty {
                link.close(reason: "user disconnect")
            } else {
                link.write(bytes)
                deadline = now + 3
            }
        } catch {
            link.close(reason: "user disconnect (stop failed: \(error.localizedDescription))")
        }
    }

    public func setRawEmg(_ enabled: Bool) {
        wantsEmg = enabled
        emgError = nil
        guard let session, let link else { return }
        do {
            link.write(try session.setRawEmgEnabled(enabled, time: now))
            logNotice(.emg, "Raw EMG \(enabled ? "requested" : "turning off")")
        } catch {
            emgError = error.localizedDescription
            logWarning(.emg, "Raw EMG change failed: \(error.localizedDescription)")
        }
    }

    /// Writes the band's persisted hand setting (`ConfigReq.is_left_handed`), then confirms it with an
    /// independent read. Explicit user action only.
    public func setHand(_ hand: Hand) {
        guard let session, let link, phase == .streaming else {
            handSync = .failed("Connect the band first.")
            return
        }
        do {
            link.write(try session.setHandedness(hand, time: now))
            handSync = .writing(hand)
            logNotice(.session, "Writing band hand setting: \(hand.rawValue) (was \(self.hand?.rawValue ?? "unknown")); will verify by reading it back")
        } catch {
            handSync = .failed(error.localizedDescription)
            logWarning(.session, "Hand change refused: \(error.localizedDescription)")
        }
    }

    /// Switch the band's handwriting model on. The band's settings are found by name, snapshotted,
    /// changed, read back, and restored by `stopHandwriting()` (or on the next connect if interrupted).
    public func startHandwriting() {
        guard let session else { return }
        do {
            try session.startHandwriting(time: now)
            UserDefaults.standard.set(true, forKey: Self.handwritingRecoveryKey)
            logNotice(.session, "Handwriting: starting the band's handwriting model")
        } catch {
            handwriting = ModelCaptureStatus(phase: .finished, message: error.localizedDescription, problem: error.localizedDescription, restorationVerified: false)
        }
    }

    public func stopHandwriting() {
        guard let session, session.handwritingActive else { return }
        session.stopHandwriting(time: now)
        logNotice(.session, "Handwriting: restoring the band's normal mode")
    }

    /// Raw EMG, the handwriting model and experimental streams drain the band's battery, so they're
    /// switched off when the app leaves the foreground and stay off until the user turns them on
    /// again. Gestures keep working; a firmware update is left running. True if anything was on.
    @discardableResult
    public func pauseExtras() -> Bool {
        var paused: [String] = []
        if wantsEmg || emgStreaming { setRawEmg(false); paused.append("raw EMG") }
        if session?.handwritingActive == true { stopHandwriting(); paused.append("handwriting") }
        if !probeRequested.isEmpty { setProbeStreams([]); paused.append("experimental streams") }
        guard !paused.isEmpty else { return false }
        logNotice(.session, "App left the foreground: switching off \(paused.joined(separator: ", ")) to save the band's battery")
        return true
    }

    /// True while switching those off still waits on the band.
    public var extrasStopping: Bool {
        guard let session, link != nil else { return false }
        return session.handwritingActive || (!wantsEmg && (emgStreaming || session.rawEmgRequested))
    }

    /// Reads every band setting, the band's config and its update status. Read requests only.
    public func startSurvey() {
        guard let session, phase == .streaming else { return }
        do {
            try session.startSurvey(time: now)
            logNotice(.session, "Survey: reading the band's settings, config and update status (read only)")
        } catch {
            survey.problems.append(error.localizedDescription)
        }
    }

    /// Turns experimental stream flags on (any others touched before off). Not persisted by the band.
    public func setProbeStreams(_ fields: Set<UInt32>) {
        guard let session, let link, phase == .streaming else { probeError = "Connect the band first."; return }
        do {
            link.write(try session.setProbeStreams(fields, time: now))
            probeRequested = fields
            probeError = nil
        } catch {
            probeError = error.localizedDescription
        }
    }

    /// Runs one firmware update step. Explicit user action only; see `OtaMode`.
    public func startOta(_ plan: OtaPlan) {
        guard let session, let link, phase == .streaming else { otaError = "Connect the band first."; return }
        do {
            let result = try session.otaStart(plan, time: now)
            otaError = nil
            if plan.mode != .cancel { otaLog = [] }
            logNotice(.session, "Firmware: \(plan.mode.rawValue) of \(plan.version) started by the user")
            link.write(result.outgoing)
            for event in result.events { handle(event) }
        } catch {
            otaError = error.localizedDescription
            logWarning(.session, "Firmware: \(plan.mode.rawValue) refused: \(error.localizedDescription)")
        }
    }

    /// Stops a running update before its Commit and aborts what the band holds.
    public func cancelOta() { startOta(.cancel) }

    /// Reads the band's update status (firmware, staged build, key) without changing anything.
    public func refreshUpdateStatus() {
        guard let session, phase == .streaming, !session.surveyRunning else { return }
        try? session.startSurvey(time: now, updateStatusOnly: true)
    }

    public func dismissFirmwareInstall() {
        firmwareInstall = nil
        FirmwareInstall.clear()
    }

    private func handleOta(_ report: OtaReport) {
        ota = report
        otaLog += report.lines
        if otaLog.count > 600 { otaLog.removeFirst(otaLog.count - 600) }
        // A Commit the band never answered (it may already be rebooting) is followed up the same way:
        // what the band runs after it comes back decides.
        if report.committed, firmwareInstall?.version != report.version || firmwareInstall?.stage == .installed || firmwareInstall?.stage == .failed {
            firmwareInstall = FirmwareInstall(version: report.version, stage: .restarting, since: Date())
            firmwareInstall?.save()
            logNotice(.session, "Firmware: install of \(report.version) committed (\(report.commitAccepted ? "accepted" : "no answer yet")); the band restarts now")
        }
    }

    /// After the band comes back from an install: ask what it runs.
    private func checkInstallAfterConnect() {
        guard var install = firmwareInstall, install.stage == .restarting || install.stage == .checking else { return }
        install.stage = .checking
        firmwareInstall = install
        install.save()
        refreshUpdateStatus()
    }

    private func finishInstallCheck(_ status: OtaStatus) {
        guard var install = firmwareInstall, install.stage == .checking, let active = status.activeFirmware else { return }
        install.running = active
        install.stage = active == install.version ? .installed : .failed
        firmwareInstall = install
        install.save()
        logNotice(.session, "Firmware: after the restart the band runs \(active) (\(install.stage == .installed ? "the new build" : "NOT \(install.version)"))")
    }

    /// Make the band's own hand setting match the app's selected wrist.
    public func syncWristToBand() { setHand(wrist.wrist.hand) }

    /// Queue one haptics command; resolves once the band answers (or after 5 s / on disconnect).
    public func haptic(_ command: HapticsCommand) async -> HapticsResult {
        guard phase == .streaming, session != nil else {
            return HapticsResult(command: command, delivered: false, rpcSuccess: false, hapticsSuccess: nil, roundTrip: nil,
                                 error: "Connect the band first.")
        }
        return await withCheckedContinuation { continuation in
            hapticsQueue.append((command, continuation))
            pumpHaptics()
        }
    }

    /// Simulated gestures are explicitly labeled and never mixed up with band events.
    public func simulate(_ gesture: RecognizedGesture, source: EventSource = .simulated) {
        logInfo(.gestures, "\(source == .touch ? "Touch" : "SIMULATED") gesture: \(gesture.title)")
        events.publish(.gesture(GestureEvent(gesture: gesture, source: source)))
    }

    // MARK: credentials

    public func importCredentials(_ imported: AirGesturesFile.Imported, origin: StoredBand.Origin) throws {
        try store.saveOwner(imported.identity)
        var band = storedBand ?? StoredBand(name: imported.band?.name ?? "Meta Neural Band", origin: origin)
        band.origin = origin
        band.savedAt = Date()
        if let record = imported.band {
            band.name = record.name
            band.schemeGuess = record.schemeGuess ?? band.schemeGuess
            // A phone may have recorded a resolvable private address; keep a known public one instead.
            if !(AirGesturesBand.isPrivateAddress(record.address) && band.address != nil) { band.address = record.address }
        }
        try store.saveBand(band)
        reloadCredentials()
        logNotice(.credentials, "Imported owner key \(imported.identity.fingerprint) (band record: \(imported.band != nil), raw key: \(imported.rawKey))")
    }

    public func updateBand(_ change: (inout StoredBand) -> Void) {
        var band = storedBand ?? StoredBand(name: "Meta Neural Band", origin: .imported)
        change(&band)
        do {
            try store.saveBand(band)
            reloadCredentials()
        } catch {
            logError(.credentials, "Couldn't save the band record: \(BandLog.describe(error))")
        }
    }

    public func deleteLocalCredentials() throws {
        disconnect()
        try store.deleteAll()
        reloadCredentials()
    }

    public func saveMetaSession(_ session: MetaSession) {
        metaStore.save(session)
        hasMetaSession = true
    }

    public func forgetMetaSession() {
        metaStore.delete()
        hasMetaSession = false
    }

    // MARK: attempt lifecycle

    private func begin(_ operation: Operation, target: UUID) {
        reconnectTask?.cancel()
        reconnectTask = nil
        // Bump first: the old link's synchronous `.closed` must not touch this attempt.
        attempt += 1
        let generation = attempt
        if let old = link {
            link = nil
            session = nil
            old.close(reason: "starting a new attempt")
        }
        self.operation = operation
        targetID = target
        router.reset()
        diagnostics.connectAttempts += 1
        diagnostics.startedAt = Date()
        attemptStartedAt = now
        linkUp = false
        diagnostics.peripheralID = target
        diagnostics.streamingSince = nil
        diagnostics.timeToStreaming = nil
        let mode: SessionMode
        switch operation {
        case .claim:
            mode = .ceremony
            diagnostics.ownershipMode = "claiming (ownership ceremony)"
            diagnostics.ownerFingerprint = nil
        case .legacy:
            mode = .legacy
            diagnostics.ownershipMode = "no owner key (pairing-mode legacy startup)"
            diagnostics.ownerFingerprint = nil
        case .connect:
            let identity = usingPendingKey ? (try? store.loadPending()) ?? nil : nil
            if let identity {
                mode = .enrolled(identity)
                diagnostics.ownershipMode = "owner key (pending, unconfirmed)"
                diagnostics.ownerFingerprint = identity.fingerprint
            } else if let identity = try? store.loadOwner() {
                usingPendingKey = false
                mode = .enrolled(identity)
                diagnostics.ownershipMode = "owner key (confirmed)"
                diagnostics.ownerFingerprint = identity.fingerprint
            } else {
                fail(BandFailure(kind: .credentials, title: "The owner key couldn't be read",
                                 detail: "The Keychain item is missing or corrupt.", suggestion: "Import the key again.", code: nil))
                return
            }
        }
        let session = BandSession(mode: mode, rawEmg: wantsEmg, schemeGuess: schemeGuess)
        session.logFrames = BandLog.shared.logsFrames
        probeRequested = []
        probeReported = [:]
        probeError = nil
        if survey.phase == .running { survey.phase = .idle; survey.message = "Interrupted by a reconnect" }
        self.session = session
        deadline = now + (operation == .claim ? 180 : 30)
        lastPacketAt = now
        lastSensorAt = now
        logNotice(.app, "Attempt #\(diagnostics.connectAttempts): \(operation == .claim ? "claim" : "connect") band \(target) with \(diagnostics.ownershipMode), key guess \(schemeGuess)")
        setPhase(operation == .claim ? .claiming("Connecting to the band") : .connecting("Connecting to the band"))
        startTimer()
        link = central.openLink(to: target) { [weak self] event in
            guard let self, self.attempt == generation else { return }
            self.handle(event)
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .stage(let stage):
            if stage == "Discovering services" { linkUp = true }
            if operation == .claim { setPhase(.claiming(stage)) } else { setPhase(.connecting(stage)) }
        case .systemPairingPrompt:
            deadline = max(deadline, now + 40)
            setPhase(.pairingPrompt)
        case .gatt(let services):
            diagnostics.gatt = services
            diagnostics.peripheralName = link?.peripheralName
        case .deviceInformation(let info):
            diagnostics.deviceInformation = info
        case .batteryLevel(let level):
            if battery != level { logInfo(.bluetooth, "Battery \(level)% (GATT)") }
            battery = level
            events.publish(.battery(level: level, charging: charging))
        case .rssi(let value):
            rssi = value
        case .l2capOpened(let psm, let maxWrite):
            diagnostics.psm = psm
            diagnostics.maxWriteLength = maxWrite
            diagnostics.l2capOpenedAt = Date()
            setPhase(operation == .claim ? .claiming("Encrypting the link") : .authenticating("Encrypting the link"))
            do {
                link?.write(try session?.request() ?? [])
                logInfo(.crypto, "Sent RequestEncryption (P-256, offering schemes bitmask 31)")
            } catch { failSession(error) }
        case .bytes(let bytes):
            feed(bytes)
        case .closed(let error):
            ended(error)
        }
    }

    private func feed(_ bytes: [UInt8]) {
        guard let session, let link else { return }
        lastPacketAt = now
        do {
            let result = try session.feed(bytes, time: now)
            drainNotes()
            link.write(result.outgoing)
            for event in result.events { handle(event) }
        } catch {
            drainNotes()
            failSession(error)
        }
        if session.stopping, session.stopAcknowledged { link.close(reason: "streams stopped") }
    }

    private func drainNotes() {
        guard let session else { return }
        for note in session.takeNotes() {
            let category: BandLog.Category = note.text.hasPrefix("Ceremony") ? .ownership : (note.text.contains("EMG") ? .emg : .session)
            switch note.level {
            case .debug: logDebug(category, note.text)
            case .info: logInfo(category, note.text)
            case .notice: logNotice(category, note.text)
            case .warning: logWarning(category, note.text)
            }
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .connected:
            everStreamed = true
            reconnectAttempt = 0
            deadline = .infinity
            diagnostics.streamingSince = Date()
            diagnostics.timeToStreaming = diagnostics.startedAt.map { Date().timeIntervalSince($0) }
            setPhase(.streaming)
            persistAfterConnect()
            if UserDefaults.standard.bool(forKey: Self.handwritingRecoveryKey), let session {
                logWarning(.session, "Handwriting: the last capture didn't finish; restoring the band's normal settings")
                try? session.recoverHandwriting(time: now)
            }
            nextBatteryQuery = now
            checkInstallAfterConnect()
        case .heartbeat:
            break
        case .dataSeen:
            lastSensorAt = now
        case .gesture(let message):
            logInfo(.gestures, "Band gesture #\(message.sequence): finger \(message.finger), action \(message.action), derived \(message.derivedAction)\(message.synthetic ? " (synthetic)" : "")")
            events.publish(.rawGesture(message))
            if let raw = router.route(message, now: now) {
                let gesture = wrist.normalize(raw)
                let event = GestureEvent(gesture: gesture, source: .band, uptime: message.receivedAt,
                                         bandTimestampMicros: message.timestampMicros, sequence: message.sequence, raw: raw)
                events.publish(.gesture(event))
                let dispatched = now
                diagnostics.recognizedGestures += 1
                diagnostics.lastGestureDispatchMs = (dispatched - message.receivedAt) * 1000
                if let last = diagnostics.lastGestureAt {
                    diagnostics.gestureIntervals.append(message.receivedAt - last)
                    if diagnostics.gestureIntervals.count > 50 { diagnostics.gestureIntervals.removeFirst() }
                }
                diagnostics.lastGestureAt = message.receivedAt
                logNotice(.gestures, "Recognized: \(gesture.title)\(gesture != raw ? " (band said \(raw.title); \(wrist.wrist.title) profile)" : "")")
            }
        case .dialState(let engaged):
            logInfo(.gestures, "Pinch dial \(engaged ? "engaged" : "released")")
            events.publish(.dialEngaged(engaged))
        case .dialTurn(let delta):
            events.publish(.dialTurn(wrist.normalizeDial(delta)))
        case .motion(let timestamp, let gyro):
            events.publish(.motion(gyro: gyro * 0.07, bandTimestampMicros: timestamp))
        case .orientation(let q):
            if now - lastOrientationPublish >= 0.01 {
                lastOrientationPublish = now
                events.publish(.orientation(q))
            }
        case .handedness(let hand):
            self.hand = hand
            if case .writing(let target) = handSync {
                handSync = hand == target ? .confirmed(hand, Date()) : .failed("The band read back \(hand.rawValue), not \(target.rawValue).")
                logNotice(.session, hand == target ? "Band hand setting verified by readback: \(hand.rawValue)" : "Band hand readback mismatch: \(hand.rawValue) ≠ \(target.rawValue)")
            }
            if hand != wrist.wrist.hand {
                logWarning(.session, "Band is set to the \(hand.rawValue) hand but the app profile is \(wrist.wrist.title). The band's classifier may need its setting to match the worn wrist.")
            }
        case .handednessFailure(let message):
            logWarning(.session, "Hand: \(message)")
            if case .writing = handSync { handSync = .failed(message) }
        case .hapticsFinished(let sequence, let rpcSuccess, let hapticsSuccess):
            finishHaptics(sequence: sequence, rpcSuccess: rpcSuccess, hapticsSuccess: hapticsSuccess)
        case .batteryStatus(let status):
            if let status {
                if battery != status.level || charging != status.charging {
                    logInfo(.session, "Battery \(status.level)%, charging \(status.charging.map { $0 ? "yes" : "no" } ?? "unknown")")
                }
                battery = status.level
                charging = status.charging
                events.publish(.battery(level: status.level, charging: status.charging))
            }
        case .deviceInfo(let info):
            deviceInfo = info
        case .rawEmgFrame(let payload):
            if let config = emgConfig, let batch = try? EmgBatch.parse(payload: payload, config: config) {
                events.publish(.emg(batch, receivedAt: now))
            } else if emgConfig == nil || !(emgConfig!.isSupported) {
                if session?.rawEmgFrames == 1 { logWarning(.emg, "EMG frames arrived but the configuration is unknown or unsupported; not decoding") }
            }
        case .rawEmgConfiguration(let config):
            emgConfig = config
            events.publish(.emgConfiguration(config))
            if !config.isSupported {
                emgError = "The band reports an EMG layout this viewer doesn't decode (\(config.channels) ch @ \(config.sampleRate) Hz, encoding \(config.encoding))."
                logWarning(.emg, emgError!)
            }
        case .rawEmgState(let on):
            emgStreaming = on
            logNotice(.emg, "Band confirmed raw EMG \(on ? "on" : "off")")
        case .rawEmgFailure(let message):
            emgStreaming = false
            emgError = message
            logWarning(.emg, message)
        case .ceremonyStage(let stage):
            ceremonyStage = stage
            setPhase(claimCompleted ? .authenticating(stage) : .claiming(stage))
            logNotice(.ownership, "Claim stage: \(stage)")
        case .ceremonyHttp(let request):
            runCeremonyHTTP(request)
        case .ceremonyCompleted(let identity):
            claimCompleted = true
            do {
                try store.saveOwner(identity)
                var band = storedBand ?? StoredBand(name: link?.peripheralName ?? "Meta Neural Band", origin: .claimedHere)
                band.origin = .claimedHere
                band.peripheralID = targetID
                band.name = link?.peripheralName ?? band.name
                band.schemeGuess = session?.guessing == true ? session?.schemeGuess : nil
                band.savedAt = Date()
                try store.saveBand(band)
                reloadCredentials()
                claimJustCompleted = true
                logNotice(.ownership, "The band accepted this iPhone as its owner. Owner key \(identity.fingerprint) saved; band key from Meta: \(identity.verifiesBand)")
            } catch {
                logError(.credentials, "Couldn't save the new owner key: \(BandLog.describe(error)). The pending copy remains.")
            }
        case .modelCaptureState(let status):
            handwriting = status
            logNotice(.session, "Handwriting: \(status.message)\(status.problem.map { " (\($0))" } ?? "")")
            if status.phase == .finished, status.restorationVerified {
                UserDefaults.standard.set(false, forKey: Self.handwritingRecoveryKey)
            }
            events.publish(.handwritingState(status))
            if disconnectAfterRestore, !status.active { disconnect() }
        case .inferenceSample(let sample):
            events.publish(.inference(sample))
        case .surveyUpdated(let report):
            survey = report
            if let status = report.ota { finishInstallCheck(status) }
        case .probeStreams(let reported):
            probeReported.merge(reported) { $1 }
            let refused = probeRequested.filter { reported[$0] != 1 }
            probeError = reported.isEmpty ? "The band didn't confirm the stream change." :
                refused.isEmpty ? nil : "The band left \(refused.sorted().map(String.init).joined(separator: ", ")) off."
        case .otaProgress(let report):
            handleOta(report)
        case .firmwareLog(let text):
            logInfo(.session, "Band firmware log: \(text)")
            firmwareLog.append((Date(), text))
            if firmwareLog.count > 300 { firmwareLog.removeFirst(firmwareLog.count - 300) }
        case .ownerTrusted(let verified):
            diagnostics.bandVerified = verified
            logNotice(.ownership, "Mutual trust established with the owner key (band proof \(verified ? "verified" : "not verifiable: no band key"))")
            if usingPendingKey {
                try? store.promotePending()
                usingPendingKey = false
                reloadCredentials()
            }
            setPhase(.authenticating("Subscribing to gestures"))
        }
    }

    private func persistAfterConnect() {
        guard let targetID else { return }
        var band = storedBand ?? StoredBand(name: link?.peripheralName ?? "Meta Neural Band", origin: .imported)
        band.peripheralID = targetID
        if let name = link?.peripheralName { band.name = name }
        if let session, session.guessing { band.schemeGuess = session.schemeGuess }
        if let info = deviceInfo ?? session?.deviceInfo {
            band.firmware = info.firmware
            band.hardware = info.hardware
            band.serial = info.serial
        }
        band.lastConnectedAt = Date()
        try? store.saveBand(band)
        reloadCredentials()
    }

    private func runCeremonyHTTP(_ request: CeremonyHttpRequest) {
        guard let metaSession else {
            failSession(MetaSessionInvalidError(message: "Sign in to Meta to claim the band."))
            return
        }
        let client = MetaPairClient(session: metaSession)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch request {
                case .pairRequest(let pairRequest):
                    let pending = try await client.pairRequest(pairRequest)
                    guard let session = self.session, let link = self.link else { return }
                    link.write(try session.ceremonyPairRequestCompleted(signature: pending.signature, receipt: pending.receipt))
                case .pair(let pair):
                    let final = try await client.pair(pair)
                    guard let session = self.session, let link = self.link else { return }
                    let bytes = try session.ceremonyPairCompleted(signature: final.signature, receipt: final.receipt,
                                                                  devicePublicKey: final.devicePublicKey)
                    // Save the key BEFORE FinishChangeOwner: the band may commit even if its answer is lost.
                    if let pending = session.pendingIdentity {
                        try self.store.savePending(pending)
                        self.pendingSavedThisRun = true
                        self.hasPendingKey = true
                    }
                    link.write(bytes)
                }
            } catch {
                self.failSession(error)
            }
        }
    }

    // MARK: haptics

    private func pumpHaptics() {
        guard hapticsInFlight == nil, !hapticsQueue.isEmpty, let session, let link else { return }
        guard session.hapticsReady else { return }
        let (command, continuation) = hapticsQueue.removeFirst()
        do {
            let bytes = try session.sendHaptics(command, time: now)
            link.write(bytes)
            diagnostics.hapticsSent += 1
            hapticsInFlight = (command, UInt32(truncatingIfNeeded: diagnostics.hapticsSent), now, continuation)
            logInfo(.haptics, "Sent \(command)")
        } catch {
            continuation.resume(returning: HapticsResult(command: command, delivered: false, rpcSuccess: false, hapticsSuccess: nil,
                                                         roundTrip: nil, error: error.localizedDescription))
            logWarning(.haptics, "Haptics refused: \(error.localizedDescription)")
        }
    }

    private func finishHaptics(sequence: UInt32, rpcSuccess: Bool, hapticsSuccess: Bool?) {
        guard let inFlight = hapticsInFlight else { return }
        hapticsInFlight = nil
        let roundTrip = now - inFlight.sentAt
        if rpcSuccess { diagnostics.hapticsAcknowledged += 1 }
        logInfo(.haptics, "Haptics answered: rpc \(rpcSuccess), haptics \(hapticsSuccess.map { "\($0)" } ?? "no detail") in \(Int(roundTrip * 1000)) ms")
        let result = HapticsResult(command: inFlight.command, delivered: true, rpcSuccess: rpcSuccess, hapticsSuccess: hapticsSuccess,
                                   roundTrip: roundTrip, error: rpcSuccess ? nil : "The band didn't confirm the vibration.")
        inFlight.continuation.resume(returning: result)
        events.publish(.haptics(result))
        pumpHaptics()
    }

    private func flushHaptics(reason: String) {
        if let inFlight = hapticsInFlight {
            inFlight.continuation.resume(returning: HapticsResult(command: inFlight.command, delivered: false, rpcSuccess: false,
                                                                  hapticsSuccess: nil, roundTrip: nil, error: reason))
            hapticsInFlight = nil
        }
        for (command, continuation) in hapticsQueue {
            continuation.resume(returning: HapticsResult(command: command, delivered: false, rpcSuccess: false, hapticsSuccess: nil,
                                                         roundTrip: nil, error: reason))
        }
        hapticsQueue.removeAll()
    }

    // MARK: periodic

    private func tick() {
        let time = now
        if let session, let link {
            for event in session.tick(time: time) { handle(event) }
            drainNotes()
            if time >= deadline {
                if session.stopping { link.close(reason: "stop acknowledgement timed out"); return }
                failSession(TransportError(operation == .claim
                    ? "The claim took too long. Keep the band in pairing mode and close to the iPhone, then retry."
                    : "The band took too long to respond (stage \(session.stageName))."))
                return
            }
            if operation != .claim, !linkUp, rediscoveringSince == nil, time - attemptStartedAt > 8 {
                startRediscovery()
                return
            }
            if session.guessing, session.encryptionEstablished, session.authenticatedPackets == 0, time - lastPacketAt > 6 {
                failSession(TransportError("No authenticated reply 6 s after key exchange (encryption key guess \(session.schemeGuess))."))
                return
            }
            if session.streamsEnabled, !session.stopping, !wantsEmg, session.rawEmgRequested, time >= nextEmgOffRetry {
                // An EMG change was in flight when it was switched off: try again once it's done.
                nextEmgOffRetry = time + 1
                setRawEmg(false)
            }
            if session.streamsEnabled, !session.stopping {
                do {
                    if time >= nextBatteryQuery {
                        nextBatteryQuery = time + 5
                        link.write(try session.queryBatteryStatus(time: time))
                    }
                    if time - lastSensorAt >= 2, time - lastStatusQuery >= 2 {
                        lastStatusQuery = time
                        link.write(try session.queryStreamState())
                    }
                } catch { failSession(error); return }
                // A firmware update can keep the band busy verifying for a while.
                if time - lastPacketAt > (session.otaRunning ? 30 : 8) {
                    failSession(TransportError("The band stopped responding (no authenticated traffic for 8 s)."))
                    return
                }
                pumpHaptics()
                do {
                    let update = try session.otaTick(time: time)
                    link.write(update.outgoing)
                    for event in update.events { handle(event) }
                    let capture = try session.flushModelCapture(time: time)
                    link.write(capture.outgoing)
                    drainNotes()
                    for event in capture.events { handle(event) }
                } catch { failSession(error); return }
            }
            if time - lastDiagnosticsRefresh >= 0.5 {
                lastDiagnosticsRefresh = time
                refreshDiagnostics(session, link)
            }
        }
    }

    private func refreshDiagnostics(_ session: BandSession, _ link: BandLink) {
        diagnostics.bytesIn = link.bytesRead
        diagnostics.bytesOut = link.bytesWritten
        diagnostics.sessionStage = session.stageName
        diagnostics.schemeGuess = session.guessing ? session.schemeGuess : nil
        diagnostics.newerFirmwareScheme = session.guessing
        diagnostics.peerParameters = session.encryptionEstablished ? session.peerParameters : nil
        diagnostics.authenticatedPackets = session.authenticatedPackets
        diagnostics.framesDecoded = session.framesDecoded
        diagnostics.decodeFailures = session.decodeFailures
        diagnostics.skippedTransportRecords = session.skippedTransportRecords
        diagnostics.unknownKinds = Dictionary(uniqueKeysWithValues: session.unknownKinds.map { ("0x" + $0.key.hex8, $0.value) })
        diagnostics.unknownShapes = Dictionary(uniqueKeysWithValues: session.unknownShapes.map { ("0x" + $0.key.hex8, $0.value) })
        diagnostics.gestureMessages = session.gestureMessages
        diagnostics.motionMessages = session.motionMessages
        diagnostics.orientationMessages = session.orientationMessages
        diagnostics.emgFrames = session.rawEmgFrames
        diagnostics.messageCounts = Dictionary(uniqueKeysWithValues: session.kindCounts.map { ("0x" + $0.key.hex8, $0.value) })
    }

    // MARK: failure and retry

    private func failSession(_ error: Error) {
        logError(.session, "Session failed during \(session?.stageName ?? "?"): \(BandLog.describe(error))")
        lastError = error
        link?.close(reason: "session failed")
    }

    @ObservationIgnored private var lastError: Error?

    private func ended(_ transportError: Error?) {
        let error = lastError ?? transportError
        lastError = nil
        let session = self.session
        let operation = self.operation
        self.session = nil
        self.link = nil
        flushHaptics(reason: "The band disconnected.")
        emgStreaming = false
        if let error { record(error) }

        guard userWantsConnection, let operation, let targetID, let session else {
            logNotice(.app, "Link closed (\(error.map { $0.localizedDescription } ?? "on request"))")
            stopTimerIfIdle()
            setPhase(.idle)
            return
        }

        // 1. A wrong scheme-26 key guess: nothing authenticated, so nothing was claimed. Try the next.
        if session.guessing, session.encryptionEstablished, session.authenticatedPackets == 0,
           schemeGuess + 1 < AirShieldVariant.scheme26Guesses.count, !pendingSavedThisRun {
            schemeGuess += 1
            logWarning(.crypto, "Encryption key guess \(schemeGuess - 1) failed (band names scheme \(session.peerParameters)); trying guess \(schemeGuess) of \(AirShieldVariant.scheme26Guesses.count - 1)")
            retry(operation, target: targetID, after: 1)
            return
        }

        if let bandError = error as? BandError {
            switch bandError {
            case .identityMismatch(let code, let message):
                if usingPendingKey, (try? store.loadOwner()) != nil {
                    logWarning(.ownership, "The band rejected the pending key (0x\(String(code, radix: 16))); discarding it and trying the confirmed key")
                    try? store.discardPending()
                    usingPendingKey = false
                    reloadCredentials()
                    retry(.connect, target: targetID, after: 0.5)
                    return
                }
                userWantsConnection = false
                fail(BandFailure(kind: .ownerKeyRejected, title: "The band rejected this owner key", detail: message,
                                 suggestion: "Import the key that claimed this band (air-gestures-band.json), or claim it again after a factory reset.",
                                 code: code))
                return
            case .ownershipRejected(let code, let message):
                if pendingSavedThisRun, !claimCompleted { try? store.discardPending(); reloadCredentials() }
                userWantsConnection = false
                fail(BandFailure(kind: code == 0x1042 ? .wrongAccount : .claimRejected,
                                 title: code == 0x1042 ? "Owned by another Meta account" : "The band refused the claim",
                                 detail: message,
                                 suggestion: "Factory reset the band (hold its button ~16 s), put it in pairing mode (hold ~3 s until it flashes), then claim again.",
                                 code: code))
                return
            case .busy(let message):
                userWantsConnection = false
                fail(BandFailure(kind: .busy, title: "Band busy", detail: message, suggestion: nil, code: nil))
                return
            case .protocolError(let message) where message == BandSession.bandBusy:
                userWantsConnection = false
                fail(BandFailure(kind: .busy, title: "The band is connected elsewhere", detail: message,
                                 suggestion: "Disconnect it on your other device (Linux: `air-gestures disconnect`), then retry.", code: nil))
                return
            default: break
            }
        }
        if error is MetaSessionInvalidError {
            forgetMetaSession()
            userWantsConnection = false
            fail(BandFailure(kind: .metaSession, title: "Sign in to Meta again", detail: error!.localizedDescription,
                             suggestion: "Keep the band in pairing mode, sign in, and claim again.", code: nil))
            return
        }
        if error is MetaAuthError {
            userWantsConnection = false
            fail(BandFailure(kind: .meta, title: "Meta didn't approve the claim", detail: error!.localizedDescription,
                             suggestion: "Retry in a moment. Meta's claim service is undocumented and can change.", code: nil))
            return
        }
        if operation == .legacy, !everStreamed {
            userWantsConnection = false
            fail(BandFailure(kind: .protocolError, title: "The band didn't stream without a key",
                             detail: error?.localizedDescription ?? "The connection closed.",
                             suggestion: "This works only on some firmware, with the band in pairing mode (hold ~3 s until it flashes). Copy the log and share it.",
                             code: nil))
            return
        }
        if operation == .claim {
            userWantsConnection = false
            let committed = claimCompleted || pendingSavedThisRun
            fail(BandFailure(kind: .protocolError, title: committed ? "The claim may have finished" : "The claim didn't finish",
                             detail: error?.localizedDescription ?? "The connection closed.",
                             suggestion: committed ? "The new owner key was saved. Tap Connect to finish setting up." : "Keep the band in pairing mode and try again.",
                             code: nil))
            return
        }
        // 2. A dropped or failed connection: back off and retry while the user wants the band.
        if autoReconnect, everStreamed || reconnectAttempt < 2 {
            reconnectAttempt += 1
            diagnostics.reconnects += 1
            let delay = min(30, pow(2, Double(min(reconnectAttempt, 5))))
            logNotice(.app, "Reconnecting in \(Int(delay)) s (attempt \(reconnectAttempt)) after: \(error?.localizedDescription ?? "disconnect")")
            setPhase(.reconnecting(attempt: reconnectAttempt, delay: delay))
            retry(operation == .legacy ? .legacy : .connect, target: targetID, after: delay)
            return
        }
        userWantsConnection = false
        fail(classify(error))
    }

    private func retry(_ operation: Operation, target: UUID, after delay: Double) {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.userWantsConnection else { return }
            self.begin(operation, target: target)
        }
    }

    private func classify(_ error: Error?) -> BandFailure {
        guard let error else {
            return BandFailure(kind: .bluetooth, title: "The band disconnected", detail: "The connection closed.", suggestion: "Make sure the band is awake and nearby.", code: nil)
        }
        let native = error as NSError
        if native.domain == CBErrorDomain || native.domain == CBATTErrorDomain || error is TransportError {
            let pairing = error.localizedDescription.localizedCaseInsensitiveContains("pair")
            return BandFailure(kind: pairing ? .pairing : .bluetooth, title: pairing ? "Bluetooth pairing problem" : "Bluetooth connection failed",
                               detail: error.localizedDescription,
                               suggestion: pairing ? nil : "Keep the band close, make sure it isn't connected to another device, and retry.", code: nil)
        }
        if let bandError = error as? BandError, case .protocolError(let message) = bandError, message.contains("authentication") || message.contains("key guess") {
            return BandFailure(kind: .encryption, title: "Encryption didn't match", detail: message,
                               suggestion: "Your firmware may use a scheme none of the 8 known guesses fit. Export the log and share it.", code: nil)
        }
        return BandFailure(kind: .protocolError, title: "Connection failed", detail: error.localizedDescription,
                           suggestion: "Export the log from Diagnostics if this keeps happening.", code: nil)
    }

    private func record(_ error: Error) {
        let message = BandLog.describe(error)
        diagnostics.lastError = message
        diagnostics.errors.append((Date(), message))
        if diagnostics.errors.count > 50 { diagnostics.errors.removeFirst() }
    }

    private func fail(_ failure: BandFailure) {
        logError(.app, "\(failure.title): \(failure.detail)\(failure.code.map { " [code 0x\(String($0, radix: 16))]" } ?? "")")
        stopTimerIfIdle()
        setPhase(.failed(failure))
    }

    private func stopTimerIfIdle() {
        guard session == nil else { return }
        timer?.invalidate()
        timer = nil
    }

    private func setPhase(_ phase: ConnectionPhase) {
        guard self.phase != phase else { return }
        self.phase = phase
        logInfo(.app, "Phase → \(phase.title)")
        events.publish(.phase(phase))
    }
}
