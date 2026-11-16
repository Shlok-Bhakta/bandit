import BandLogging
import DongleProtocol
import Foundation
import Observation
import SwiftUI
import UIKit

/// Everything NP Dongle knows: the dongle link and its firmware updater, the phone's profile set
/// and its uploader, and the Live Activities. The link polls while the app is in the foreground.
@MainActor
@Observable
final class DongleModel {
    enum Tab: Hashable { case home, profiles, settings }

    /// Screens over the tabs.
    enum Sheet: String, Identifiable {
        case pairing, firmware
        var id: String { rawValue }
    }

    /// How the phone's profile set compares with the dongle's (status `ph`).
    enum SyncState: Equatable {
        case disconnected
        /// The firmware predates profiles.
        case unsupported
        case onDongle
        /// Edits on this phone the dongle doesn't have yet.
        case phoneAhead
        /// The dongle's set was changed somewhere else; this phone still has the one it had.
        case dongleAhead
        /// Both changed, or the app can't tell what the dongle runs.
        case diverged

        var title: String {
            switch self {
            case .disconnected: "Dongle not connected"
            case .unsupported: "Dongle firmware has no profiles"
            case .onDongle: "On the dongle"
            case .phoneAhead: "Not sent yet"
            case .dongleAhead: "The dongle has a newer set"
            case .diverged: "Phone and dongle differ"
            }
        }

        var symbol: String {
            switch self {
            case .disconnected: "cable.connector.slash"
            case .unsupported: "exclamationmark.arrow.circlepath"
            case .onDongle: "checkmark.circle.fill"
            case .phoneAhead: "arrow.up.circle.fill"
            case .dongleAhead: "arrow.down.circle.fill"
            case .diverged: "arrow.triangle.merge"
            }
        }
    }

    /// The dongle's set next to this phone's, to merge (from Get, or a file).
    struct MergeRequest: Identifiable {
        let id = UUID()
        var merge: ProfileMerge
        /// "The dongle", or a file name.
        let source: String
        /// Set when it's the dongle's own set: the phone then counts as synced with it.
        let dongleHash: String?
    }

    /// A short note over the screen ("Sent", "Switched to Copilot").
    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let symbol: String
        var tint: Color = Theme.mint
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
    var pendingMerge: MergeRequest?
    var sheet: Sheet?
    private(set) var toast: Toast?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var checkedForUpdate = false

