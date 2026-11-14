import BandCredentials
import BandKit
import BandLogging
import BandProtocol
import SwiftUI
import UniformTypeIdentifiers

/// Phase 2: "Band Credentials" — view, reveal, copy, export, share, import, back up and delete.
struct CredentialsView: View {
    @Environment(BandClient.self) private var band
    @State private var revealedKey: String?
    @State private var revealTask: Task<Void, Never>?
    @State private var addressDraft = ""
    @State private var pendingAction: SecretAction?
    @State private var exportDocument: DataDocument?
    @State private var exportName = AirGesturesFile.defaultFileName
    @State private var exportType: UTType = .json
    @State private var exporting = false
    @State private var sharedFile: SharedFile?
    @State private var showEncrypt = false
    @State private var importing = false
    @State private var confirmDelete = false
    @State private var message: String?

    enum SecretAction: Identifiable {
        case copy, exportJSON, shareJSON, exportRawKey
        var id: Self { self }

        var title: String {
            switch self {
            case .copy: "Copy the owner key?"
            case .exportJSON, .shareJSON: "Export an unencrypted key?"
            case .exportRawKey: "Export the raw owner.key?"
            }
        }

        var warning: String {
            switch self {
            case .copy:
                "Anyone with this key can control your band. The clipboard stays on this device and clears after 60 seconds."
            case .exportJSON, .shareJSON:
                "air-gestures-band.json holds your owner key in plain text, as air-gestures expects. Anyone with the file can control your band. Keep it private and delete it after importing. For storage, use an encrypted backup instead."
            case .exportRawKey:
                "This is the bare 32-byte private key (for kinesis on macOS, or air-gestures `import owner.key`). It's unencrypted."
            }
        }
    }

