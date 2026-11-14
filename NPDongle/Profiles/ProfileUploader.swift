import BandLogging
import DongleProtocol
import Foundation
import Observation

/// Sends a profile set to the dongle (`profiles begin` / `data` / `commit`, one write at a time)
/// and waits until the status hash `ph` is the set's own; or resets the dongle to its built-in
/// set. A refusal shows the dongle's reason (`pe`, or the `PROFILES: refused:` log line).
@MainActor
@Observable
final class ProfileUploader {
    enum Phase: Equatable {
        case idle
        /// Commands written, of all of them.
        case sending(done: Int, of: Int)
        /// Committed; waiting for the status to show the new hash.
        case confirming
        case done(String)
        case failed(String)
    }

    static let confirmTimeout: TimeInterval = 10

    let link: DongleLink
    private(set) var phase: Phase = .idle

    @ObservationIgnored private var commands: [DongleCommand] = []
    @ObservationIgnored private var next = 0
    /// The hash that means success (`builtin` for a reset).
    @ObservationIgnored private var expectedHash = ""
    @ObservationIgnored private var errorBefore: String?
    @ObservationIgnored private var deadline: Date = .distantPast
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var successMessage = ""

    init(link: DongleLink) {
        self.link = link
    }

    var isBusy: Bool {
        switch phase {
        case .sending, .confirming: true
        default: false
        }
    }

    var progress: Double {
        switch phase {
        case .sending(let done, let of): of > 0 ? Double(done) / Double(of) : 0
        case .confirming, .done: 1
        default: 0
        }
    }

    // MARK: starting

    /// Checks the set here first (the dongle would refuse it anyway), then streams it.
    func send(_ set: GestureProfileSet) {
        guard !isBusy else { return }
        if let error = set.validate() {
            phase = .failed("Fix this first: \(error)")
            return
        }
        guard let status = ready() else { return }
        do {
            let upload = try ProfileUpload(set.minifiedData)
            start(upload.commands, expecting: upload.sha8, status: status,
                  success: "“\(set.name ?? "Your set")” is on the dongle (\(upload.data.count) bytes, \(upload.sha8)).")
            logNotice(.dongle, "Profiles: sending \(upload.data.count) B as \(upload.commands.count) commands, sha \(upload.sha8)")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// `profiles reset`: the dongle goes back to its built-in set.
    func resetDongle() {
        guard !isBusy, let status = ready() else { return }
        start([.profilesReset], expecting: ProfileFormat.builtinHash, status: status, success: "The dongle uses its built-in profiles again.")
        logNotice(.dongle, "Profiles: resetting the dongle to the built-in set")
    }

    func dismiss() {
        guard !isBusy else { return }
        phase = .idle
    }

    private func ready() -> DongleStatus? {
        guard link.isReady, let status = link.status else {
            phase = .failed("Not connected to the dongle.")
            return nil
        }
        guard status.supportsProfiles else {
            phase = .failed("This dongle's firmware doesn't keep profiles yet. Update it on the Firmware tab, then try again.")
            return nil
        }
        return status
    }

    private func start(_ commands: [DongleCommand], expecting hash: String, status: DongleStatus, success: String) {
        self.commands = commands
        next = 0
        expectedHash = hash
        errorBefore = status.profileError
        successMessage = success
        phase = .sending(done: 0, of: commands.count)
        sendNext()
    }

    // MARK: sending

    private func sendNext() {
        guard case .sending = phase else { return }
        guard next < commands.count else { return awaitConfirmation() }
        link.send(commands[next]) { [weak self] error in
            guard let self, case .sending = self.phase else { return }
            if let error {
                return self.fail("The dongle didn't take the set: \(error.localizedDescription)")
            }
            self.next += 1
            self.phase = .sending(done: self.next, of: self.commands.count)
            self.sendNext()
        }
    }

    private func awaitConfirmation() {
        phase = .confirming
        deadline = Date().addingTimeInterval(Self.confirmTimeout)
        link.readStatus()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard phase == .confirming else { return stopTimer() }
        if let status = link.status { statusChanged(status) }
        guard phase == .confirming else { return }
        if Date() > deadline {
            let reason = link.status?.profileError.map { " The dongle says: \($0)" } ?? ""
            fail("The dongle didn't confirm the new set within \(Int(Self.confirmTimeout)) s.\(reason)")
        } else {
            link.readStatus()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func fail(_ reason: String) {
        stopTimer()
        logError(.dongle, "Profiles: \(reason)")
        phase = .failed(reason)
    }

    // MARK: from the link

    func statusChanged(_ status: DongleStatus) {
        guard phase == .confirming else { return }
        if status.profileHash == expectedHash {
            stopTimer()
            logNotice(.dongle, "Profiles: the dongle reports \(expectedHash)")
            phase = .done(successMessage)
        } else if let error = status.profileError, error != errorBefore {
            fail("The dongle refused the set: \(error)")
        }
    }

    func logLines(_ lines: [String]) {
        guard isBusy, let line = lines.first(where: { $0.contains("PROFILES: refused:") }),
              let reason = line.components(separatedBy: "PROFILES: refused:").last?.trimmingCharacters(in: .whitespaces) else { return }
        fail("The dongle refused the set: \(reason)")
    }
}

/// Reads the dongle's set back (`profiles show`, 0.12.1 on), for the user to take onto the phone:
/// when it was changed from elsewhere (by an agent over USB, say).
@MainActor
@Observable
final class ProfileDownloader {
    private(set) var isBusy = false
    private(set) var error: String?

    let link: DongleLink
    @ObservationIgnored private var dump = ProfileDump()
    @ObservationIgnored private var timeout: Task<Void, Never>?

    init(link: DongleLink) {
        self.link = link
    }

    func start() {
        guard !isBusy else { return }
        error = nil
        dump = ProfileDump()
        isBusy = true
        logNotice(.dongle, "Profiles: reading the dongle's set")
        link.send(.profilesShow) { [weak self] error in
            guard let self, let error else { return }
            self.finish("Couldn't ask the dongle: \(error.localizedDescription)")
        }
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.finish("The dongle didn't send its set. It needs firmware 0.12.1 or later.")
        }
    }

    /// The set, ready to review, once the whole of it has arrived.
    func logLines(_ lines: [String]) -> ProfileStore.Candidate? {
        guard isBusy else { return nil }
        lines.forEach { dump.feed($0) }
        switch dump.result {
        case nil:
            return nil
        case .failure(let failure):
            finish(failure.message)
            return nil
        case .success(let file):
            finish(nil)
            var candidate = ProfileStore.candidate(file.data, source: file.builtin ? "The dongle (its built-in set)" : "The dongle")
            candidate.dongleHash = file.builtin ? ProfileFormat.builtinHash : file.sha8
            return candidate
        }
    }

    private func finish(_ error: String?) {
        timeout?.cancel()
        isBusy = false
        self.error = error
        if let error { logWarning(.dongle, "Profiles: \(error)") }
    }
}
