import BandKit
import BandLogging
import SwiftUI
import UIKit

@main
struct NeuralPlaygroundApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.band)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(BandClient.self) private var band
    @Environment(\.scenePhase) private var scenePhase

    @ViewBuilder private var playgroundRoot: some View {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "NPScreen") == "signals" { SignalsView() } else { PlaygroundView() }
        #else
        PlaygroundView()
        #endif
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            NavigationStack { BandConnectionView() }
                .tabItem { Label("Band", systemImage: "wave.3.right.circle") }
                .tag(AppModel.Tab.band)
            NavigationStack { playgroundRoot }
                .tabItem { Label("Playground", systemImage: "hand.tap") }
                .tag(AppModel.Tab.playground)
            NavigationStack { GamesView() }
                .tabItem { Label("Games", systemImage: "gamecontroller") }
                .tag(AppModel.Tab.games)
            NavigationStack { CredentialsView() }
                .tabItem { Label("Credentials", systemImage: "key.horizontal") }
                .tag(AppModel.Tab.credentials)
            NavigationStack { DiagnosticsView() }
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(AppModel.Tab.diagnostics)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { ExtrasPause.run(band) }
        }
        .sheet(isPresented: Binding(get: { band.claimJustCompleted }, set: { band.claimJustCompleted = $0 })) {
            BackupPromptView()
        }
    }
}

/// Leaving the app switches the band's battery-hungry extras off (see `BandClient.pauseExtras`),
/// with a little background time so the band can confirm and the handwriting settings are restored.
@MainActor
enum ExtrasPause {
    private final class Token { var id = UIBackgroundTaskIdentifier.invalid }

    static func run(_ band: BandClient) {
        guard band.pauseExtras() else { return }
        let token = Token()
        func end() {
            guard token.id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(token.id)
            token.id = .invalid
        }
        token.id = UIApplication.shared.beginBackgroundTask(withName: "band-extras-off") { end() }
        Task { @MainActor in
            for _ in 0..<100 where band.extrasStopping { try? await Task.sleep(for: .milliseconds(200)) }
            end()
        }
    }
}
