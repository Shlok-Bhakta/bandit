import BandLogging
import DongleProtocol
import SwiftUI

/// The dongle's firmware: what it runs, the latest release on the Tailscale host, and installing it
/// over Bluetooth with a Live Activity following along.
struct FirmwareView: View {
    @Environment(DongleModel.self) private var model
    @State private var confirmInstall = false

    private var link: DongleLink { model.link }

    var body: some View {
        @Bindable var updater = model.updater
        List {
            if !link.isReady { ConnectionSection() }
            if let status = link.status {
                Section("On the dongle") {
                    InfoRow(label: "Firmware", value: "\(status.firmware) · \(status.buildID)", monospaced: true)
                    InfoRow(label: "Slot", value: status.slot, monospaced: true)
                    if status.onProbation {
                        Label("On probation: the new firmware is confirmed after about a minute of healthy running. A crash before then rolls back.", systemImage: "hourglass")
                            .font(.footnote).foregroundStyle(Theme.warn)
                    }
                    InfoRow(label: "Uptime", value: Duration.seconds(status.uptime).formatted(.time(pattern: .hourMinuteSecond)))
                    if let heap = status.heap { InfoRow(label: "Free heap", value: ByteCountFormatter.string(fromByteCount: Int64(heap), countStyle: .memory)) }
                    InfoRow(label: "Profiles", value: status.profileHash.map { $0 == ProfileFormat.builtinHash ? "Built-in" : $0 } ?? "Not supported", monospaced: true)
                }
            }
            DongleUpdateSection(updater: model.updater)
            if !model.activities.enabled {
                Section {
                    Label("Live Activities are off for NP Dongle, so the Lock Screen won't show update progress. Turn them on in Settings › NP Dongle.", systemImage: "rectangle.badge.xmark")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .darkList()
        .navigationTitle("Firmware")
        .task { if updater.release == nil, !updater.checking { await updater.check() } }
        .onAppear { if updater.phase == .confirming { confirmInstall = true } }
        .onChange(of: updater.phase) { _, phase in if phase == .confirming { confirmInstall = true } }
        .alert("Install dongle firmware \(updater.release?.version ?? "")?", isPresented: $confirmInstall) {
            Button("Install") { updater.install() }
            Button("Cancel", role: .cancel) { updater.cancelConfirmation() }
        } message: {
            Text("The app sends the package to the dongle over Bluetooth. The dongle verifies its signature and refuses anything that isn't signed for it. It keeps its current firmware and rolls back automatically if the new one doesn't start, or crashes in its first minute. Keep the phone close to the dongle.")
        }
        .sheet(item: $updater.flasherFile) { file in ShareSheet(url: file.url) }
    }
}

/// Dongle firmware: the release on the Tailscale host, install over Bluetooth, and the Chrome flasher.
struct DongleUpdateSection: View {
    let updater: DongleUpdater
    private var link: DongleLink { updater.link }

    var body: some View {
        Section {
            Button {
                Task { await updater.check() }
            } label: {
                HStack {
                    Label(updater.checking ? "Checking…" : "Check for update", systemImage: "magnifyingglass")
                    if updater.checking { Spacer(); ProgressView().controlSize(.small) }
                }
            }
            .disabled(updater.checking || updater.isBusy)
            if let error = updater.checkError { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            if let release = updater.release { releaseInfo(release) }
            progress
            if updater.release?.flasher != nil {
                Button {
                    Task { await updater.shareFlasher() }
                } label: {
                    HStack {
                        Label("Share Chrome flasher", systemImage: "square.and.arrow.up")
                        if updater.flasherLoading { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(updater.flasherLoading)
                if let error = updater.flasherError { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            }
            if !updater.events.isEmpty {
                DisclosureGroup("Update log (\(updater.events.count))") {
                    ForEach(Array(updater.events.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).foregroundStyle(line.hasPrefix("FAILED") ? Theme.danger : .secondary)
                    }
                }
                .font(.footnote)
            }
        } header: {
            Text("Firmware update")
        } footer: {
            Text("Releases come from the release host on your Tailscale network. The app checks the download's SHA-256 against the release index; the dongle checks its signature and keeps its current firmware until the new one has run healthily for about a minute. The Chrome flasher is a single web page that flashes the dongle over USB from desktop Chrome: AirDrop it to a laptop if Bluetooth updates don't work.")
        }
    }

    @ViewBuilder
    private func releaseInfo(_ release: DongleRelease) -> some View {
        InfoRow(label: "Latest", value: "\(release.version) · \(release.id)", monospaced: true)
        if let size = release.size { InfoRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let notes = release.notes, !notes.isEmpty { Text(notes).font(.footnote).foregroundStyle(.secondary) }
        if let status = link.status {
            if release.isRunning(on: status) {
                Label("The dongle runs this build", systemImage: "checkmark.circle").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Label("Update available: the dongle runs \(status.firmware) · \(status.buildID)", systemImage: "arrow.down.circle.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Theme.mint)
            }
        } else {
            Text("Connect the dongle to compare.").font(.footnote).foregroundStyle(.secondary)
        }
        if updater.updateAvailable, !updater.isBusy, ![.probation, .confirming].contains(updater.phase) {
            Button {
                Task { await updater.download() }
            } label: {
                Label("Install \(release.version)…", systemImage: "arrow.down.to.line.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.warn)
            .disabled(!link.isReady || link.status?.update.map { $0.state == "receiving" || $0.state == "verifying" } == true)
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch updater.phase {
        case .idle, .confirming:
            EmptyView()
        case .downloading:
            HStack { ProgressView().controlSize(.small); Text("Downloading and checking the package…").font(.callout) }
        case .starting:
            HStack { ProgressView().controlSize(.small); Text("Waiting for the dongle to get ready…").font(.callout) }
            cancelButton
        case .sending, .verifying:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(updater.sent), total: Double(max(updater.total, 1)))
                HStack {
                    Text("\(updater.sent / 1024) / \(updater.total / 1024) KB")
                    Spacer()
                    if updater.phase == .verifying {
                        Text("Verifying…")
                    } else if updater.rate > 0 {
                        Text("\(String(format: "%.1f", updater.rate / 1024)) KB/s")
                        if let eta = updater.eta { Text("· \(Duration.seconds(Int(eta.rounded())).formatted(.time(pattern: .minuteSecond))) left") }
                    }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if updater.resends > 0 { Text("Resent \(updater.resends)×").font(.caption2).foregroundStyle(.secondary) }
                Text("Keep the phone close to the dongle. The Lock Screen and Dynamic Island show the progress; NP Dongle keeps the screen awake while it's open.").font(.caption).foregroundStyle(Theme.warn)
            }
            cancelButton
        case .rebooting:
            HStack { ProgressView().controlSize(.small); Text("Rebooting… the dongle restarts into the new firmware and reconnects by itself.").font(.callout) }
        case .probation:
            Label("The new firmware runs (\(link.status?.buildID ?? "?")). It's confirmed after about a minute of healthy running; a crash before then rolls back.", systemImage: "hourglass")
                .font(.callout).foregroundStyle(Theme.warn)
        case .installed:
            Label("Installed: the dongle runs \(link.status.map { "\($0.firmware) · \($0.buildID)" } ?? "the new firmware").", systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(Theme.mint)
            Button("Dismiss") { updater.dismiss() }.font(.footnote)
        case .rolledBack:
            Label("The dongle rolled back to its previous firmware (\(link.status?.buildID ?? "?")): the new build didn't start properly. Fetch the log backlog (Settings › Logs) to see why.", systemImage: "arrow.uturn.backward.circle.fill")
                .font(.callout).foregroundStyle(Theme.warn)
            Button("Dismiss") { updater.dismiss() }.font(.footnote)
        case .cancelled:
            Text("Cancelled. The dongle keeps its current firmware.").font(.callout).foregroundStyle(.secondary)
            Button("Dismiss") { updater.dismiss() }.font(.footnote)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.danger)
            Button("Dismiss") { updater.dismiss() }.font(.footnote)
        }
    }

    private var cancelButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(role: .destructive) { updater.cancel() } label: { Label("Cancel update", systemImage: "xmark.circle") }
                .buttonStyle(.bordered)
            Text("Cancelling is safe: the dongle keeps its current firmware.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
