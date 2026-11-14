import BandCredentials
import BandKit
import BandLogging
import BandProtocol
import BandTransport
import SwiftUI
import UniformTypeIdentifiers

/// Phase 1: scan, connect with a saved/imported owner key, or claim the band.
struct BandConnectionView: View {
    @Environment(BandClient.self) private var band
    @Environment(AppModel.self) private var model
    @State private var showAllDevices = false
    @State private var selected: DiscoveredDevice?
    @State private var claimTarget: DiscoveredDevice?
    @State private var confirmReplaceKey: DiscoveredDevice?
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StatusCard()
                if case .failed(let failure) = band.phase { FailureCard(failure: failure) }
                if band.phase == .pairingPrompt { PairingPromptCard() }
                credentialCard
                if band.phase == .streaming { WristQuickSwitch() }
                nearbyCard
                tipsCard
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Neural Band")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if band.phase.isActive || { if case .reconnecting = band.phase { true } else { false } }() {
                    Button("Disconnect", role: .destructive) { band.disconnect() }
                }
            }
        }
        .onAppear { if !band.phase.isActive { band.startScan() } }
        .onDisappear { band.stopScan() }
        .confirmationDialog(selected?.name ?? "", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
                            titleVisibility: .visible, presenting: selected) { device in
            if band.hasOwnerKey {
                Button("Connect with the saved owner key") { band.stopScan(); band.connect(to: device.id) }
            }
            Button(band.hasOwnerKey ? "Claim again with Meta (replaces key)…" : "Claim this band with Meta…") {
                if band.hasOwnerKey { confirmReplaceKey = device } else { claimTarget = device }
            }
            Button("Try without an owner key (pairing mode, experimental)") { band.stopScan(); band.connectWithoutKey(to: device.id) }
        } message: { device in
            Text("iOS identifier \(device.id.uuidString)")
        }
        .alert("Replace your working owner key?", isPresented: Binding(get: { confirmReplaceKey != nil }, set: { if !$0 { confirmReplaceKey = nil } }),
               presenting: confirmReplaceKey) { device in
            Button("Export a backup first") { model.tab = .credentials }
            Button("Claim anyway", role: .destructive) { claimTarget = device }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Claiming creates a new owner key. Once the band accepts it, the key saved now (\(band.ownerFingerprint ?? "—")) stops working on every device that uses it, including Linux and Mac. Back it up first if you might need it.")
        }
        .sheet(item: $claimTarget) { device in ClaimFlowView(device: device) }
        .sheet(isPresented: $importing) { NavigationStack { ImportCredentialsView() } }
    }

    private var credentialCard: some View {
        Card(title: "Ownership", systemImage: "key.horizontal") {
            if let fingerprint = band.ownerFingerprint {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.mint).font(.title2)
                    VStack(alignment: .leading) {
                        Text("Owner key saved").font(.headline)
                        Text("Fingerprint \(fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if let stored = band.storedBand {
                    InfoRow(label: "Band", value: stored.name)
                    if stored.peripheralID == nil {
                        Text("Imported key: choose your band below to connect it to this iPhone for the first time.")
                            .font(.footnote).foregroundStyle(Theme.warn)
                    }
                }
                if band.storedBand?.peripheralID != nil, !band.phase.isActive {
                    Button { band.stopScan(); band.connect() } label: {
                        Label("Connect", systemImage: "bolt.horizontal.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else if band.hasPendingKey {
                Label("An unconfirmed owner key from an interrupted claim is saved. Connect to confirm it.", systemImage: "hourglass")
                    .foregroundStyle(Theme.warn)
            } else {
                Text("No owner key on this iPhone yet.").font(.headline)
                Text("Already claimed the band on Linux or Android? Import its key. Otherwise, choose the band below to claim it with a one-time Meta sign-in.")
                    .font(.callout).foregroundStyle(.secondary)
                Button { importing = true } label: {
                    Label("Import air-gestures-band.json or backup", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    private var nearbyCard: some View {
        Card(title: "Nearby", systemImage: "dot.radiowaves.up.forward") {
            HStack {
                if band.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").foregroundStyle(.secondary)
                } else {
                    Text("Bluetooth \(band.bluetoothState)").foregroundStyle(.secondary)
                }
                Spacer()
                Button(band.isScanning ? "Stop" : "Scan") { band.isScanning ? band.stopScan() : band.startScan() }
                    .disabled(band.phase.isActive)
            }
            Toggle("Show other devices", isOn: $showAllDevices).font(.callout)
            let devices = band.discovered.filter { showAllDevices || $0.isBand }
            if devices.isEmpty {
                Text("Hold the band's button ~3 s until it flashes to put it in pairing mode. A band that's already bonded and in use appears as soon as it advertises.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                Button { if device.isBand { selected = device } } label: { DeviceRow(device: device, saved: band.storedBand?.peripheralID == device.id) }
                    .buttonStyle(.plain)
                    .disabled(!device.isBand || band.phase.isActive)
            }
        }
    }

    private var tipsCard: some View {
        Card(title: "How it works", systemImage: "info.circle") {
            Text("The app talks to the band directly over Bluetooth LE + L2CAP, using the reverse-engineered protocol from band-core, kinesis and air-gestures. Meta doesn't support it and could change it with a firmware update.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Only one device can use the band at a time. Disconnect it on Linux (`air-gestures disconnect`) or your Mac first.")
                .font(.footnote).foregroundStyle(.secondary)
            Label("The band remote dongle has its own app, NP Dongle.", systemImage: "cable.connector")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct DeviceRow: View {
    let device: DiscoveredDevice
    let saved: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.isBand ? "applewatch.side.right" : "dot.radiowaves.right")
                .font(.title2).foregroundStyle(device.isBand ? Theme.accent : .secondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(device.name).font(.headline)
                    if saved { Text("YOUR BAND").badgeStyle(Theme.mint) }
                    if device.systemConnected { Text("BONDED").badgeStyle(Theme.accent) }
                }
                Text(device.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if !device.advertisedServices.isEmpty {
                    Text("Services \(device.advertisedServices.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                if let rssi = device.rssi { Text("\(rssi) dBm").font(.caption.monospacedDigit()) }
                SignalBars(rssi: device.rssi)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

struct SignalBars: View {
    let rssi: Int?

    var body: some View {
        let level = rssi.map { $0 > -55 ? 4 : $0 > -67 ? 3 : $0 > -78 ? 2 : 1 } ?? 0
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1).fill(bar <= level ? Theme.mint : .white.opacity(0.15))
                    .frame(width: 4, height: CGFloat(bar) * 4)
            }
        }
    }
}

struct StatusCard: View {
    @Environment(BandClient.self) private var band

    var body: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.color(for: band.phase).opacity(0.18)).frame(width: 56, height: 56)
                    Image(systemName: Theme.symbol(for: band.phase)).font(.title2).foregroundStyle(Theme.color(for: band.phase))
                        .symbolEffect(.pulse, isActive: band.phase.isActive && band.phase != .streaming)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(band.phase.title).font(.headline)
                    Text(band.storedBand?.name ?? "No band saved").font(.subheadline).foregroundStyle(.secondary)
                    if let stage = band.ceremonyStage, case .claiming = band.phase {
                        Text(stage).font(.caption).foregroundStyle(Theme.accent)
                    }
                }
                Spacer()
            }
            if band.phase == .streaming {
                HStack(spacing: 18) {
                    stat("battery.75", band.battery.map { "\($0)%\(band.charging == true ? " ⚡︎" : "")" } ?? "—", "Battery")
                    stat("antenna.radiowaves.left.and.right", band.rssi.map { "\($0) dBm" } ?? "—", "Signal")
                    stat("cpu", band.deviceInfo?.firmware ?? "—", "Firmware")
                    stat("hand.raised", band.hand?.rawValue.capitalized ?? "—", "Hand")
                }
            }
        }
    }

    private func stat(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FailureCard: View {
    let failure: BandFailure
    @State private var copied = false

    var body: some View {
        Card(title: "Problem", systemImage: "exclamationmark.triangle") {
            Text(failure.title).font(.headline).foregroundStyle(Theme.danger)
            Text(failure.detail).font(.callout)
            if let suggestion = failure.suggestion {
                Label(suggestion, systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary)
            }
            if let code = failure.code { Text("Band result code 0x\(String(code, radix: 16))").font(.caption.monospaced()).foregroundStyle(.secondary) }
            Button {
                SecureClipboard.copy(BandLog.shared.export(header: AppModel.reportHeader))
                copied = true
            } label: {
                Label(copied ? "Log copied" : "Copy full log for support", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }
}

struct PairingPromptCard: View {
    var body: some View {
        Card(title: "Bluetooth pairing", systemImage: "hand.raised") {
            Text("Tap **Pair** on the iOS Bluetooth Pairing Request.").font(.headline)
            Text("If no request appears, or this keeps failing after a factory reset: open Settings › Bluetooth, tap ⓘ next to the band, choose Forget This Device, put the band back in pairing mode, and connect again.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// The guided claim: prerequisites, Meta sign-in, then the ceremony with live stages.
struct ClaimFlowView: View {
    let device: DiscoveredDevice
    @Environment(BandClient.self) private var band
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var signingIn = false
    @State private var started = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card(title: "Before you claim", systemImage: "list.bullet.clipboard") {
                        step(1, "Put the band in pairing mode", "Hold its button ~3 s until it flashes. If it was set up with the Meta AI app or glasses, you may need a factory reset first (hold ~16 s). Only you can do that: the app never resets the band.")
                        step(2, "Close the Meta AI app", "Make sure no other phone, Mac or Linux machine is connected to the band.")
                        step(3, "Sign in to Meta once", band.hasMetaSession ? "Signed in. The saved Meta session will be used." : "Opens Meta's own page. Your password never reaches this app.")
                        Toggle("I understand claiming unlinks the band from the Meta AI app and glasses, and replaces any owner key used elsewhere.", isOn: $acknowledged)
                            .font(.footnote)
                    }
                    if started {
                        Card(title: "Claim progress", systemImage: "key.fill") {
                            HStack(spacing: 12) {
                                if band.phase.isActive, band.phase != .streaming { ProgressView() }
                                Text(band.phase.title).font(.headline)
                            }
                            if let stage = band.ceremonyStage { Text(stage).foregroundStyle(.secondary) }
                            if band.phase == .pairingPrompt { PairingPromptCard() }
                            if case .failed(let failure) = band.phase { FailureCard(failure: failure) }
                            if band.phase == .streaming {
                                Label("Claimed and connected. Your owner key is saved in the Keychain.", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(Theme.mint)
                                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    Button { start() } label: {
                        Label(band.hasMetaSession ? "Claim \(device.name)" : "Sign in to Meta and claim", systemImage: "key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!acknowledged || band.phase.isActive)
                    if band.hasMetaSession {
                        Button("Use a different Meta account") { band.forgetMetaSession(); signingIn = true }
                            .font(.footnote).frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .screenBackground()
            .navigationTitle("Claim your band")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $signingIn) {
                MetaLoginView { session in
                    band.saveMetaSession(session)
                    started = true
                    band.stopScan()
                    band.claim(device.id, metaSession: session)
                }
            }
        }
    }

    private func start() {
        if let session = band.metaStore.load() {
            started = true
            band.stopScan()
            band.claim(device.id, metaSession: session)
        } else {
            signingIn = true
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.headline).frame(width: 28, height: 28).background(Theme.accent.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Shown after a successful claim: back the key up now.
struct BackupPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 56)).foregroundStyle(Theme.mint)
            Text("Back up your owner key").font(.title2.bold())
            Text("Your band now trusts this iPhone's owner key. Export it once to use the band on Linux and Mac (air-gestures), or to restore it, without signing in to Meta again. If this key is lost, the only way back in is a factory reset and a new claim.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button {
                model.tab = .credentials
                dismiss()
            } label: { Label("Open Band Credentials", systemImage: "key.horizontal").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button("Later") { dismiss() }
        }
        .padding(28)
        .presentationDetents([.medium])
    }
}
