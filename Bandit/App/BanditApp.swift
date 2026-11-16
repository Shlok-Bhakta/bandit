import DongleProtocol
import SwiftUI

@main
struct BanditApp: App {
    @State private var model = DongleModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onOpenURL { url in model.open(url) }
        }
    }
}

struct RootView: View {
    @Environment(DongleModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Appearance.accentKey) private var accent = ""

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            NavigationStack { HomeView() }
                .tabItem { Label("Dongle", systemImage: "dot.radiowaves.left.and.right") }
                .tag(DongleModel.Tab.home)
            NavigationStack { profilesRoot }
                .safeAreaInset(edge: .bottom, spacing: 0) { SyncBar() }
                .tabItem { Label("Profiles", systemImage: "hand.raised.fingers.spread") }
                .badge(model.unsentChanges.count)
                .tag(DongleModel.Tab.profiles)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .badge(model.updater.updateAvailable ? 1 : 0)
                .tag(DongleModel.Tab.settings)
        }
        // A new accent redraws everything (Theme.accent is read as views draw).
        .id(accent)
        .tint(Theme.accent)
        .overlay(alignment: .top) { ToastView(toast: model.toast) }
        .onAppear { model.link.setActive(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in
            model.link.setActive(phase == .active)
            if phase == .active { model.becameActive() }
            if phase == .background { model.store.save() }
        }
        .sheet(item: $model.pendingImport) { candidate in
            NavigationStack { ImportReviewView(candidate: candidate) }
        }
        .sheet(item: $model.pendingMerge) { request in
            NavigationStack { MergeView(request: request) { model.pendingMerge = nil } }
                .interactiveDismissDisabled()
        }
        .sheet(item: $model.sheet) { sheet in
            NavigationStack {
                Group {
                    switch sheet {
                    case .pairing: PairingView()
                    case .firmware: FirmwareView()
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.sheet = nil } } }
            }
        }
    }
    /// Direct routes for simulator layout checks, alongside the existing -NPTab launch option.
    @ViewBuilder private var profilesRoot: some View {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "NPScreen") {
        case "buzzes": BuzzesView()
        case "designer": BuzzDesignerView(name: "rise", initial: model.store.set.patternText("rise"))
        case "feedback": FeedbackView()
        case "lab": GestureLabView()
        case "editor":
            if let profile = model.store.set.profiles.first { ProfileEditorView(uid: profile.uid) }
        case "band":
            if let profile = model.store.set.profiles.first { BandEventsView(target: .profile(profile.uid)) }
        case "everywhere": EverywhereView()
        case "changes": ChangesView()
        case "merge":
            let other: GestureProfileSet = {
                var set = GestureProfileSet.builtin
                set.profiles[0].name = "Media+"
                set.menu["z"] = "media:mute"
                set.profiles.append(GestureProfile(id: "zoom", name: "Zoom", symbol: "video"))
                return set
            }()
            MergeView(request: .init(merge: ProfileMerge(base: .builtin, phone: model.store.set, other: other), source: "The dongle", dongleHash: "deadbeef")) {}
        default: ProfilesView()
        }
        #else
        ProfilesView()
        #endif
    }

}

/// The note that drops in from the top for a moment.
struct ToastView: View {
    let toast: DongleModel.Toast?

    var body: some View {
        ZStack {
            if let toast {
                Label {
                    Text(toast.text).font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: toast.symbol).foregroundStyle(toast.tint).symbolEffect(.bounce, value: toast.id)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(toast.tint.opacity(0.4), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: toast?.id)
        .padding(.top, 4)
        .allowsHitTesting(false)
    }
}