    var body: some View {
        List {
            identitySection
            keySection
            if band.ownerFingerprint != nil { portabilitySection }
            restoreSection
            metaSection
            dangerSection
            guideSection
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Band Credentials")
        .onAppear { addressDraft = band.storedBand?.address ?? "" }
        .onDisappear { hideKey() }
        .alert(pendingAction?.title ?? "", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
               presenting: pendingAction) { action in
            Button("Continue", role: .destructive) { Task { await perform(action) } }
            Button("Cancel", role: .cancel) {}
        } message: { action in Text(action.warning) }
        .alert("Delete local credentials?", isPresented: $confirmDelete) {
            Button("Delete from this iPhone", role: .destructive) { Task { await deleteAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the owner key, any pending key and the band record from this iPhone. The band stays claimed by this key. Without a backup, you'd need a factory reset and a new claim. Your Meta session isn't touched.")
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
            switch result {
            case .success(let url): message = "Saved \(url.lastPathComponent)."; logNotice(.credentials, "Credentials exported to Files (\(url.lastPathComponent))")
            case .failure(let error): message = error.localizedDescription; logWarning(.credentials, "Export failed: \(BandLog.describe(error))")
            }
            exportDocument = nil
        }
        .sheet(item: $sharedFile) { file in ShareSheet(url: file.url).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showEncrypt) { NavigationStack { EncryptedBackupView() } }
        .sheet(isPresented: $importing) { NavigationStack { ImportCredentialsView() } }
        .overlay(alignment: .bottom) {
            if let message {
                Text(message).font(.callout).padding(12).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 12)
                    .task { try? await Task.sleep(for: .seconds(3)); self.message = nil }
            }
        }
    }

    // MARK: sections

    private var identitySection: some View {
        Section("Band identity (not secret)") {
            if let stored = band.storedBand {
                InfoRow(label: "Name", value: stored.name)
                InfoRow(label: "Origin", value: origin(stored.origin))
                InfoRow(label: "Saved", value: stored.savedAt.formatted(date: .abbreviated, time: .shortened))
                if let last = stored.lastConnectedAt { InfoRow(label: "Last connected", value: last.formatted(date: .abbreviated, time: .shortened)) }
                InfoRow(label: "iOS identifier", value: stored.peripheralID?.uuidString ?? "not connected here yet", monospaced: true)
                InfoRow(label: "Firmware", value: stored.firmware ?? band.deviceInfo?.firmware ?? "—")
                InfoRow(label: "Hardware", value: stored.hardware ?? "—")
                InfoRow(label: "Serial", value: stored.serial.map { BandLog.mask($0) } ?? "—", monospaced: true)
                InfoRow(label: "Encryption", value: stored.schemeGuess.map { "scheme 26, key guess \($0)" } ?? "scheme 3 / not yet known")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bluetooth address (for Linux)").foregroundStyle(.secondary).font(.callout)
                    HStack {
                        TextField("AA:BB:CC:DD:EE:FF", text: $addressDraft)
                            .font(.callout.monospaced()).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button("Save") {
                            let value = addressDraft.trimmingCharacters(in: .whitespaces).uppercased()
                            band.updateBand { $0.address = value.isEmpty ? nil : value }
                            message = value.isEmpty ? "Address cleared." : "Address saved."
                        }
                        .disabled(!addressDraft.isEmpty && !AirGesturesBand.isValidAddress(addressDraft.trimmingCharacters(in: .whitespaces)))
                    }
                    Text("iOS never reveals the band's Bluetooth address, but air-gestures on Linux needs it to reconnect. Imported files keep theirs. Otherwise copy it from `bluetoothctl devices` on Linux. Without it, the export holds the key only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("No band saved yet.").foregroundStyle(.secondary)
            }
        }
    }

    private var keySection: some View {
        Section("Owner key (secret)") {
            if let fingerprint = band.ownerFingerprint {
                InfoRow(label: "Fingerprint", value: fingerprint, monospaced: true)
                InfoRow(label: "Band key included", value: band.ownerHasBandKey ? "yes (97-byte key, verifies the band)" : "no (32-byte key)")
                InfoRow(label: "Stored in", value: "Keychain, this device only")
                if let revealedKey {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(revealedKey).font(.footnote.monospaced()).textSelection(.enabled)
                            .padding(10).background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        Text("Base64, as in air-gestures-band.json. It hides again after 60 seconds.").font(.caption).foregroundStyle(.secondary)
                        Button("Hide") { hideKey() }
                    }
                } else {
                    HStack {
                        Text(String(repeating: "•", count: 24)).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await reveal() } } label: { Label("Reveal", systemImage: "faceid") }
                    }
                }
                Button { pendingAction = .copy } label: { Label("Copy owner key…", systemImage: "doc.on.doc") }
            } else if band.hasPendingKey {
                Label("Only an unconfirmed key from an interrupted claim is stored. Connect once so the band confirms it.", systemImage: "hourglass")
                    .foregroundStyle(Theme.warn)
            } else {
                Text("No owner key stored. Import one below, or claim the band from the Band tab.").foregroundStyle(.secondary)
            }
        }
    }

    private var portabilitySection: some View {
        Section {
            Button { pendingAction = .exportJSON } label: { Label("Export air-gestures-band.json to Files…", systemImage: "folder") }
            Button { pendingAction = .shareJSON } label: { Label("Share air-gestures-band.json…", systemImage: "square.and.arrow.up") }
            Button { showEncrypt = true } label: { Label("Create encrypted backup (.npbackup)…", systemImage: "lock.doc") }
            Button { pendingAction = .exportRawKey } label: { Label("Export raw owner.key (kinesis / Mac)…", systemImage: "key") }
        } header: {
            Text("Back up & move to another device")
        } footer: {
            Text(band.storedBand?.airGesturesBand == nil
                 ? "This export holds only the key: no Bluetooth address is saved. Add it above so air-gestures on Linux can reconnect without pairing again."
                 : "This export holds the key and the band record (address, name, scheme guess).")
        }
    }

