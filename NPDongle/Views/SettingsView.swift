import DongleProtocol
import SwiftUI

/// The rest: the status Live Activity, the air mouse, the band, test keys, logs and restarting.
struct SettingsView: View {
    @Environment(DongleModel.self) private var model
    @State private var confirmReboot = false

    private var link: DongleLink { model.link }
    private var status: DongleStatus? { link.status }

    var body: some View {
        List {
            liveActivity
            if let status, link.isReady {
                if let mouse = status.mouse { mouseSettings(mouse) }
                band(status)
                TestKeysSection(activeHost: status.activeHost)
            }
            Section("Dongle") {
                NavigationLink { LogsView() } label: { Label("Logs", systemImage: "text.alignleft") }
                Button(role: .destructive) { confirmReboot = true } label: { Label("Restart the dongle", systemImage: "restart.circle") }
                    .disabled(!link.isReady || model.updater.isBusy || model.uploader.isBusy)
            }
            Section("About") {
                InfoRow(label: "NP Dongle", value: DongleModel.version)
                InfoRow(label: "Release host", value: DongleUpdater.releasesHost.isEmpty ? "Not set" : "Set")
                InfoRow(label: "Profiles file", value: "Documents/\(ProfileStore.fileName)", monospaced: true)
            }
        }
        .darkList()
        .navigationTitle("Settings")
        .confirmationDialog("Restart the dongle?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { link.send(.reboot) }
        } message: {
            Text("Hosts and the band reconnect by themselves within a few seconds.")
        }
    }

    private var liveActivity: some View {
        Section {
            Toggle(isOn: Binding(get: { model.activities.statusWanted }, set: { model.setStatusActivity($0) })) {
                Label { Text("Dongle status on the Lock Screen"); Text("Active host, profile and band battery").font(.caption) } icon: { Image(systemName: "lock.iphone") }
            }
            .disabled(!model.activities.enabled && !model.activities.statusWanted)
            if let error = model.activities.lastError { Text(error).font(.footnote).foregroundStyle(Theme.warn) }
            if !model.activities.enabled {
                Text("Live Activities are off for NP Dongle: turn them on in Settings › NP Dongle.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Live Activity")
        } footer: {
            Text("It updates while NP Dongle runs; when the app has been away for a while it shows that it isn't current. Firmware updates always show their progress there.")
        }
    }

    private func mouseSettings(_ mouse: DongleStatus.Mouse) -> some View {
        Section {
            Stepper("Speed \(mouse.speed)", value: Binding(get: { mouse.speed }, set: { link.send(.mouseSpeed($0)) }), in: 1...10)
            Toggle("Flip left and right", isOn: Binding(get: { mouse.flipX }, set: { link.send(.mouse(.flipX, $0)) }))
            Toggle("Flip up and down", isOn: Binding(get: { mouse.flipY }, set: { link.send(.mouse(.flipY, $0)) }))
            Toggle("Type what I write", isOn: Binding(get: { mouse.typing }, set: { link.send(.mouse(.typing, $0)) }))
        } header: {
            Text("Air mouse and typing")
        } footer: {
            Text("For profiles with the air mouse: the pointer moves only while you pinch and hold. If it goes the wrong way, flip that direction. “Type what I write” switches handwriting typing off everywhere (the pointer keeps working).")
        }
    }

    private func band(_ status: DongleStatus) -> some View {
        Section {
            if status.band?.state == "paused" {
                Button { link.send(.bandResume) } label: { Label("Reclaim: the dongle takes the band back", systemImage: "play.circle") }
            } else {
                Button { link.send(.bandPause) } label: { Label("Release the band for Neural Playground", systemImage: "pause.circle") }
            }
        } header: {
            Text("Band")
        } footer: {
            Text("The band talks to one device at a time. Release hands it to the Neural Playground app (its Band tab); Reclaim gives it back to the dongle.")
        }
    }
}

/// Sends single keys to the active host, to check the link end to end.
struct TestKeysSection: View {
    @Environment(DongleModel.self) private var model
    let activeHost: DongleStatus.Host?

    private static let keys: [(name: String, title: String, symbol: String)] = [
        ("playpause", "Play/Pause", "playpause.fill"), ("previous", "Previous", "backward.fill"), ("next", "Next", "forward.fill"),
        ("voldown", "Volume −", "speaker.minus.fill"), ("volup", "Volume +", "speaker.plus.fill"), ("voice", "Voice", "mic.fill"),
        ("phonemute", "Phone mute", "mic.slash.fill"), ("teamsmute", "Teams mute", "person.2.slash"), ("blank", "Blank", "rectangle.fill"),
        ("left", "Left", "arrow.left"), ("right", "Right", "arrow.right"),
    ]

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(Self.keys, id: \.name) { key in
                    Button { model.link.send(.key(key.name)) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: key.symbol)
                            Text(key.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Test keys")
        } footer: {
            Text("Sends the key to \(activeHost.map { "the active host, \($0.displayName)" } ?? "the active host").")
        }
    }
}

/// The dongle's log over Bluetooth, to read, copy or share.
struct LogsView: View {
    @Environment(DongleModel.self) private var model
    @State private var copied = false

    private var link: DongleLink { model.link }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(link.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line).id(index)
                            .foregroundStyle(line.hasPrefix("E") ? Theme.danger : line.hasPrefix("W") ? Theme.warn : .secondary)
                    }
                    if !link.logPending.isEmpty { Text(link.logPending).foregroundStyle(.secondary) }
                    if link.logLines.isEmpty && link.logPending.isEmpty {
                        Text("Log lines appear here while the dongle is connected. Fetch the backlog for the last ~200.").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .onChange(of: link.logLines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .screenBackground()
        .navigationTitle("Logs (\(link.logLines.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { link.send(.logs) } label: { Label("Fetch backlog", systemImage: "clock.arrow.circlepath") }
                    .disabled(!link.isReady)
                Spacer()
                Button {
                    Clipboard.copy(link.logText)
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                ShareLink(item: link.logText, preview: SharePreview("np-band-remote-log.txt")) { Label("Share", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) {
                    link.clearLog()
                    copied = false
                } label: { Label("Clear", systemImage: "trash") }
                    .disabled(link.logLines.isEmpty)
            }
        }
    }
}
