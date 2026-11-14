import DongleProtocol
import SwiftUI

@main
struct NPDongleApp: App {
    @State private var model = DongleModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { url in model.open(url) }
        }
    }
}

struct RootView: View {
    @Environment(DongleModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            NavigationStack { HomeView() }
                .tabItem { Label("Dongle", systemImage: "cable.connector") }
                .tag(DongleModel.Tab.home)
            NavigationStack { profilesRoot }
                .tabItem { Label("Profiles", systemImage: "hand.raised.fingers.spread") }
                .tag(DongleModel.Tab.profiles)
            NavigationStack { PairingView() }
                .tabItem { Label("Pair", systemImage: "link.badge.plus") }
                .tag(DongleModel.Tab.pair)
            NavigationStack { FirmwareView() }
                .tabItem { Label("Firmware", systemImage: "cpu") }
                .badge(model.updater.updateAvailable ? 1 : 0)
                .tag(DongleModel.Tab.firmware)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(DongleModel.Tab.settings)
        }
        .onAppear { model.link.setActive(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in
            model.link.setActive(phase == .active)
            if phase == .active { model.becameActive() }
            if phase == .background { model.store.save() }
        }
        .sheet(item: $model.pendingImport) { candidate in
            NavigationStack { ImportReviewView(candidate: candidate) }
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
            if let profile = model.store.set.profiles.first { BandEventsView(uid: profile.uid) }
        default: ProfilesView()
        }
        #else
        ProfilesView()
        #endif
    }

}