    init() {
        updater = DongleUpdater(link: link)
        uploader = ProfileUploader(link: link)
        downloader = ProfileDownloader(link: link)
        updater.onChange = { [weak self] updater in self?.activities.updaterChanged(updater) }
        link.onStatus = { [weak self] status in self?.statusChanged(status) }
        link.onLogLines = { [weak self] lines in
            guard let self else { return }
            uploader.logLines(lines)
            if let candidate = downloader.logLines(lines) { received(candidate) }
        }
        link.onStateChange = { [weak self] in
            guard let self else { return }
            self.activities.statusChanged(self.statusActivityState)
            if self.link.isReady, !self.checkedForUpdate, !DongleUpdater.releasesHost.isEmpty {
                self.checkedForUpdate = true
                Task { await self.updater.check() }
            }
        }
        uploader.onSent = { [weak self] set, hash in
            guard let self else { return }
            store.markSynced(set, hash: hash)
            show(Toast(text: "Sent to the dongle", symbol: "checkmark.seal.fill"))
        }
        link.keepConnected = { [weak self] in
            guard let self else { return false }
            return self.uploader.isBusy || self.downloader.isBusy || self.activities.statusRunning
        }
        #if DEBUG
        // Screenshot/testing aid: `-NPTab profiles|pair|firmware|settings`.
        switch UserDefaults.standard.string(forKey: "NPTab") {
        case "profiles": tab = .profiles
        case "pair": sheet = .pairing
        case "firmware": sheet = .firmware
        case "settings": tab = .settings
        default: break
        }
        if UserDefaults.standard.bool(forKey: "NPDemo") {
            let demo = #"{"fw":"0.17.0","id":"a885660a","slot":"ota_1","up":5400,"heap":81234,"band":{"s":"live","bat":82,"chg":false,"hand":"right"},"mode":"media","you":1,"ph":"builtin","hosts":[{"h":1,"k":"phone","n":"Shlok's iPhone","act":false,"p":"media"},{"h":2,"k":"computer","os":"mac","n":"MacBook Air","act":true,"p":"copilot"}]}"#
            if UserDefaults.standard.bool(forKey: "NPDemoEdit"), !store.set.profiles.isEmpty {
                store.set.profiles[0].name = "Home"
                store.set.menu["h"] = "profile:home"
            }
            if let status = try? DongleStatus.decode(Data(demo.utf8)) {
                DispatchQueue.main.async { self.link.simulate(status) }
            }
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
        if let hash = status.profileHash { store.noteDongle(hash: hash) }
        uploader.statusChanged(status)
        activities.statusChanged(statusActivityState)
    }

    // MARK: profiles

    var syncState: SyncState {
        guard link.isReady, let status else { return .disconnected }
        guard let hash = status.profileHash else { return .unsupported }
        if store.isOnDongle(hash) { return .onDongle }
        if store.dongleSet(hash: hash) != nil { return .phoneAhead }
        return store.synced != nil && store.unchangedSinceSync ? .dongleAhead : .diverged
    }

    /// The set the dongle runs, when the app knows it: the phone's, the built-in one (also older
    /// firmware's modes), or the one last synced.
    var dongleSet: GestureProfileSet? {
        guard let status else { return nil }
        guard let hash = status.profileHash else { return .builtin }
        return store.dongleSet(hash: hash)
    }

    /// What the phone has that the dongle doesn't (empty when it can't tell).
    var unsentChanges: [ProfileSetPart] {
        guard syncState == .phoneAhead, let dongle = dongleSet else { return [] }
        return store.set.differences(from: dongle)
    }

    /// Sends the phone's set, if the dongle would take it.
    func sendProfiles() {
        uploader.send(store.set)
    }

    /// Back to what the dongle runs.
    func discardChanges() {
        guard let dongle = dongleSet else { return }
        store.discardChanges(to: dongle)
        show(Toast(text: "Changes discarded", symbol: "arrow.uturn.backward.circle.fill", tint: Theme.warn))
    }

    func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Profiles to offer for switching: the dongle's set if known, else the phone's.
    var switchableProfiles: [GestureProfile] { (dongleSet ?? store.set).profiles }

    func profile(id: String?) -> GestureProfile? {
        guard let id else { return nil }
        return dongleSet?.profile(id: id) ?? store.set.profile(id: id) ?? GestureProfileSet.builtin.profile(id: id)
    }

    /// The dongle's set arrived (Get): straight in when nothing differs, else to merge.
    private func received(_ candidate: ProfileStore.Candidate) {
        guard let set = candidate.set, let hash = candidate.dongleHash else { pendingImport = candidate; return }
        if set.sameContent(as: store.set) {
            store.markSynced(set, hash: hash)
            show(Toast(text: "This iPhone already has the dongle's set", symbol: "checkmark.circle.fill"))
            return
        }
        pendingMerge = MergeRequest(merge: ProfileMerge(base: store.synced?.set, phone: store.set, other: set), source: "The dongle", dongleHash: hash)
    }

    func applyMerge(_ request: MergeRequest) {
        store.applyMerge(request.merge.result, dongle: request.dongleHash.map { (request.merge.other, $0) })
        pendingMerge = nil
        show(Toast(text: request.dongleHash == nil ? "Merged into this iPhone's set" : "Merged with the dongle's set", symbol: "arrow.triangle.merge"))
    }

    func profileName(id: String?) -> String {
        guard let id, !id.isEmpty else { return "—" }
        return profile(id: id)?.name ?? id
    }

    /// Switches the active host (`profile <id>`) or one host (`profile <h> <id>`).
    func switchProfile(_ id: String, host: Int? = nil) {
        if let host { link.send(.hostProfile(host, id)) } else { link.send(.profile(id)) }
        if let profile = profile(id: id) { show(Toast(text: profile.name, symbol: profile.displaySymbol, tint: profile.tint)) }
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
