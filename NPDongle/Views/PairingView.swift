import DongleProtocol
import SwiftUI

/// Pairing a new device: pick what it is, open the dongle's pairing window (`pair <kind>`), follow
/// that device's steps while the countdown runs, and close the window when done.
struct PairingView: View {
    @Environment(DongleModel.self) private var model
    @State private var kind: DongleCommand.HostType = .mac
    /// What this app opened the window for (nil: opened elsewhere, like at the dongle's start).
    @State private var requested: DongleCommand.HostType?

    private var link: DongleLink { model.link }

    var body: some View {
        List {
            if !link.isReady {
                ConnectionSection()
            } else if let status = link.status {
                if status.pairingSecondsLeft > 0 {
                    openWindow(status)
                } else {
                    chooser(status)
                }
            }
        }
        .darkList()
        .navigationTitle("Pair a device")
    }

    // MARK: choosing

    private func chooser(_ status: DongleStatus) -> some View {
        Group {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(DongleCommand.HostType.allCases, id: \.self) { type in
                        Button { kind = type } label: {
                            VStack(spacing: 6) {
                                Image(systemName: type.symbol).font(.title2)
                                Text(type.label).font(.callout.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .background((kind == type ? Theme.accent : Color.white).opacity(kind == type ? 0.22 : 0.06),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(kind == type ? Theme.accent : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
                Text(kind.caption).font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("What are you pairing?")
            }
            Section {
                Button {
                    requested = kind
                    link.send(.pairType(kind))
                } label: {
                    Label("Open a 2-minute pairing window", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .disabled(status.hosts.count >= 5)
            } footer: {
                Text(status.hosts.count >= 5
                     ? "Five hosts are connected, the most the dongle takes. Forget one on the Dongle tab first."
                     : "While the window is open, the next new device to pair becomes a \(kind.label). Outside it, unknown devices can't pair. A phone gets media keys only; computers and TVs get a keyboard and mouse, so a phone can't later become a computer without pairing again.")
            }
        }
    }

    // MARK: the open window

    private func openWindow(_ status: DongleStatus) -> some View {
        Group {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = link.statusDate.map { context.date.timeIntervalSince($0) } ?? 0
                    let left = max(0, status.pairingSecondsLeft - Int(elapsed))
                    VStack(spacing: 8) {
                        ZStack {
                            Circle().stroke(Theme.mint.opacity(0.2), lineWidth: 8)
                            Circle().trim(from: 0, to: Double(left) / 120)
                                .stroke(Theme.mint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 1), value: left)
                            VStack(spacing: 2) {
                                Text(Duration.seconds(left).formatted(.time(pattern: .minuteSecond)))
                                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                                Text("left").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 150, height: 150)
                        Label(requested.map { "Pairing window open for a \($0.label)" } ?? "Pairing window open", systemImage: requested?.symbol ?? "dot.radiowaves.left.and.right")
                            .font(.headline).foregroundStyle(Theme.mint)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            if requested == nil {
                Section {
                    Picker("Device", selection: $kind) {
                        ForEach(DongleCommand.HostType.allCases, id: \.self) { type in Text(type.label).tag(type) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("The dongle opened this window itself (for 2 minutes after it starts, the next new device pairs as a computer). Pick a device for its steps.")
                }
            }
            Section {
                ForEach(Array(kind.pairingSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").font(.callout.weight(.bold)).foregroundStyle(Theme.accent).frame(width: 18)
                        Text(step).font(.callout)
                    }
                }
            } header: {
                Text("On the \(kind.label)")
            } footer: {
                Text("Once it's connected it shows up under Hosts on the Dongle tab. Close the window when you're done, so nothing else can pair.")
            }
            Section {
                Button(role: .destructive) {
                    link.send(.pairClose)
                    requested = nil
                } label: { Label("Close the pairing window", systemImage: "xmark.circle") }
            }
        }
    }
}
