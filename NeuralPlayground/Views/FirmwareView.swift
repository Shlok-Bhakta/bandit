import BandCredentials
import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// Band firmware without glasses: what the band runs, what Meta offers it, the downloaded packages
/// (inspectable and exportable), and installing one, each step on its own button.
struct FirmwareView: View {
    @Environment(BandClient.self) private var band
    @State private var checking = false
    @State private var checkResult: FirmwareCheckResult?
    @State private var checkError: String?
    @State private var downloading: String?
    @State private var downloadProgress: (done: Int64, total: Int64) = (0, 0)
    @State private var packages: [FirmwarePackage] = []
    @State private var signingIn = false

    private var serial: String? { band.deviceInfo?.serial }
    private var bandTag: String? { serial.map { FirmwareLibrary.bandTag(serial: $0) } }
    private var status: OtaStatus? { band.survey.ota }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let install = band.firmwareInstall { InstallBanner(install: install) }
                current
                check
                downloads
                Text("Packages come from Meta's own update service, the same one the Meta AI app uses, signed in with your Meta account. They're encrypted for the band, and the band checks each one before it accepts it. Based on Air Gestures for Android and band-core.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Firmware")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionPill() } }
        .onAppear {
            reload()
            if status == nil { band.refreshUpdateStatus() }
        }
        .sheet(isPresented: $signingIn) {
            MetaLoginView { session in
                band.saveMetaSession(session)
                Task { await runCheck(session) }
            }
        }
    }

    private func reload() { packages = FirmwareLibrary.packages(bandTag: bandTag) }

    // MARK: current

    private var current: some View {
        Card(title: "This band", systemImage: "cpu") {
            row("Firmware", band.deviceInfo?.firmware ?? "—")
            if let status {
                row("Update version", status.activeFirmware.map { "\($0) (\(FirmwareLibrary.name(String($0))))" } ?? "—")
                row("Update service", status.stateName)
                row("Firmware state", status.deviceName)
                if let staged = status.stagedFirmware, staged != status.activeFirmware { row("Staged (not installed)", String(staged)) }
                row("ML bundle", status.mlModel.map(String.init) ?? "—")
                row("Firmware key version", String(status.kek))
                if let reason = status.reasonName { Label("Updates unavailable: \(reason)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warn) }
            } else {
                Text(band.phase == .streaming ? "Reading the band's update status…" : "Connect the band to read its update status.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let info = band.deviceInfo {
                row("Handwriting model", info.hasHandwritingModel ? "on the band" : "not on this firmware")
            }
            HStack {
                Button("Refresh") { band.refreshUpdateStatus() }.buttonStyle(.bordered).disabled(band.phase != .streaming || band.otaRunning)
                Spacer()
                Text(band.battery.map { "Band battery \($0)%\(band.charging == true ? " · charging" : "")" } ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: check

    private var check: some View {
        Card(title: "Ask Meta", systemImage: "icloud.and.arrow.down") {
            Text("Asks Meta which firmware it would install on this band. Nothing is sent to the band, and nothing is downloaded until you tap Download.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                if let session = band.metaStore.load() { Task { await runCheck(session) } } else { signingIn = true }
            } label: {
                Label(checking ? "Asking Meta…" : band.hasMetaSession ? "Check for firmware" : "Sign in to Meta and check", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(checking || serial == nil)
            if serial == nil { Text("Connect the band once so the app knows its serial.").font(.caption).foregroundStyle(.secondary) }
            if let checkError {
                Text(checkError).font(.caption).foregroundStyle(Theme.danger)
                if checkError.contains("sign in") || checkError.contains("OAuth") || checkError.contains("token") {
                    Button("Sign in to Meta again") { signingIn = true }.font(.caption)
                }
            }
            if let result = checkResult {
                if result.offers.isEmpty { Text("Meta offered no firmware for this band.").font(.callout) }
                ForEach(result.offers) { offer in offerRow(offer) }
                if !result.notOffered.isEmpty {
                    DisclosureGroup("Other answers (\(result.notOffered.count))") {
                        ForEach(result.notOffered, id: \.self) { Text($0).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func offerRow(_ offer: FirmwareOffer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(offer.title).font(.headline)
                Spacer()
                Text(offer.targetVersion).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            FirmwareVerdict(version: UInt64(offer.targetVersion), running: status?.activeFirmware)
            HStack(spacing: 12) {
                if let size = offer.fileSize { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption) }
                if let tag = offer.releaseTag { Text(tag).font(.caption.monospaced()) }
                if offer.kekID != nil { Text("needs firmware key \(offer.kekID!)").font(.caption) }
            }
            .foregroundStyle(.secondary)
            if let notes = offer.releaseNotes { Text(notes).font(.caption).foregroundStyle(.secondary) }
            if downloading == offer.targetVersion {
                ProgressView(value: downloadProgress.total > 0 ? Double(downloadProgress.done) / Double(downloadProgress.total) : nil) {
                    Text("Downloading… \(ByteCountFormatter.string(fromByteCount: downloadProgress.done, countStyle: .file))").font(.caption)
                }
            } else {
                Button {
                    Task { await download(offer) }
                } label: {
                    Label(packages.contains { $0.version == offer.targetVersion && $0.hasBandKey } ? "Download again" : "Download and inspect",
                          systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(downloading != nil)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func runCheck(_ session: MetaSession) async {
        guard let serial else { return }
        checking = true
        checkError = nil
        defer { checking = false }
        do {
            checkResult = try await FirmwareLibrary.check(session: session, serial: serial)
        } catch {
            checkError = error.localizedDescription
        }
    }

    private func download(_ offer: FirmwareOffer) async {
        guard let serial, let session = band.metaStore.load() else { signingIn = true; return }
        downloading = offer.targetVersion
        downloadProgress = (0, offer.fileSize ?? 0)
        checkError = nil
        defer { downloading = nil; reload() }
        do {
            _ = try await FirmwareLibrary.download(offer, session: session, serial: serial) { done, total in
                Task { @MainActor in downloadProgress = (done, total) }
            }
        } catch {
            checkError = error.localizedDescription
        }
    }

    // MARK: downloads

    private var downloads: some View {
        Card(title: "On this phone", systemImage: "externaldrive") {
            if packages.isEmpty { Text("Nothing downloaded yet.").font(.callout).foregroundStyle(.secondary) }
            ForEach(packages) { package in
                NavigationLink {
                    FirmwarePackageView(package: package, onDelete: reload)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(package.title).font(.callout.weight(.semibold))
                            Text("\(package.version) · \(ByteCountFormatter.string(fromByteCount: package.zipSize, countStyle: .file))\(package.hasBandKey ? " · key for this band" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if package.checksumMatches == false { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger) }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

/// How a build compares with what's known to work, and with what the band runs.
struct FirmwareVerdict: View {
    let version: UInt64?
    let running: UInt64?

    var body: some View {
        let (text, color, symbol): (String, Color, String) = {
            guard let version else { return ("Unknown version", Theme.warn, "questionmark.circle") }
            if let running, version == running { return ("Your band already runs this", .gray, "checkmark.circle") }
            if let running, version < running { return ("Older than your band's: it will refuse it", Theme.danger, "arrow.down.circle") }
            if version == FirmwareLibrary.knownGood { return ("Known good: the build others have tested, handwriting included", Theme.mint, "checkmark.seal.fill") }
            if version > FirmwareLibrary.knownGood { return ("Newer than anything tested so far: research first", Theme.warn, "exclamationmark.triangle.fill") }
            return ("Older than the tested build", Theme.warn, "info.circle")
        }()
        Label(text, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
    }
}

struct InstallBanner: View {
    @Environment(BandClient.self) private var band
    let install: FirmwareInstall

    var body: some View {
        Card(title: "Firmware install", systemImage: "arrow.triangle.2.circlepath") {
            switch install.stage {
            case .restarting:
                Label("The band is installing \(FirmwareLibrary.name(String(install.version))) and restarting. Keep the app open; it reconnects by itself (about a minute).",
                      systemImage: "hourglass").font(.callout)
                ProgressView()
            case .checking:
                Label("The band is back; checking what it runs…", systemImage: "magnifyingglass").font(.callout)
            case .installed:
                Label("Installed: the band runs \(FirmwareLibrary.name(String(install.version))).", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.mint)
            case .failed:
                Label("Not confirmed: the band runs \(install.running.map { FirmwareLibrary.name(String($0)) } ?? "unknown firmware"), not \(FirmwareLibrary.name(String(install.version))).",
                      systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.warn)
            }
            if install.stage == .restarting || install.stage == .checking {
                Text("If it doesn't come back within a few minutes: put the band on its charger, then reconnect from the Band tab. If the app can't reconnect after an update, claim the band again (Band tab); your Meta sign-in is kept for that.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Button("Dismiss") { band.dismissFirmwareInstall() }.font(.caption)
            }
        }
    }
}

/// One downloaded package: what's inside, export, and installing it.
struct FirmwarePackageView: View {
    @Environment(BandClient.self) private var band
    @Environment(\.dismiss) private var dismiss
    let package: FirmwarePackage
    var onDelete: () -> Void
    @State private var inspection: FirmwareInspection?
    @State private var inspectError: String?
    @State private var confirmInstall = false
    @State private var confirmDelete = false
    @State private var planError: String?

    private var bandTag: String? { band.deviceInfo.map { FirmwareLibrary.bandTag(serial: $0.serial) } }
    private var status: OtaStatus? { band.survey.ota }
    private var running: Bool { band.otaRunning && band.ota?.version == package.numericVersion }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                summary
                install
                if band.ota?.version == package.numericVersion { progress }
                if let inspection { contents(inspection) }
                if let inspectError { Text(inspectError).foregroundStyle(Theme.danger).font(.callout) }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle(package.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(items: FirmwareLibrary.exportFiles(package)) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task {
            do { inspection = try FirmwareLibrary.inspect(package) } catch { inspectError = error.localizedDescription }
        }
        .onChange(of: band.otaRunning) { _, running in UIApplication.shared.isIdleTimerDisabled = running }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = band.otaRunning }
        .sheet(isPresented: $confirmInstall) {
            InstallConfirmation(package: package) { start(.update) }
        }
        .confirmationDialog("Delete \(package.title) from this phone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? FirmwareLibrary.delete(package)
                onDelete()
                dismiss()
            }
        } message: {
            Text("The band isn't affected. You can download it again while Meta offers it.")
        }
    }

    private var summary: some View {
        Card(title: "Package", systemImage: "shippingbox") {
            row("Version", package.version)
            FirmwareVerdict(version: package.numericVersion, running: status?.activeFirmware)
            row("Size", ByteCountFormatter.string(fromByteCount: package.zipSize, countStyle: .file))
            if let checksum = package.checksumMatches {
                Label(checksum ? "Matches Meta's checksum" : "Doesn't match Meta's checksum: download again",
                      systemImage: checksum ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(checksum ? Theme.mint : Theme.danger)
            }
            if let inspection {
                Label(inspection.verified ? "Every item matches the manifest (size and SHA-256)" : "Items don't match the manifest",
                      systemImage: inspection.verified ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(inspection.verified ? Theme.mint : Theme.danger)
                ForEach(inspection.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.danger) }
            }
            row("Key for this band", package.hasBandKey ? "downloaded (never shown or exported)" : "not downloaded")
            if let offer = package.offer {
                if let base = offer.baseVersion { row("Base version", base) }
                if let tag = offer.releaseTag { row("Release tag", tag) }
                if let notes = offer.releaseNotes { Text(notes).font(.caption).foregroundStyle(.secondary) }
                row("Offered by", offer.source)
            }
            HStack {
                ShareLink(items: FirmwareLibrary.exportFiles(package)) { Label("Export for research", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Delete", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered).disabled(running)
            }
            Text("Export shares ota.zip and Meta's offer. The band's key is never included.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: install

    private var checks: [(ok: Bool, text: String)] {
        let version = package.numericVersion ?? 0
        var list: [(Bool, String)] = [
            (band.phase == .streaming, "The band is connected"),
            (band.charging == true || (band.battery ?? 0) >= 50, "The band is charging or at least 50% (it's \(band.battery.map { "\($0)%" } ?? "unknown")\(band.charging == true ? ", charging" : ""))"),
            (inspection?.verified == true && package.checksumMatches != false, "The package is intact"),
            (status.map { ($0.activeFirmware ?? 0) < version } ?? false, "It's newer than what the band runs"),
        ]
        let needKey = inspection?.kekVersion
        let hasKey = package.hasBandKey || (needKey != nil && status?.kek == needKey)
        list.append((hasKey, needKey.map { "The firmware key \($0) is on the band or downloaded" } ?? "Firmware key known"))
        if let status, status.state == 0 { list.append((false, "The band's update service is available (\(status.reasonName ?? "unavailable"))")) }
        return list
    }

    private var install: some View {
        Card(title: "Install", systemImage: "square.and.arrow.down.on.square") {
            ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                Label(check.text, systemImage: check.ok ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.caption).foregroundStyle(check.ok ? Theme.mint : .secondary)
            }
            let ready = checks.allSatisfy(\.ok) && !band.otaRunning
            Button {
                start(.trial)
            } label: {
                Label("Dry run (send, check, abort)", systemImage: "testtube.2").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!ready)
            Text("Sends the whole package, lets the band check it, then cancels: the band keeps its current firmware. If the band needs the package's firmware key, it gets installed (that part stays). Takes as long as the real thing (about 15–25 minutes).")
                .font(.caption2).foregroundStyle(.secondary)
            Button {
                confirmInstall = true
            } label: {
                Label("Install firmware…", systemImage: "arrow.down.to.line.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.warn)
            .disabled(!ready)
            if let planError { Text(planError).font(.caption).foregroundStyle(Theme.danger) }
            if let error = band.otaError { Text(error).font(.caption).foregroundStyle(Theme.danger) }
        }
    }

    private func start(_ mode: OtaMode) {
        guard let bandTag else { planError = "Connect the band first."; return }
        do {
            let plan = try FirmwareLibrary.plan(package, bandTag: bandTag, mode: mode)
            planError = nil
            UIApplication.shared.isIdleTimerDisabled = true
            band.startOta(plan)
        } catch {
            planError = error.localizedDescription
        }
    }

    private var progress: some View {
        Card(title: band.otaRunning ? "Updating" : "Last run", systemImage: "arrow.up.arrow.down") {
            if let ota = band.ota {
                Text("\(ota.mode.rawValue.capitalized) of \(FirmwareLibrary.name(String(ota.version)))\(ota.running ? "" : " · finished")")
                    .font(.callout.weight(.semibold))
                ForEach(ota.items, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.name).font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(item.stage) · \(item.sent / 1024) / \(item.size / 1024) KB").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(item.sent), total: Double(max(item.size, 1)))
                    }
                }
                if ota.running {
                    Text("Keep this screen open and the band close to the phone. The screen stays awake.").font(.caption).foregroundStyle(Theme.warn)
                    Button(role: .destructive) { band.cancelOta() } label: { Label("Cancel", systemImage: "xmark.circle") }
                        .buttonStyle(.bordered)
                        .disabled(!ota.cancellable)
                    Text(ota.cancellable ? "Cancelling now is safe: the band keeps the firmware it runs." : "Not safe to cancel: the band is installing.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !band.otaLog.isEmpty {
                DisclosureGroup("Log (\(band.otaLog.count) lines)") {
                    ForEach(Array(band.otaLog.suffix(80).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(line.hasPrefix("FAILED") ? Theme.danger : .secondary)
                    }
                }
                .font(.caption)
            }
        }
    }

    // MARK: contents

    private func contents(_ inspection: FirmwareInspection) -> some View {
        Card(title: "What's inside", systemImage: "doc.zipper") {
            if let kek = inspection.kekVersion { row("Needs firmware key", String(kek)) }
            ForEach(inspection.manifestFields, id: \.key) { field in row(field.key, field.value) }
            ForEach(inspection.files) { file in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(file.path).font(.callout.monospaced().weight(.semibold))
                        if let item = file.item { Text(item.typeName).font(.caption2.bold()).padding(.horizontal, 5).background(Theme.accent.opacity(0.3), in: Capsule()) }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(.caption.monospacedDigit())
                    }
                    if let version = file.item?.version { Text("version \(version)").font(.caption2).foregroundStyle(.secondary) }
                    Text("\(file.guess) · \(String(format: "%.3f", file.entropy)) bits/byte · \(file.method)").font(.caption2).foregroundStyle(.secondary)
                    Text("SHA-256 \(file.sha256)").font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("first bytes \(file.head)").font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if !file.strings.isEmpty {
                        DisclosureGroup("Readable strings (\(file.strings.count))") {
                            ForEach(Array(file.strings.enumerated()), id: \.offset) { _, string in
                                Text(string).font(.caption2.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .font(.caption2)
                    }
                }
                .padding(.vertical, 4)
            }
            if let manifest = inspection.manifestText {
                DisclosureGroup("manifest.json") {
                    Text(manifest).font(.caption2.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

/// The install question: Install stays off until the risk is acknowledged.
struct InstallConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    let package: FirmwarePackage
    var onInstall: () -> Void
    @State private var understood = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Install \(package.title)?", systemImage: "exclamationmark.triangle.fill").font(.title3.bold()).foregroundStyle(Theme.warn)
                    Text("This sends \(package.title) to the band, has the band check it, and installs it. The band then restarts into the new firmware.")
                    Text("**It can't be undone.** As far as anyone knows, the band refuses older firmware, so you can't go back to the version it runs now.")
                    Text("**This isn't Meta's updater.** It sends Meta's own package the way the Meta AI app does, but if something goes wrong there's no official support. Air Gestures has done this successfully; it still warns that an update can brick a band.")
                    Text("**Before you start:** band on its charger (or at least 50%), close to the phone, this screen open for 15–25 minutes. Taking the band off your wrist and leaving it still helps. Cancelling is safe until the last step.")
                    Text("**Afterwards:** the band uses the newer connection scheme. The app supports it, but you may need to reconnect or claim the band again. The ESP32 dongle will need re-pairing and possibly a band-core update.")
                    Toggle("I understand this can't be undone", isOn: $understood).font(.callout.weight(.semibold))
                    Button {
                        dismiss()
                        onInstall()
                    } label: {
                        Label("Install \(package.title)", systemImage: "arrow.down.to.line.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.warn)
                    .disabled(!understood)
                }
                .font(.callout)
                .padding()
            }
            .navigationTitle("Install firmware")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}
