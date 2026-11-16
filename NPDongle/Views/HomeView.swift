import DongleProtocol
import SwiftUI

/// The dongle at a glance: the profile gestures go to (swipe the card for the next), the other
/// profiles to switch to, the devices, and a cheat sheet for the band.
struct HomeView: View {
    @Environment(DongleModel.self) private var model
    @State private var renaming: DongleStatus.Host?
    @State private var newName = ""
    @State private var forgetting: DongleStatus.Host?

    private var link: DongleLink { model.link }
    private var status: DongleStatus? { link.status }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let status, link.isReady {
                    if model.updater.updateAvailable, let release = model.updater.release { updateBanner(release) }
                    HeroCard(status: status)
                    if let host = status.activeHost {
                        ProfileCarousel(host: host, current: host.profile ?? status.mode)
                    }
                    devices(status)
                    if status.supportsProfiles, let host = status.activeHost {
                        OnTheBandCard(host: host, profileID: host.profile ?? status.mode)
                    }
                } else {
                    ConnectingCard()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .screenBackground()
        .navigationTitle("NP Dongle")
        .refreshable { link.readStatus() }
        .alert("Rename device", isPresented: renamingShown, presenting: renaming) { host in
            TextField("Name", text: $newName)
            Button("Rename") { link.send(.name(host.handle, newName)) }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { host in
            Text("The dongle shows this name for host \(host.handle).")
        }
        .confirmationDialog("Forget \(forgetting?.displayName ?? "this device")?", isPresented: forgettingShown,
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

    private func updateBanner(_ release: DongleRelease) -> some View {
        Button { model.sheet = .firmware } label: {
            HStack(spacing: 12) {
                SymbolTile(symbol: "arrow.down.circle.fill", tint: Theme.mint, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Firmware \(release.version) is ready").font(.subheadline.weight(.semibold))
                    Text("Install it over Bluetooth in a minute or two").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Theme.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.mint.opacity(0.35)))
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: devices

    private func devices(_ status: DongleStatus) -> some View {
        Card(title: "Devices · \(status.hosts.count) of 5", systemImage: "laptopcomputer.and.iphone") {
            if status.hosts.isEmpty {
                Text("Nothing is paired yet. Add your Mac, phone or TV to send it gestures.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(status.hosts) { host in
                HStack(spacing: 0) {
                    Button { link.send(.target(host.handle)) } label: {
                        HostRow(host: host, isYou: host.handle == status.you,
                                profileName: model.profileName(id: host.profile ?? (host.active ? status.mode : nil)),
                                showsProfile: host.profile != nil || host.active)
                    }
                    .buttonStyle(PressableStyle())
                    .sensoryFeedback(.selection, trigger: host.active)
                    Menu { hostMenu(host, status: status) } label: {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(10)
                .background((host.active ? Theme.accent : .white).opacity(host.active ? 0.16 : 0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(host.active ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1))
                .contextMenu { hostMenu(host, status: status) }
                .animation(.snappy, value: host.active)
            }
            Button { model.sheet = .pairing } label: {
                Label("Add a device", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(status.hosts.count >= 5)
            Text(status.hosts.count >= 5 ? "Five is the most the dongle takes: forget one first." : "Tap a device to send it gestures. On the band: open the letter menu and write p or l for the previous or next one.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func hostMenu(_ host: DongleStatus.Host, status: DongleStatus) -> some View {
        if status.supportsProfiles {
            let profiles = model.switchableProfiles.filter { $0.allows(host.type) }
            Picker(selection: Binding(get: { host.profile ?? "" }, set: { model.switchProfile($0, host: host.handle) })) {
                ForEach(profiles, id: \.uid) { profile in
                    Label(profile.name, systemImage: profile.displaySymbol).tag(profile.id)
                }
            } label: { Label("Profile", systemImage: "rectangle.stack") }
            .pickerStyle(.menu)
        }
        if host.type.hasKeyboard {
            Picker(selection: Binding(get: { host.type }, set: { link.send(.hostType(host.handle, $0)) })) {
                ForEach(DongleCommand.HostType.allCases.filter(\.hasKeyboard), id: \.self) { type in
                    Label(type.label, systemImage: type.symbol).tag(type)
                }
            } label: { Label("Kind of device", systemImage: "desktopcomputer") }
            .pickerStyle(.menu)
        }
        Button { newName = host.name; renaming = host } label: { Label("Rename", systemImage: "pencil") }
        Button(role: .destructive) { forgetting = host } label: { Label("Forget", systemImage: "trash") }
    }
}

/// The active device's profile, big: swipe it sideways for the previous or next profile.
struct HeroCard: View {
    @Environment(DongleModel.self) private var model
    @AppStorage(Appearance.glowKey) private var profileGlow = true
    let status: DongleStatus
    @State private var drag: CGFloat = 0
    @State private var swiped = 0

    var body: some View {
        let host = status.activeHost
        let profileID = host?.profile ?? status.mode
        let profile = model.profile(id: profileID)
        let tint = profileGlow ? profile?.tint ?? Theme.accent : Theme.accent
        GlowCard(tint: tint) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    LiveDot(color: BandState.color(status.band?.state), live: status.band?.state == "live")
                    Text(status.band.map { BandState.describe($0.state) } ?? "No band").font(.caption.weight(.semibold))
                    Spacer()
                    if let battery = status.band?.battery { BatteryPill(percent: battery, charging: status.band?.charging == true) }
                }
                if let host {
                    HStack(alignment: .center, spacing: 16) {
                        SymbolTile(symbol: profile?.displaySymbol ?? GestureProfile.defaultSymbol, tint: tint, size: 66)
                            .symbolEffect(.bounce, value: profileID)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.profileName(id: profileID))
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .lineLimit(1).minimumScaleFactor(0.6)
                                .contentTransition(.opacity)
                            Label("on \(host.displayName)", systemImage: host.type.symbol)
                                .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .offset(x: drag)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: profileID)
                    if let description = profile?.description, !description.isEmpty {
                        Text(description).font(.callout).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    }
                    if status.supportsProfiles {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                            Text("Swipe for another profile")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No device yet").font(.system(.title, design: .rounded, weight: .bold))
                        Text("Pair your Mac, phone or TV, and gestures go to it.").font(.callout).foregroundStyle(.white.opacity(0.7))
                        Button { model.sheet = .pairing } label: { Label("Add a device", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).padding(.top, 4)
                    }
                }
            }
            .padding(20)
        }
        .contentShape(Rectangle())
        .gesture(status.supportsProfiles && host != nil ? swipe : nil)
        .sensoryFeedback(.impact(weight: .medium), trigger: swiped)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Next profile") { model.link.send(.profileNext) }
        .accessibilityAction(named: "Previous profile") { model.link.send(.profilePrevious) }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = value.translation.width / 3
            }
            .onEnded { value in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { drag = 0 }
                guard abs(value.translation.width) > 70, abs(value.translation.width) > abs(value.translation.height) else { return }
                model.link.send(value.translation.width < 0 ? .profileNext : .profilePrevious)
                swiped += 1
            }
    }
}

/// A dot that breathes while the band is live.
struct LiveDot: View {
    let color: Color
    var live = true
    @State private var pulse = false

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .background(Circle().fill(color.opacity(0.5)).scaleEffect(pulse ? 2.6 : 1).opacity(pulse ? 0 : 0.8))
            .onAppear { if live { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true } } }
    }
}

struct BatteryPill: View {
    let percent: Int
    let charging: Bool

    var body: some View {
        let low = percent <= 15 && !charging
        HStack(spacing: 4) {
            Image(systemName: charging ? "battery.100.bolt" : percent > 60 ? "battery.100" : percent > 25 ? "battery.50" : "battery.25")
            Text("\(percent)%").monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(low ? Theme.danger : .white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.white.opacity(0.12), in: Capsule())
        .accessibilityLabel("Band battery \(percent) percent\(charging ? ", charging" : "")")
    }
}

/// The profiles the active device may use, to tap.
struct ProfileCarousel: View {
    @Environment(DongleModel.self) private var model
    let host: DongleStatus.Host
    let current: String

    private var supportsProfiles: Bool { model.status?.supportsProfiles == true }

    var body: some View {
        let profiles = model.switchableProfiles.filter { $0.allows(host.type) }
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(profiles, id: \.uid) { profile in
                        let selected = profile.id == current
                        Button { select(profile) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                SymbolTile(symbol: profile.displaySymbol, tint: profile.tint, size: 34)
                                Text(profile.name).font(.footnote.weight(.semibold)).lineLimit(1)
                            }
                            .frame(width: 96, alignment: .leading)
                            .padding(12)
                            .background((selected ? profile.tint : .white).opacity(selected ? 0.2 : 0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(selected ? profile.tint : .white.opacity(0.06), lineWidth: selected ? 1.5 : 1))
                        }
                        .buttonStyle(PressableStyle())
                        .id(profile.id)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 2)
            }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
        .sensoryFeedback(.selection, trigger: current)
    }

    private func select(_ profile: GestureProfile) {
        if supportsProfiles {
            model.switchProfile(profile.id)
        } else if let mode = DongleCommand.Mode(rawValue: profile.id) {
            // Older firmware: the built-in profiles were its modes.
            model.link.send(.mode(mode))
        }
    }
}

/// How to drive it from the band: the letter menu's letters and every gesture in the profile.
struct OnTheBandCard: View {
    @Environment(DongleModel.self) private var model
    let host: DongleStatus.Host
    let profileID: String
    @State private var showsGestures = false

    var body: some View {
        let set = model.dongleSet
        let profile = model.profile(id: profileID)
        Card(title: "On the band", systemImage: "hand.pinch") {
            if let set {
                let openers = Self.gestures(in: profile, of: set, for: host.type).filter { $0.action == "menu" }.map(\.gesture.title)
                Text(openers.isEmpty
                     ? "Nothing in \(model.profileName(id: profileID)) opens the letter menu. Bind a gesture to Letter menu to switch from the band."
                     : "\(openers.joined(separator: " or ")), let go without turning. After two buzzes, write a letter on any surface:")
                    .font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(Self.letters(set), id: \.self) { letter in
                        letterTile(letter, action: set.menu[letter] ?? "none", set: set)
                    }
                }
                if let profile {
                    DisclosureGroup(isExpanded: $showsGestures) {
                        VStack(spacing: 8) {
                            ForEach(Self.gestures(in: profile, of: set, for: host.type), id: \.gesture) { item in
                                HStack(spacing: 10) {
                                    Image(systemName: item.gesture.symbol).foregroundStyle(item.gesture.tint).frame(width: 22)
                                    Text(item.gesture.title).foregroundStyle(.secondary)
                                    Spacer(minLength: 12)
                                    Text(ActionKind.summary(item.action, profileName: model.profileName(id:))).multilineTextAlignment(.trailing)
                                }
                                .font(.callout)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Every gesture in \(profile.name)").font(.callout.weight(.semibold))
                    }
                }
            } else {
                Text("The dongle runs a profile set this iPhone doesn't have yet. Get it on the Profiles tab to see its letters here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func letterTile(_ letter: String, action: String, set: GestureProfileSet) -> some View {
        let target = action.hasPrefix("profile:") ? set.profile(id: String(action.dropFirst("profile:".count))) : nil
        let usable = target?.allows(host.type) ?? true
        let tint = target?.tint ?? Theme.accent
        return HStack(spacing: 10) {
            Text(letter)
                .font(.title3.weight(.heavy).monospaced())
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(target?.name ?? ActionKind.summary(action, profileName: model.profileName(id:))).font(.footnote.weight(.semibold)).lineLimit(2)
                if target != nil, !usable { Text("Not for this \(host.type.label.lowercased())").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if target?.id == profileID { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint) }
        }
        .padding(8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    /// What each gesture does in `profile` on `type`, the set's `everywhere` bindings included.
    static func gestures(in profile: GestureProfile?, of set: GestureProfileSet?, for type: DongleCommand.HostType) -> [(gesture: ProfileGesture, action: String)] {
        guard let profile else { return [] }
        let set = set ?? GestureProfileSet(profiles: [profile])
        return ProfileGesture.allCases.compactMap { gesture in
            set.action(gesture, in: profile, for: type).map { (gesture, $0) }
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
            SymbolTile(symbol: host.type.symbol, tint: host.active ? Theme.accent : Color(white: 0.3), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(host.displayName).font(.headline).lineLimit(1)
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

/// Before the dongle is connected: what the link is doing, and what to try.
struct ConnectingCard: View {
    @Environment(DongleModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ripple = false

    private var link: DongleLink { model.link }
    private var failed: Bool {
        switch link.state {
        case .failed, .bluetooth: true
        default: false
        }
    }
    private var tint: Color { failed ? Theme.danger : Theme.accent }

    var body: some View {
        GlowCard(tint: tint) {
            VStack(spacing: 18) {
                ZStack {
                    ForEach(0..<3) { ring in
                        Circle()
                            .stroke(tint.opacity(0.5), lineWidth: 1.5)
                            .scaleEffect(ripple ? 2.4 : 0.8)
                            .opacity(ripple ? 0 : 0.9)
                            .animation(reduceMotion || failed ? nil : .easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(ring) * 0.8), value: ripple)
                    }
                    SymbolTile(symbol: failed ? "cable.connector.slash" : "dot.radiowaves.left.and.right", tint: tint, size: 72)
                        .symbolEffect(.variableColor.iterative, isActive: !failed && !reduceMotion)
                }
                .frame(height: 160)
                .onAppear { ripple = true }
                VStack(spacing: 6) {
                    Text(link.isReady ? "Reading the dongle…" : link.state.title)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    if let name = link.peripheralName { Text(name).font(.subheadline).foregroundStyle(.white.opacity(0.7)) }
                    if case .failed(let message) = link.state {
                        Text(message).font(.callout).foregroundStyle(link.needsPairing ? Theme.warn : Theme.danger).multilineTextAlignment(.center)
                    } else if link.state == .searching {
                        Text("Make sure the dongle is powered and paired with this iPhone (Settings › Bluetooth › “\(DongleGATT.advertisedName)”).")
                            .font(.callout).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    }
                    if let error = link.commandError { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                }
                if failed {
                    Button { link.reconnect() } label: { Label("Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(tint)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }
}
