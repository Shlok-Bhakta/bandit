import BandLogging
import BandTransport
import DongleProtocol
import Foundation
import Observation
import UIKit

/// Dongle firmware over Bluetooth: the release index on the Tailscale host, downloading and checking
/// the package, streaming it (see `DongleTransfer` for the window and resend rules), and watching the
/// dongle come back on the new build. The dongle checks the signature and keeps the old firmware.
/// `onChange` reports every phase and progress step (the Live Activity follows it).
@MainActor
@Observable
final class DongleUpdater {
    enum Phase: Equatable {
        case idle
        case downloading
        /// The package passed the app's checks; waiting for the user to confirm.
        case confirming
        /// BEGIN sent; waiting for READY.
        case starting
        case sending
        /// Everything acknowledged; the dongle checks the image.
        case verifying
        /// DONE: the dongle switched its boot slot and restarts.
        case rebooting
        /// The new build runs but isn't confirmed yet (a crash now rolls back).
        case probation
        case installed
        case rolledBack
        case cancelled
        case failed(String)
    }

    static let readyTimeout: TimeInterval = 15
    static let verifyTimeout: TimeInterval = 60
    static let rebootTimeout: TimeInterval = 150

    let link: DongleLink
    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onChange?(self) } }
    }
    private(set) var checking = false
    private(set) var checkError: String?
    private(set) var release: DongleRelease?
    private(set) var package: DonglePackage?
    /// Committed bytes, package size, and the measured rate (bytes/s).
    private(set) var sent = 0 {
        didSet { if sent != oldValue { onChange?(self) } }
    }
    private(set) var total = 0
    private(set) var rate = 0.0
    private(set) var resends = 0
    private(set) var events: [String] = []
    private(set) var flasherLoading = false
    var flasherFile: SharedFile?
    var flasherError: String?

    @ObservationIgnored var onChange: ((DongleUpdater) -> Void)?
    @ObservationIgnored private var transfer: DongleTransfer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var deadline: TimeInterval = 0
    @ObservationIgnored private var startedAt: TimeInterval = 0
    @ObservationIgnored private var previousID: String?
    @ObservationIgnored private var expectedID: String?
    @ObservationIgnored private var uptimeAtDone: Int?
    @ObservationIgnored private var sawReboot = false

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    init(link: DongleLink) {
        self.link = link
        link.updater = self
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// BEGIN through DONE: the link is busy with the package (no status polling).
    var isStreaming: Bool { [.starting, .sending, .verifying].contains(phase) }
    var isBusy: Bool { isStreaming || phase == .downloading || phase == .rebooting }
    /// Keep reconnecting even if the screen stops polling.
    var needsLink: Bool { isStreaming || phase == .rebooting || phase == .probation }

    var updateAvailable: Bool {
        guard let release, let status = link.status else { return false }
        return !release.isRunning(on: status)
    }

    var eta: TimeInterval? { rate > 0 ? Double(total - sent) / rate : nil }
    var fraction: Double { total > 0 ? min(1, Double(sent) / Double(total)) : 0 }

    // MARK: release index

    /// The Mac that serves releases over Tailscale (Info.plist `DongleReleasesHost`, from the
    /// `DONGLE_RELEASES_HOST` build setting).
    static var releasesHost: String { Bundle.main.object(forInfoDictionaryKey: "DongleReleasesHost") as? String ?? "" }

    func check() async {
        checking = true
        checkError = nil
        defer { checking = false }
        do {
            guard let index = DongleRelease.indexURL(host: Self.releasesHost) else {
                checkError = "No release host set: put DONGLE_RELEASES_HOST (your Mac's Tailscale name) in ~/.config/neural-playground/build.env or Config/Local.xcconfig and rebuild the app."
                return
            }
            let data = try await Self.fetch(index)
            let release = try DongleRelease.decode(data, index: index)
            self.release = release
            logNotice(.dongle, "Release index: \(release.version) id \(release.id) (\(release.size.map(String.init) ?? "?") B); dongle runs \(link.status?.buildID ?? "?")")
        } catch let error as DecodingError {
            checkError = "The release index isn't valid (\(error.localizedDescription))."
        } catch {
            checkError = Self.explain(error)
        }
    }

    func download() async {
        guard let release, let url = release.packageURL, !isBusy else { return }
        phase = .downloading
        package = nil
        do {
            let data = try await Self.fetch(url)
            let package = try DonglePackage(data, expectedSHA256: release.sha256, expectedSize: release.size)
            self.package = package
            logNotice(.dongle, "Package \(release.file): \(data.count) B, SHA-256 matches, header version \(package.header.version)")
            phase = .confirming
        } catch {
            logError(.dongle, "Package download/check failed: \(BandLog.describe(error))")
            phase = .failed(Self.explain(error))
        }
    }

    func shareFlasher() async {
        guard let release, let url = release.flasherURL, let name = release.flasher else { return }
        flasherLoading = true
        flasherError = nil
        defer { flasherLoading = false }
        do {
            let data = try await Self.fetch(url)
            flasherFile = SharedFile(url: try TemporaryShareFile.make(name: (name as NSString).lastPathComponent, data: data))
        } catch {
            flasherError = Self.explain(error)
        }
    }

    private static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw TransportError("The release host answered \(http.statusCode) for \(url.lastPathComponent).")
        }
        return data
    }

    static func explain(_ error: Error) -> String {
        let native = error as NSError
        if native.domain == NSURLErrorDomain,
           [NSURLErrorCannotFindHost, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed].contains(native.code) {
            return "Can't reach the release host. It's on the Tailscale network: make sure Tailscale is on and connected on this iPhone, then try again."
        }
        return error.localizedDescription
    }

    // MARK: install

    func cancelConfirmation() {
        if phase == .confirming { phase = .idle }
    }

    /// After the user confirmed: BEGIN, then wait for READY.
    func install() {
        guard phase == .confirming, let package, let status = link.status, link.isReady else {
            if phase == .confirming { phase = .failed("Not connected to the dongle.") }
            return
        }
        previousID = status.buildID
        expectedID = release?.id
        uptimeAtDone = nil
        sawReboot = false
        total = package.data.count
        sent = 0
        rate = 0
        resends = 0
        events.removeAll()
        transfer = nil
        note("BEGIN \(total) B (\(package.header.version)); max write \(link.maximumUpdateWrite) B")
        guard link.writeUpdate(UpdateFrame.begin(total: total), withResponse: true) else {
            phase = .failed("Not connected to the dongle.")
            return
        }
        phase = .starting
        deadline = now + Self.readyTimeout
        UIApplication.shared.isIdleTimerDisabled = true
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        guard isStreaming else { return }
        link.writeUpdate(UpdateFrame.abort, withResponse: true)
        note("ABORT (cancelled)")
        finish(.cancelled)
    }

    func dismiss() {
        guard !isBusy else { return }
        phase = .idle
        package = nil
    }

    private func finish(_ phase: Phase) {
        self.phase = phase
        transfer = nil
        if !needsLink {
            timer?.invalidate()
            timer = nil
        }
        UIApplication.shared.isIdleTimerDisabled = false
        if case .failed(let reason) = phase { note("FAILED: \(reason)") }
    }

    private func fail(_ reason: String, abort: Bool = true) {
        if abort { link.writeUpdate(UpdateFrame.abort, withResponse: true) }
        logError(.dongle, "Update failed: \(reason)")
        finish(.failed(reason))
    }

    private func note(_ line: String) {
        events.append(line)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        logInfo(.dongle, "Update: \(line)")
    }

    // MARK: from DongleLink

    func received(_ message: DongleUpdateMessage) {
        switch message {
        case .ready:
            guard phase == .starting else { return }
            let chunk = max(link.maximumUpdateWrite - UpdateFrame.dataOverhead, 16)
            transfer = DongleTransfer(total: total, chunkSize: chunk, now: now)
            startedAt = now
            phase = .sending
            note("READY; sending \(chunk) B chunks")
            pump()
        case .ack(let next):
            guard var transfer, phase == .sending || phase == .verifying else { return }
            transfer.ack(next, now: now)
            self.transfer = transfer
            sent = transfer.acked
            if transfer.allAcknowledged, phase == .sending {
                phase = .verifying
                deadline = now + Self.verifyTimeout
                note("All \(total) B acknowledged; the dongle is verifying")
            }
            pump()
        case .resend(let next):
            guard var transfer, phase == .sending || phase == .verifying else { return }
            transfer.resend(from: next, now: now)
            self.transfer = transfer
            sent = transfer.acked
            resends = transfer.resends
            phase = .sending
            note("RESEND from \(next)")
            pump()
        case .done:
            guard isStreaming else { return }
            note("DONE: verified, boot slot switched; rebooting")
            uptimeAtDone = link.status?.uptime
            transfer = nil
            phase = .rebooting
            deadline = now + Self.rebootTimeout
            UIApplication.shared.isIdleTimerDisabled = false
        case .fail(let reason):
            guard isStreaming else { return }
            fail("The dongle refused the update: \(reason.isEmpty ? "no reason given" : reason). It keeps its current firmware.", abort: false)
        }
    }

    func updateWriteFinished(_ error: Error?) {
        guard let error, phase == .starting else { return }
        fail("The dongle didn't accept BEGIN: \(error.localizedDescription)", abort: false)
    }

    func readyToSend() { pump() }

    func linkLost() {
        if isStreaming {
            fail("The Bluetooth connection dropped during the update. The dongle keeps its current firmware; try again with the phone closer to it.", abort: false)
        } else if phase == .rebooting, !sawReboot {
            sawReboot = true
            note("Disconnected: the dongle is restarting")
        }
    }

    func statusChanged(_ status: DongleStatus) {
        switch phase {
        case .rebooting:
            // Until the dongle has actually restarted, the old build may still answer.
            let restarted = sawReboot || uptimeAtDone.map { status.uptime < $0 } == true
            guard restarted else { return }
            conclude(status)
        case .probation:
            conclude(status)
        default:
            break
        }
    }

    private func conclude(_ status: DongleStatus) {
        let id = status.buildID.lowercased()
        if id == expectedID?.lowercased() {
            if status.onProbation {
                if phase != .probation { note("Back on \(status.firmware) id \(status.buildID), on probation") }
                phase = .probation
            } else {
                note("Confirmed: \(status.firmware) id \(status.buildID)")
                finish(.installed)
            }
        } else if id == previousID?.lowercased() {
            note("Back on the previous build \(status.buildID): rolled back")
            finish(.rolledBack)
        } else {
            finish(.failed("The dongle runs \(status.firmware) id \(status.buildID), neither the previous build nor the new one."))
        }
    }

    // MARK: sending

    private func pump() {
        guard phase == .sending, var transfer, let package else { return }
        while link.canSendUpdateData, let range = transfer.nextChunk() {
            link.writeUpdate(UpdateFrame.data(offset: range.lowerBound, package.data.subdata(in: range)), withResponse: false)
        }
        self.transfer = transfer
    }

    private func tick() {
        let now = now
        switch phase {
        case .starting:
            if now > deadline { fail("The dongle didn't get ready within \(Int(Self.readyTimeout)) s.") }
        case .sending:
            guard var transfer else { return }
            if transfer.checkTimeout(now: now) {
                self.transfer = transfer
                resends = transfer.resends
                if transfer.gaveUp { return fail("The dongle stopped acknowledging data.") }
                note("No ACK for \(Int(DongleTransfer.ackTimeout)) s; resending from \(transfer.acked)")
            }
            // Also covers a missed peripheralIsReady(toSendWriteWithoutResponse:).
            pump()
            let elapsed = now - startedAt
            if elapsed > 1 { rate = Double(sent) / elapsed }
        case .verifying:
            if now > deadline { fail("The dongle didn't confirm the update within \(Int(Self.verifyTimeout)) s.") }
        case .rebooting:
            if now > deadline {
                finish(.failed("The dongle hasn't come back within \(Int(Self.rebootTimeout / 60)) minutes. Unplug it and plug it back in; if it still doesn't show up, flash it with the Chrome flasher."))
            }
        case .probation:
            break
        default:
            timer?.invalidate()
            timer = nil
        }
    }
}
