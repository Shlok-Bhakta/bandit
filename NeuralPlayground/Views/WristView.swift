import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// Compact wrist switch for the top of the Playground and Band screens.
struct WristQuickSwitch: View {
    @Environment(BandClient.self) private var band

    var body: some View {
        @Bindable var band = band
        Card(title: "Wrist", systemImage: "hand.raised") {
            Picker("Worn on", selection: $band.wrist.wrist) {
                ForEach(Wrist.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                Image(systemName: bandMatches ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(bandMatches ? Theme.mint : Theme.warn)
                Text(bandStatus).font(.footnote)
                Spacer()
                if band.phase == .streaming, !bandMatches {
                    Button(syncing ? "Syncing…" : "Set band to \(band.wrist.wrist.hand.rawValue)") { band.syncWristToBand() }
                        .font(.footnote.weight(.semibold)).buttonStyle(.borderedProminent).disabled(syncing)
                }
            }
            if case .failed(let message) = band.handSync { Text(message).font(.caption).foregroundStyle(Theme.danger) }
            NavigationLink { WristView() } label: { Label("Wrist settings & corrections", systemImage: "slider.horizontal.3").font(.footnote) }
        }
    }

    private var syncing: Bool { if case .writing = band.handSync { true } else { false } }
    private var bandMatches: Bool { band.hand == band.wrist.wrist.hand }
    private var bandStatus: String {
        guard let hand = band.hand else { return band.phase == .streaming ? "Band hasn't reported its hand yet" : "Band hand: connect to read it" }
        return bandMatches ? "Band is also set to \(hand.rawValue)" : "Band is set to \(hand.rawValue): it doesn't match"
    }
}

/// Full wrist configuration: app profile per wrist, plus the band's own persisted setting.
struct WristView: View {
    @Environment(BandClient.self) private var band
    @State private var confirmSync = false

    var body: some View {
        @Bindable var band = band
        Form {
            Section {
                Picker("Worn on", selection: $band.wrist.wrist) {
                    ForEach(Wrist.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("App wrist profile")
            } footer: {
                Text("Switches right away without reconnecting, so you can hand the band to a friend and test. This changes only how the app reads gestures; the band isn't touched.")
            }
            Section {
                Toggle("Invert horizontal swipes", isOn: $band.wrist.active.invertHorizontal)
                Toggle("Invert vertical swipes", isOn: $band.wrist.active.invertVertical)
                Toggle("Invert pinch-dial rotation", isOn: $band.wrist.active.invertDial)
                Button("Restore defaults for \(band.wrist.wrist.title.lowercased())") {
                    band.wrist.active = .defaults(for: band.wrist.wrist)
                }
            } header: {
                Text("Corrections for \(band.wrist.wrist.title.lowercased())")
            } footer: {
                Text("Defaults come from kinesis's left-wrist testing: with the band set to the left hand, swipes came out right and only the gyro-based dial was reversed. Check with real swipes. The Playground shows both the band's raw gesture and the normalized one.")
            }
            Section {
                InfoRow(label: "Band reports", value: band.hand.map { $0 == .left ? "Left hand" : "Right hand" } ?? "unknown")
                InfoRow(label: "App profile", value: band.wrist.wrist.title)
                switch band.handSync {
                case .idle: EmptyView()
                case .writing(let hand): Label("Writing \(hand.rawValue), then reading back…", systemImage: "arrow.triangle.2.circlepath")
                case .confirmed(let hand, let date): Label("Verified by readback: \(hand.rawValue) (\(date.formatted(date: .omitted, time: .standard)))", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.mint)
                case .failed(let message): Label(message, systemImage: "xmark.octagon").foregroundStyle(Theme.danger)
                }
                Button("Sync wrist setting to band…") { confirmSync = true }
                    .disabled(band.phase != .streaming || band.hand == nil)
                HStack {
                    Button("Set band: Left") { band.setHand(.left) }
                    Spacer()
                    Button("Set band: Right") { band.setHand(.right) }
                }
                .buttonStyle(.bordered)
                .disabled(band.phase != .streaming || band.hand == nil)
            } header: {
                Text("Band's own hand setting")
            } footer: {
                Text("The band stores `is_left_handed` (ConfigReq field 10) and keeps it across reconnects. The app writes it, then reads it back separately before reporting success. The band seems to use this setting for its own gesture recognition. App-side inversion can relabel directions, but it can't make the band recognize gestures it misses because it's set for the other wrist, so match it to the wrist you wear it on.")
            }
        }
        .navigationTitle("Wrist")
        .alert("Change the band's hand setting?", isPresented: $confirmSync) {
            Button("Set to \(band.wrist.wrist.hand.rawValue)") { band.syncWristToBand() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This writes a setting that the band stores and keeps. You can switch it back here at any time.")
        }
    }
}