    private var restoreSection: some View {
        Section("Restore & reconnect") {
            Button { importing = true } label: { Label("Import credentials…", systemImage: "square.and.arrow.down") }
            Button {
                band.connect()
            } label: { Label("Reconnect with saved credentials (no Meta)", systemImage: "bolt.horizontal") }
                .disabled(!band.hasOwnerKey || band.storedBand?.peripheralID == nil || band.phase.isActive)
        }
    }

    private var metaSection: some View {
        Section {
            InfoRow(label: "Meta session", value: band.hasMetaSession ? "saved (claiming only)" : "none")
            if band.hasMetaSession {
                Button("Forget Meta session", role: .destructive) { band.forgetMetaSession(); message = "Meta session forgotten." }
            }
        } header: {
            Text("Meta account")
        } footer: {
            Text("The Meta session is only used to claim a band. It's stored separately from the owner key, so forgetting it doesn't affect reconnecting.")
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Delete local credentials…", role: .destructive) { confirmDelete = true }
                .disabled(!band.hasOwnerKey && band.storedBand == nil)
        }
    }

    private var guideSection: some View {
        Section("Using the key elsewhere") {
            guide("Linux (air-gestures)", "air-gestures import air-gestures-band.json\nair-gestures disconnect   # on the device you're leaving")
            guide("Android / rokid-lumen", "Setup › Owner key › Import, then choose the JSON file.")
            guide("Mac (kinesis dev build)", "Import the raw 32-byte owner.key. Note: kinesis predates scheme-26 firmware.")
            guide("Encrypted backup", "Decrypt with this app (Import), or any tool: PBKDF2-HMAC-SHA256 → AES-256-GCM. Parameters are inside the file.")
            Text("The band talks to one device at a time. If another device has claimed it since, forget the band in that device's Bluetooth settings and pair it again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func guide(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func origin(_ origin: StoredBand.Origin) -> String {
        switch origin {
        case .claimedHere: "Claimed on this iPhone"
        case .imported: "Imported (air-gestures JSON)"
        case .encryptedBackup: "Restored from encrypted backup"
        }
    }

    // MARK: actions

    private func ownerIdentity() -> OwnerIdentity? {
        do { return try band.store.loadOwner() } catch {
            message = error.localizedDescription
            logError(.credentials, "Couldn't read the owner key: \(BandLog.describe(error))")
            return nil
        }
    }

    private func reveal() async {
        guard await DeviceAuth.authenticate("Reveal your band's owner key"), let identity = ownerIdentity() else { return }
        revealedKey = Data(identity.ownerKeyBytes).base64EncodedString()
        logNotice(.credentials, "Owner key revealed on screen")
        revealTask?.cancel()
        revealTask = Task { try? await Task.sleep(for: .seconds(60)); if !Task.isCancelled { hideKey() } }
    }

    private func hideKey() {
        revealTask?.cancel()
        revealedKey = nil
    }

    private func perform(_ action: SecretAction) async {
        guard await DeviceAuth.authenticate("Export your band's owner key"), let identity = ownerIdentity() else { return }
        let json = AirGesturesFile.encode(identity: identity, band: band.storedBand?.airGesturesBand)
        switch action {
        case .copy:
            SecureClipboard.copySecret(Data(identity.ownerKeyBytes).base64EncodedString())
            message = "Copied. The clipboard clears in 60 s."
        case .exportJSON:
            exportDocument = DataDocument(data: json)
            exportName = AirGesturesFile.defaultFileName
            exportType = .json
            exporting = true
            logNotice(.credentials, "Exporting unencrypted air-gestures-band.json (band record: \(band.storedBand?.airGesturesBand != nil))")
        case .shareJSON:
            do {
                sharedFile = SharedFile(url: try TemporaryShareFile.make(name: AirGesturesFile.defaultFileName, data: json))
                logNotice(.credentials, "Sharing unencrypted air-gestures-band.json via share sheet")
            } catch { message = error.localizedDescription }
        case .exportRawKey:
            exportDocument = DataDocument(data: Data(identity.ownerKeyBytes.prefix(32)))
            exportName = "owner.key"
            exportType = .data
            exporting = true
            logNotice(.credentials, "Exporting raw 32-byte owner.key")
        }
    }

    private func deleteAll() async {
        guard await DeviceAuth.authenticate("Delete your band's owner key from this iPhone") else { return }
        do {
            try band.deleteLocalCredentials()
            hideKey()
            addressDraft = ""
            message = "Local credentials deleted."
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Create a password-encrypted backup, then save or share it.
struct EncryptedBackupView: View {
    @Environment(BandClient.self) private var band
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var document: DataDocument?
    @State private var exporting = false
    @State private var shared: SharedFile?

    private var fileName: String {
        let name = (band.storedBand?.name ?? "neural-band").replacingOccurrences(of: " ", with: "-").lowercased()
        return "\(name)-backup.\(EncryptedBackup.fileExtension)"
    }

    var body: some View {
        Form {
            Section {
                SecureField("Password (10+ characters)", text: $password).textContentType(.newPassword)
                SecureField("Repeat password", text: $confirm).textContentType(.newPassword)
            } footer: {
                Text("An encrypted backup (.npbackup) is a Neural Playground format, separate from air-gestures-band.json. It holds the same JSON, sealed with AES-256-GCM using a key derived from your password (PBKDF2, 600,000 rounds). You can't recover the password, so store it in a password manager.")
            }
            if let error { Text(error).foregroundStyle(Theme.danger) }
            Section {
                Button { Task { await make(share: false) } } label: { Label("Save to Files…", systemImage: "folder") }
                Button { Task { await make(share: true) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            }
            .disabled(working || password.count < EncryptedBackup.minimumPasswordLength || password != confirm)
            if working { ProgressView("Encrypting…") }
        }
        .navigationTitle("Encrypted backup")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .fileExporter(isPresented: $exporting, document: document, contentType: .encryptedBandBackup, defaultFilename: fileName) { result in
            if case .success = result { logNotice(.credentials, "Encrypted backup saved to Files"); dismiss() }
        }
        .sheet(item: $shared) { file in ShareSheet(url: file.url) { done in if done { dismiss() } } }
    }

    private func make(share: Bool) async {
        guard await DeviceAuth.authenticate("Back up your band's owner key"), let identity = try? band.store.loadOwner() else { return }
        working = true
        defer { working = false }
        let json = AirGesturesFile.encode(identity: identity, band: band.storedBand?.airGesturesBand)
        let password = password
        let name = band.storedBand?.name
        let fingerprint = identity.fingerprint
        do {
            let sealed = try await Task.detached(priority: .userInitiated) {
                try EncryptedBackup.encrypt(airGesturesJSON: json, password: password, bandName: name, fingerprint: fingerprint)
            }.value
            logNotice(.credentials, "Encrypted backup created (\(sealed.count)B, fingerprint \(fingerprint))")
            if share {
                shared = SharedFile(url: try TemporaryShareFile.make(name: fileName, data: sealed))
            } else {
                document = DataDocument(data: sealed)
                exporting = true
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Import an air-gestures JSON, raw owner.key, or encrypted backup — validated and previewed first.
struct ImportCredentialsView: View {
    @Environment(BandClient.self) private var band
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var imported: AirGesturesFile.Imported?
    @State private var origin: StoredBand.Origin = .imported
    @State private var backupData: Data?
    @State private var password = ""
    @State private var error: String?
    @State private var confirmReplace = false
    @State private var pasted = ""

    var body: some View {
        Form {
            Section {
                Button { picking = true } label: { Label("Choose a file…", systemImage: "doc") }
            } footer: {
                Text("Accepts air-gestures-band.json (Linux, Android, this app), a raw 32- or 97-byte owner.key, or a Neural Playground .npbackup.")
            }
            Section {
                TextField("Paste air-gestures-band.json contents", text: $pasted, axis: .vertical)
                    .font(.caption.monospaced()).lineLimit(3...8).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Read pasted JSON") { parse(Data(pasted.utf8)) }.disabled(pasted.isEmpty)
            }
            if let backupData {
                Section("Encrypted backup") {
                    if let hint = EncryptedBackup.hint(backupData) {
                        if let name = hint.bandName { InfoRow(label: "Band", value: name) }
                        if let fingerprint = hint.ownerFingerprint { InfoRow(label: "Fingerprint", value: fingerprint, monospaced: true) }
                        if let created = hint.created { InfoRow(label: "Created", value: created) }
                    }
                    SecureField("Backup password", text: $password)
                    Button("Decrypt") { Task { await decrypt(backupData) } }.disabled(password.isEmpty)
                }
            }
            if let imported {
                Section("Validated") {
                    Label("Valid P-256 owner key", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.mint)
                    InfoRow(label: "Fingerprint", value: imported.identity.fingerprint, monospaced: true)
                    InfoRow(label: "Band key", value: imported.identity.verifiesBand ? "included (verifies the band)" : "not included")
                    if let record = imported.band {
                        InfoRow(label: "Band", value: record.name)
                        InfoRow(label: "Address", value: record.address, monospaced: true)
                        if AirGesturesBand.isPrivateAddress(record.address) {
                            Text("This is a resolvable private address recorded by a phone. Linux may need its identity address instead.").font(.caption).foregroundStyle(Theme.warn)
                        }
                        InfoRow(label: "Scheme guess", value: record.schemeGuess.map(String.init) ?? "—")
                    } else {
                        Text(imported.rawKey ? "A raw key file: it has no band record." : "No band record in this file.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let existing = band.ownerFingerprint {
                        if existing == imported.identity.fingerprint {
                            Label("Same key as the one already stored.", systemImage: "equal.circle").foregroundStyle(.secondary)
                        } else {
                            Label("Different from the stored key (\(existing)). Importing replaces it on this iPhone.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.warn)
                        }
                    }
                    Button("Save to Keychain") {
                        if let existing = band.ownerFingerprint, existing != imported.identity.fingerprint { confirmReplace = true } else { save() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let error { Section { Text(error).foregroundStyle(Theme.danger) } }
        }
        .navigationTitle("Import credentials")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .encryptedBandBackup, .data, .item]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    logInfo(.credentials, "Import: read \(url.lastPathComponent) (\(data.count)B)")
                    parse(data)
                } catch { self.error = error.localizedDescription }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .alert("Replace the stored owner key?", isPresented: $confirmReplace) {
            Button("Replace", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The key stored now (\(band.ownerFingerprint ?? "—")) will be removed from this iPhone. If it's the one your band trusts and you have no backup, you'll lose access.")
        }
    }

    private func parse(_ data: Data) {
        error = nil
        imported = nil
        backupData = nil
        if EncryptedBackup.isBackup(data) {
            backupData = data
            origin = .encryptedBackup
            logInfo(.credentials, "Import: encrypted backup detected")
            return
        }
        do {
            imported = try AirGesturesFile.parse(data)
            origin = .imported
            logInfo(.credentials, "Import: valid key \(imported!.identity.fingerprint), band record \(imported!.band != nil)")
        } catch {
            self.error = error.localizedDescription
            logWarning(.credentials, "Import rejected: \(error.localizedDescription)")
        }
    }

    private func decrypt(_ data: Data) async {
        let password = password
        do {
            let json = try await Task.detached(priority: .userInitiated) { try EncryptedBackup.decrypt(data, password: password) }.value
            imported = try AirGesturesFile.parse(json)
            origin = .encryptedBackup
            error = nil
            logInfo(.credentials, "Encrypted backup decrypted (key \(imported!.identity.fingerprint))")
        } catch {
            self.error = error.localizedDescription
            logWarning(.credentials, "Backup decrypt failed: \(error.localizedDescription)")
        }
    }

    private func save() {
        guard let imported else { return }
        do {
            try band.importCredentials(imported, origin: origin)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
