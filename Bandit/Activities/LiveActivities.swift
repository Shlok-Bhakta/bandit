import ActivityKit
import BandLogging
import Foundation
import Observation

/// Starts, updates and ends Bandit's Live Activities locally (no push): the firmware update,
/// which follows `DongleUpdater`, and the optional dongle status, which follows the status reads.
/// Updates are sent only when what they show changes.
@MainActor
@Observable
final class LiveActivities {
    static let statusPreferenceKey = "BanditStatusActivity"

    /// The user wants the status on the Lock Screen (a preference, not a secret).
    private(set) var statusWanted = UserDefaults.standard.bool(forKey: LiveActivities.statusPreferenceKey)
    private(set) var lastError: String?

    @ObservationIgnored private var update: Activity<DongleUpdateAttributes>?
    @ObservationIgnored private var updateState: DongleUpdateAttributes.ContentState?
    @ObservationIgnored private var updateSentAt = Date.distantPast
    @ObservationIgnored private var status: Activity<DongleStatusAttributes>?
    @ObservationIgnored private var statusState: DongleStatusAttributes.ContentState?
    /// When the status activity was last updated.
    @ObservationIgnored private var statusSent = Date.distantPast

    init() {
        // An update activity left from a previous run can't be finished any more.
        Task.detached { await Self.endAll(DongleUpdateAttributes.self) }
        if statusWanted {
            status = Activity<DongleStatusAttributes>.activities.first
        } else {
            Task.detached { await Self.endAll(DongleStatusAttributes.self) }
        }
    }

    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var statusRunning: Bool { status != nil }

    // MARK: firmware update

    /// Called on every phase and progress change of the updater.
    func updaterChanged(_ updater: DongleUpdater) {
        let version = updater.release?.version ?? "update"
        let state: DongleUpdateAttributes.ContentState?
        switch updater.phase {
        case .idle:
            state = nil
        case .downloading:
            state = .init(phase: .downloading, progress: 0, detail: "Downloading and checking the package")
        case .confirming:
            state = .init(phase: .downloading, progress: 0, detail: "Downloaded. Confirm the install in Bandit.")
        case .starting:
            state = .init(phase: .sending, progress: 0, detail: "Waiting for the dongle to get ready")
        case .sending:
            let left = updater.eta.map { " · \(Duration.seconds(Int($0.rounded())).formatted(.time(pattern: .minuteSecond))) left" } ?? ""
            state = .init(phase: .sending, progress: updater.fraction, detail: "\(updater.sent / 1024) of \(updater.total / 1024) KB\(left)")
        case .verifying:
            state = .init(phase: .verifying, progress: 1, detail: "The dongle checks the signature and the image")
        case .rebooting:
            state = .init(phase: .restarting, progress: 1, detail: "Restarting into the new firmware")
        case .probation:
            state = .init(phase: .restarting, progress: 1, detail: "Running; confirmed after about a minute")
        case .installed:
            state = .init(phase: .done, progress: 1, detail: "The dongle runs \(version)")
        case .rolledBack:
            state = .init(phase: .failed, progress: 1, detail: "Rolled back to the previous firmware")
        case .cancelled:
            state = .init(phase: .failed, progress: 0, detail: "Cancelled. The dongle keeps its firmware.")
        case .failed(let reason):
            state = .init(phase: .failed, progress: updater.fraction, detail: reason)
        }
        guard let state else { return endUpdate(nil, after: nil) }
        if update == nil {
            guard !state.phase.isFinal else { return }
            startUpdate(version: version, state: state)
        } else if state.phase.isFinal {
            endUpdate(state, after: state.phase == .done ? 5 * 60 : 10 * 60)
        } else {
            sendUpdate(state)
        }
    }

