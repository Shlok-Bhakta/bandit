import DongleProtocol
import SwiftUI

/// The dongle at a glance: the connection, the band, the active host and its profile (with a
/// quick switcher), and every connected host.
struct HomeView: View {
    @Environment(DongleModel.self) private var model
    @State private var renaming: DongleStatus.Host?
    @State private var newName = ""
    @State private var forgetting: DongleStatus.Host?

    private var link: DongleLink { model.link }
    private var status: DongleStatus? { link.status }

    var body: some View {
        List {
            ConnectionSection()
            if let status, link.isReady {
                activeSection(status)
                if status.supportsProfiles, let host = status.activeHost {
                    OnTheBandSection(host: host, profileID: host.profile ?? status.mode)
                }
                bandSection(status)
                hostsSection(status)
            }
        }
        .darkList()
        .navigationTitle("NP Dongle")
        .refreshable { link.readStatus() }
        .alert("Rename host", isPresented: renamingShown, presenting: renaming) { host in
            TextField("Name", text: $newName)
            Button("Rename") { link.send(.name(host.handle, newName)) }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { host in
            Text("The dongle shows this name for host \(host.handle).")
        }
        .confirmationDialog("Forget \(forgetting?.displayName ?? "this host")?", isPresented: forgettingShown,
                            titleVisibility: .visible, presenting: forgetting) { host in
            Button("Forget", role: .destructive) { link.send(.forget(host.handle)) }
        } message: { host in
            Text(host.handle == status?.you
                 ? "This deletes the dongle's pairing with this iPhone: the remote and this app stop working until you pair it again in Settings › Bluetooth, while a pairing window is open."
                 : "This deletes its pairing. To use it again, open a pairing window and pair it again from its Bluetooth settings.")
        }
    }

    private var renamingShown: Binding<Bool> { Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }) }
    private var forgettingShown: Binding<Bool> { Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }) }

    // MARK: active host and profile

    private func activeSection(_ status: DongleStatus) -> some View {
        Section {
            if let host = status.activeHost {
                let profileID = host.profile ?? status.mode
                let profile = model.profile(id: profileID)
                HStack(spacing: 14) {
                    Image(systemName: profile?.displaySymbol ?? GestureProfile.defaultSymbol)
                        .font(.title2)
                        .foregroundStyle(profile?.tint ?? Theme.accent)
                        .frame(width: 52, height: 52)
                        .background((profile?.tint ?? Theme.accent).opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.profileName(id: profileID)).font(.title3.weight(.semibold))
                        Label(host.displayName, systemImage: host.type.symbol).font(.subheadline).foregroundStyle(.secondary)
                        if let description = profile?.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                ProfileSwitcher(host: host, current: profileID)
            } else {
                Text("No host is active. Pair a phone, computer or TV on the Pair tab.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Gestures go to")
        } footer: {
            if !status.supportsProfiles {
                Text("This firmware has the four fixed modes. Update it on the Firmware tab for your own profiles.")
            }
        }
    }

    // MARK: band

    private func bandSection(_ status: DongleStatus) -> some View {
        Section {
            let band = status.band
            HStack {
                Circle().fill(BandState.color(band?.state)).frame(width: 10, height: 10)
                Text(band.map { BandState.describe($0.state) } ?? "—").font(.headline)
                Spacer()
                if let battery = band?.battery {
                    Label("\(battery)%", systemImage: band?.charging == true ? "battery.100.bolt" : "battery.75")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(battery <= 15 && band?.charging != true ? Theme.danger : .primary)
                }
            }
            if let millivolts = band?.millivolts, let milliamps = band?.milliamps {
                // The band's own reading: negative current is charging.
                InfoRow(label: "Band power", value: String(format: "%.2f V · %@", Double(millivolts) / 1000,
                                                           milliamps < 0 ? "charging at \(-milliamps) mA" : "drawing \(milliamps) mA"))
            }
            if let hand = band?.hand { InfoRow(label: "Hand", value: hand.capitalized) }
        } header: {
            Text("Band")
        }
    }

    // MARK: hosts

    private func hostsSection(_ status: DongleStatus) -> some View {
        Section {
            if status.hosts.isEmpty { Text("No hosts connected").foregroundStyle(.secondary) }
            ForEach(status.hosts) { host in
                Button { link.send(.target(host.handle)) } label: {
                    HostRow(host: host, isYou: host.handle == status.you,
                            profileName: model.profileName(id: host.profile ?? (host.active ? status.mode : nil)),
                            showsProfile: host.profile != nil || host.active)
                }
                .buttonStyle(.plain)
                .contextMenu { hostMenu(host, status: status) }
                .listRowBackground(host.active ? Theme.accent.opacity(0.16) : nil)
                .swipeActions {
                    Button("Forget") { forgetting = host }.tint(Theme.danger)
                    Button("Rename") { newName = host.name; renaming = host }.tint(Theme.accent)
                }
            }
            if status.hosts.count > 1 {
                Button { link.send(.targetNext) } label: { Label("Next host", systemImage: "arrow.right.circle") }
            }
        } header: {
            Text("Hosts (\(status.hosts.count) of 5)")
        } footer: {
            Text("Tap a host to send gestures to it. Swipe to rename or forget it; touch and hold to set its profile or what kind of device it is (Windows and Linux get Ctrl where a Mac gets ⌘). On the band: pinch, hold and let go (two buzzes), then write p or l for the previous or next host.")
        }
    }

    @ViewBuilder
    private func hostMenu(_ host: DongleStatus.Host, status: DongleStatus) -> some View {
        if status.supportsProfiles {
            let profiles = model.switchableProfiles.filter { $0.allows(host.type) }
            Picker("Profile", selection: Binding(get: { host.profile ?? "" }, set: { model.switchProfile($0, host: host.handle) })) {
                ForEach(profiles, id: \.uid) { profile in
                    Label(profile.name, systemImage: profile.displaySymbol).tag(profile.id)
                }
            }
        }
        if host.type.hasKeyboard {
            Picker("Device type", selection: Binding(get: { host.type }, set: { link.send(.hostType(host.handle, $0)) })) {
                ForEach(DongleCommand.HostType.allCases.filter(\.hasKeyboard), id: \.self) { type in
                    Label(type.label, systemImage: type.symbol).tag(type)
                }
            }
        }
    }
}

/// How to switch on the band itself: what opens the letter menu, each letter and what it does,
/// and what every gesture does in the active profile.
struct OnTheBandSection: View {
    @Environment(DongleModel.self) private var model
    let host: DongleStatus.Host
    let profileID: String

    var body: some View {
        let set = model.dongleSet
        let profile = model.profile(id: profileID)
        Section {
            if let set {
                let openers = Self.gestures(in: profile, for: host.type).filter { $0.action == "menu" }.map(\.gesture.title)
                Label {
                    Text(openers.isEmpty
                         ? "Nothing in \(model.profileName(id: profileID)) opens the letter menu. Switch profile here, or bind a gesture to Letter menu."
                         : "\(openers.joined(separator: " or ")), let go without turning. After two buzzes, write one letter on any surface within 6 s.")
                } icon: {
                    Image(systemName: "hand.pinch").foregroundStyle(Theme.accent)
                }
                .font(.callout)
                ForEach(Self.letters(set), id: \.self) { letter in
                    letterRow(letter, action: set.menu[letter] ?? "none", set: set)
                }
            } else {
                Text("The dongle runs a profile set this iPhone doesn't have. Send yours from the Profiles tab to see its letters here.")
                    .foregroundStyle(.secondary)
            }
            if let profile {
                DisclosureGroup("Gestures in \(profile.name)") {
                    ForEach(Self.gestures(in: profile, for: host.type), id: \.gesture) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.gesture.title).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(ActionKind.summary(item.action, profileName: model.profileName(id:))).multilineTextAlignment(.trailing)
                        }
                        .font(.callout)
                    }
                }
            }
        } header: {
            Text("On the band")
        } footer: {
            Text("A letter that isn't listed gets one long buzz. The band mixes up l, i, 1 and |, so they all count as l. Change the letters in Profiles › Letter menu.")
        }
    }

    private func letterRow(_ letter: String, action: String, set: GestureProfileSet) -> some View {
        let target = action.hasPrefix("profile:") ? set.profile(id: String(action.dropFirst("profile:".count))) : nil
        let usable = target?.allows(host.type) ?? true
        return HStack(spacing: 12) {
            Text(letter)
                .font(.title3.weight(.bold).monospaced())
                .frame(width: 38, height: 38)
                .background(Theme.accent.opacity(usable ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(target?.name ?? ActionKind.summary(action, profileName: model.profileName(id:)))
                if let target {
                    Text(usable ? "\(target.buzz ?? 1) buzz\(target.buzz ?? 1 == 1 ? "" : "es") when you land" : "Not for this \(host.type.label.lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if target?.id == profileID { Image(systemName: "checkmark").foregroundStyle(Theme.mint) }
        }
        .opacity(usable ? 1 : 0.5)
    }

    /// Profile letters in profile order, then the rest alphabetically.
    static func letters(_ set: GestureProfileSet) -> [String] {
        let order = Dictionary(set.profiles.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        func rank(_ letter: String) -> Int {
            guard let action = set.menu[letter], action.hasPrefix("profile:") else { return Int.max }
            return order[String(action.dropFirst("profile:".count))] ?? Int.max - 1
        }
        return set.menu.keys.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    static func gestures(in profile: GestureProfile?, for type: DongleCommand.HostType) -> [(gesture: ProfileGesture, action: String)] {
        guard let profile else { return [] }
        return ProfileGesture.allCases.compactMap { gesture in
            guard let action = profile.gestures[gesture.rawValue]?.action(for: type), action != "none" else { return nil }
            return (gesture, action)
        }
    }
}

/// Picks the active host's profile: a menu of the profiles it may use, and previous / next.
struct ProfileSwitcher: View {
    @Environment(DongleModel.self) private var model
    let host: DongleStatus.Host
    let current: String

    private var supportsProfiles: Bool { model.status?.supportsProfiles == true }

    var body: some View {
        let profiles = model.switchableProfiles.filter { $0.allows(host.type) }
        HStack(spacing: 10) {
            Button { model.link.send(.profilePrevious) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }
                .buttonStyle(.bordered)
                .disabled(!supportsProfiles || profiles.count < 2)
            Menu {
                ForEach(profiles, id: \.uid) { profile in
                    Button { select(profile.id) } label: {
                        Label(profile.name, systemImage: profile.id == current ? "checkmark" : profile.displaySymbol)
                    }
                }
            } label: {
                Label("Switch profile", systemImage: "rectangle.stack").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button { model.link.send(.profileNext) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 28) }
                .buttonStyle(.bordered)
                .disabled(!supportsProfiles || profiles.count < 2)
        }
        .labelStyle(.titleAndIcon)
    }

    private func select(_ id: String) {
        if supportsProfiles {
            model.switchProfile(id)
        } else if let mode = DongleCommand.Mode(rawValue: id) {
            // Older firmware: the built-in profiles were its modes.
            model.link.send(.mode(mode))
        }
    }
}

struct HostRow: View {
    let host: DongleStatus.Host
    let isYou: Bool
    var profileName: String
    var showsProfile: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: host.type.symbol)
                .font(.title3).foregroundStyle(host.active ? Theme.accent : .secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(host.displayName).font(.headline)
                    if isYou { Text("THIS IPHONE").badgeStyle(Theme.mint) }
                }
                Text(showsProfile ? "\(host.type.label) · \(profileName)" : host.type.caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if host.active { Text("ACTIVE").badgeStyle(Theme.accent) }
        }
        .contentShape(Rectangle())
    }
}

/// The link: its state, the device, and what to do when it fails.
struct ConnectionSection: View {
    @Environment(DongleModel.self) private var model

    private var link: DongleLink { model.link }

    private var stateColor: Color {
        switch link.state {
        case .ready: Theme.mint
        case .failed, .bluetooth: Theme.danger
        case .idle: .gray
        default: Theme.accent
        }
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                Text(link.state.title).font(.headline)
                Spacer()
                if [.searching, .connecting, .discovering].contains(link.state) { ProgressView().controlSize(.small) }
                if let status = link.status, link.isReady { Text(status.firmware).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            if let name = link.peripheralName { InfoRow(label: "Device", value: name) }
            if case .failed(let message) = link.state {
                Text(message).font(.callout).foregroundStyle(link.needsPairing ? Theme.warn : Theme.danger)
                Button("Try again") { link.reconnect() }
            }
            if link.state == .searching {
                Text("Make sure the dongle is powered and paired with this iPhone (Settings › Bluetooth › “\(DongleGATT.advertisedName)”).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = link.commandError { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
        } header: {
            Text("Connection")
        }
    }
}
