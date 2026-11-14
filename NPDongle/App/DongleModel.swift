import BandLogging
import DongleProtocol
import Foundation
import Observation
import UIKit

/// Everything NP Dongle knows: the dongle link and its firmware updater, the phone's profile set
/// and its uploader, and the Live Activities. The link polls while the app is in the foreground.
@MainActor
@Observable
final class DongleModel {
    enum Tab: Hashable { case home, profiles, pair, firmware, settings }

    /// How the phone's profile set compares with the dongle's (status `ph`).
    enum SyncState: Equatable {
        case disconnected
        /// The firmware predates profiles.
        case unsupported
        case onDongle
        /// The dongle runs its built-in set and the phone's differs.
        case notSent
        case different

        var title: String {
            switch self {
            case .disconnected: "Dongle not connected"
            case .unsupported: "Dongle firmware has no profiles"
            case .onDongle: "On the dongle"
            case .notSent: "Not sent"
            case .different: "Dongle has a different set"
            }
        }

        var symbol: String {
            switch self {
            case .disconnected: "cable.connector.slash"
            case .unsupported: "exclamationmark.arrow.circlepath"
            case .onDongle: "checkmark.circle.fill"
            case .notSent: "arrow.up.circle"
            case .different: "arrow.triangle.2.circlepath.circle"
            }
        }
    }

    var tab: Tab = .home
    let link = DongleLink()
    let updater: DongleUpdater
    let store = ProfileStore()
    let uploader: ProfileUploader
    let downloader: ProfileDownloader
    let activities = LiveActivities()
    /// A file or paste waiting for the user's OK.
    var pendingImport: ProfileStore.Candidate?

    init() {
        updater = DongleUpdater(link: link)
        uploader = ProfileUploader(link: link)
        downloader = ProfileDownloader(link: link)
        updater.onChange = { [weak self] updater in self?.activities.updaterChanged(updater) }
        link.onStatus = { [weak self] status in self?.statusChanged(status) }
        link.onLogLines = { [weak self] lines in
            guard let self else { return }
            uploader.logLines(lines)
            if let candidate = downloader.logLines(lines) { pendingImport = candidate }
        }
        link.onStateChange = { [weak self] in
            guard let self else { return }
            self.activities.statusChanged(self.statusActivityState)
        }
        link.keepConnected = { [weak self] in
            guard let self else { return false }
            return self.uploader.isBusy || self.downloader.isBusy || self.activities.statusRunning
        }
        #if DEBUG
        // Screenshot/testing aid: `-NPTab profiles|pair|firmware|settings`.
        switch UserDefaults.standard.string(forKey: "NPTab") {
        case "profiles": tab = .profiles
        case "pair": tab = .pair
        case "firmware": tab = .firmware
        case "settings": tab = .settings
        default: break
        }
        #endif
        let device = UIDevice.current
        logNotice(.app, "NP Dongle \(Self.version) on \(device.systemName) \(device.systemVersion)")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var status: DongleStatus? { link.status }

    private func statusChanged(_ status: DongleStatus) {
        uploader.statusChanged(status)
        activities.statusChanged(statusActivityState)
    }

    // MARK: profiles

    var syncState: SyncState {
        guard link.isReady, let status else { return .disconnected }
        guard let hash = status.profileHash else { return .unsupported }
        if store.isOnDongle(hash) { return .onDongle }
        return hash == ProfileFormat.builtinHash ? .notSent : .different
    }

    /// The set the dongle runs, when the app knows it: the phone's (same hash) or the built-in one.
    var dongleSet: GestureProfileSet? {
        guard let hash = status?.profileHash else { return status == nil ? nil : .builtin }
        if store.isOnDongle(hash) { return store.set }
        return hash == ProfileFormat.builtinHash ? .builtin : nil
    }

    /// Profiles to offer for switching: the dongle's set if known, else the phone's.
    var switchableProfiles: [GestureProfile] { (dongleSet ?? store.set).profiles }

    func profile(id: String?) -> GestureProfile? {
        guard let id else { return nil }
        return dongleSet?.profile(id: id) ?? store.set.profile(id: id) ?? GestureProfileSet.builtin.profile(id: id)
    }

    func profileName(id: String?) -> String {
        guard let id, !id.isEmpty else { return "—" }
        return profile(id: id)?.name ?? id
    }

    /// Switches the active host (`profile <id>`) or one host (`profile <h> <id>`).
    func switchProfile(_ id: String, host: Int? = nil) {
        if let host { link.send(.hostProfile(host, id)) } else { link.send(.profile(id)) }
    }

    // MARK: import

    func open(_ url: URL) {
        let candidate = ProfileStore.candidate(url: url)
        // Files handed over by other apps land in Documents/Inbox: they're copies.
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        pendingImport = candidate
        tab = .profiles
    }

    func pasteProfiles() {
        guard let text = Clipboard.text, !text.isEmpty else {
            pendingImport = ProfileStore.Candidate(source: "Clipboard", set: nil, error: ProfileError("", "The clipboard has no text."))
            return
        }
        pendingImport = ProfileStore.candidate(text: text, source: "Clipboard")
    }

    // MARK: status Live Activity

    var statusActivityState: DongleStatusAttributes.ContentState {
        let host = status?.activeHost
        let profile = profile(id: host?.profile ?? status?.mode)
        let band = status?.band
        return .init(connected: link.isReady && status != nil,
                     hostName: host?.displayName ?? "No host",
                     hostSymbol: host?.type.symbol ?? "questionmark.circle",
                     profileName: profile?.name ?? status?.mode ?? "—",
                     profileSymbol: profile?.displaySymbol ?? GestureProfile.defaultSymbol,
                     battery: band?.battery,
                     charging: band?.charging == true,
                     bandState: band.map { BandState.describe($0.state) } ?? "Unknown",
                     bandLive: band?.state == "live")
    }

    func setStatusActivity(_ on: Bool) {
        activities.setStatusWanted(on, dongleName: link.peripheralName ?? DongleGATT.advertisedName, state: statusActivityState)
    }

    /// Back in the foreground: notice an activity the user swiped away, refresh the one shown.
    func becameActive() {
        activities.refresh()
        if activities.statusWanted, !activities.statusRunning { setStatusActivity(true) }
        activities.statusChanged(statusActivityState)
    }
}