    private func startUpdate(version: String, state: DongleUpdateAttributes.ContentState) {
        guard enabled else { return }
        do {
            update = try Activity.request(attributes: DongleUpdateAttributes(version: version),
                                          content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(120)), pushType: nil)
            updateState = state
            updateSentAt = Date()
            logInfo(.dongle, "Live Activity: firmware update started")
        } catch {
            lastError = error.localizedDescription
            logWarning(.dongle, "Live Activity: couldn't start the update activity: \(BandLog.describe(error))")
        }
    }

    private func sendUpdate(_ state: DongleUpdateAttributes.ContentState) {
        guard let update, state != updateState else { return }
        // Progress moves many times a second: once a second (or a new phase) is plenty.
        let phaseChanged = state.phase != updateState?.phase
        guard phaseChanged || Date().timeIntervalSince(updateSentAt) >= 1 || state.percent == 100 else { return }
        updateState = state
        updateSentAt = Date()
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
        let id = update.id
        Task.detached { await Self.send(DongleUpdateAttributes.self, id: id, content: content) }
    }

    private func endUpdate(_ state: DongleUpdateAttributes.ContentState?, after seconds: TimeInterval?) {
        guard let update else { return }
        self.update = nil
        updateState = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = seconds.map { .after(Date().addingTimeInterval($0)) } ?? .immediate
        let id = update.id
        Task.detached { await Self.end(DongleUpdateAttributes.self, id: id, content: content, policy: policy) }
        logInfo(.dongle, "Live Activity: firmware update ended (\(state?.phase.rawValue ?? "dismissed"))")
    }

    // MARK: dongle status

    func setStatusWanted(_ on: Bool, dongleName: String, state: DongleStatusAttributes.ContentState) {
        statusWanted = on
        UserDefaults.standard.set(on, forKey: Self.statusPreferenceKey)
        if on {
            startStatus(dongleName: dongleName, state: state)
        } else if let status {
            self.status = nil
            statusState = nil
            let id = status.id
            Task.detached { await Self.end(DongleStatusAttributes.self, id: id, content: nil, policy: .immediate) }
        }
    }

    private func startStatus(dongleName: String, state: DongleStatusAttributes.ContentState) {
        guard status == nil else { return statusChanged(state) }
        guard enabled else {
            lastError = "Live Activities are off for Bandit (Settings › Bandit)."
            return
        }
        do {
            status = try Activity.request(attributes: DongleStatusAttributes(dongleName: dongleName),
                                          content: ActivityContent(state: state, staleDate: Self.statusStaleDate), pushType: nil)
            statusState = state
            statusSent = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            logWarning(.dongle, "Live Activity: couldn't start the status activity: \(BandLog.describe(error))")
        }
    }

    /// Without fresh status (the app suspended, the dongle away), the Lock Screen says so.
    private static var statusStaleDate: Date { Date().addingTimeInterval(5 * 60) }

    func statusChanged(_ state: DongleStatusAttributes.ContentState) {
        // The same status still counts as fresh news: renew the stale date now and then (the
        // dongle nudges at least once a minute), not on every read.
        guard let status, state != statusState || Date().timeIntervalSince(statusSent) > 60 else { return }
        statusState = state
        statusSent = Date()
        let content = ActivityContent(state: state, staleDate: Self.statusStaleDate)
        let id = status.id
        Task.detached { await Self.send(DongleStatusAttributes.self, id: id, content: content) }
    }

    // `Activity` isn't Sendable: these find it again by id off the main actor rather than send it.

    nonisolated private static func send<A: ActivityAttributes>(_ type: A.Type, id: String, content: ActivityContent<A.ContentState>) async {
        for activity in Activity<A>.activities where activity.id == id { await activity.update(content) }
    }

    nonisolated private static func end<A: ActivityAttributes>(_ type: A.Type, id: String, content: ActivityContent<A.ContentState>?,
                                                             policy: ActivityUIDismissalPolicy) async {
        for activity in Activity<A>.activities where activity.id == id { await activity.end(content, dismissalPolicy: policy) }
    }

    nonisolated private static func endAll<A: ActivityAttributes>(_ type: A.Type) async {
        for activity in Activity<A>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// The system (or the user) may end an activity: notice when it's gone.
    func refresh() {
        if let status, status.activityState == .ended || status.activityState == .dismissed {
            self.status = nil
            statusState = nil
        }
    }
}
