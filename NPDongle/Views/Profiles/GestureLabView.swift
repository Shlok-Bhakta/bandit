import DongleProtocol
import SwiftUI

struct GestureLabView: View {
    @Environment(DongleModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var bindingName: String?
    @State private var route: LabBindingRoute?
    @State private var started = false
    @State private var renewAt = Date.distantPast
    private let heartbeat = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    struct LabBindingRoute: Identifiable {
        let id = UUID()
        let uid: UUID
        let gesture: ProfileGesture
    }
    private var records: [GestureLabRecord] { model.link.logLines.compactMap(GestureLabRecord.parse) }
    private var messages: [(key: String, finger: String, action: String, derived: String, count: Int)] {
        var rows: [(key: String, finger: String, action: String, derived: String, count: Int)] = []
        for record in records.reversed() {
            guard case .message(_, let finger, let action, let derived) = record else { continue }
            let key = "\(finger) \(action) \(derived)"
            if let index = rows.firstIndex(where: { $0.key == key }) { rows[index].count += 1 }
            else { rows.append((key, finger, action, derived, 1)) }
        }
        return rows
    }
    var body: some View {
        List {
            Section {
                FirmwareFeatureNote()
                Label(model.link.isReady ? "Listening to your band" : "Connect a dongle to begin", systemImage: model.link.isReady ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(model.link.isReady ? Theme.mint : .secondary)
                Text("Tap, swipe, pinch and flick. Watch what the band calls each movement, then bind an event to try it.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Last gesture") {
                if let last = messages.first {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "hand.wave.fill").font(.largeTitle).foregroundStyle(Theme.mint)
                        Text(last.finger.capitalized).font(.title.bold())
                        Text(last.action).font(.title2.weight(.semibold))
                        Text(last.derived).font(.body.monospaced()).foregroundStyle(.secondary)
                        names(last.finger, last.action, last.derived)
                    }.padding(.vertical, 12)
                } else { ContentUnavailableView("Try a gesture", systemImage: "hand.wave", description: Text("Your band's messages will appear here.")) }
            }
            Section("Seen in the log") {
                ForEach(messages, id: \.key) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(row.finger.capitalized + " · " + row.action).font(.headline); Spacer(); Text("×\(row.count)").monospacedDigit().foregroundStyle(Theme.mint) }
                        Text(row.derived).font(.caption.monospaced()).foregroundStyle(.secondary)
                        names(row.finger, row.action, row.derived)
                    }.padding(.vertical, 4)
                }
            }
            Section("Wrist motion") {
                ForEach(Array(records.filter { if case .motion = $0 { return true }; return false }.suffix(30).reversed().enumerated()), id: \.offset) { _, record in
                    if case .motion(let flick, let direction, let peak) = record {
                        Label("\(flick ? "Flick" : "Below threshold") \(direction) · \(peak)", systemImage: flick ? "bolt.fill" : "waveform.path").font(.callout).foregroundStyle(flick ? Theme.mint : .secondary)
                    }
                }
            }
            Section {
                DisclosureGroup("Bindings that fired") {
                    ForEach(Array(records.suffix(100).reversed().enumerated()), id: \.offset) { _, record in
                        if case .fired(let gesture, let profile, let action) = record { Text("\(gesture) in \(profile)\n\(action)").font(.caption.monospaced()) }
                    }
                }
                DisclosureGroup("Raw message fields") {
                    ForEach(Array(records.suffix(100).reversed().enumerated()), id: \.offset) { _, record in
                        if case .fields(let dump) = record { Text(dump).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
            } footer: { Text("Counts cover the dongle log currently held by the app. Raw fields can reveal pressure or other undocumented values. Named gesture matches are hints; the fired bindings above confirm what ran.") }
        }
        .darkList().navigationTitle("Gesture lab")
        .onAppear { started = true; refresh(force: true) }
        .onDisappear { started = false; model.link.send(.lab(false)) }
        .onChange(of: model.link.isReady) { _, _ in refresh(force: true) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh(force: true) } else { model.link.send(.lab(false)) } }
        .onReceive(heartbeat) { _ in refresh() }
        .confirmationDialog("Bind \(bindingName ?? "event") in…", isPresented: Binding(get: { bindingName != nil }, set: { if !$0 { bindingName = nil } }), titleVisibility: .visible) {
            ForEach(model.store.set.profiles, id: \.uid) { profile in
                Button(profile.name) { if let name = bindingName, let gesture = ProfileGesture(rawValue: name) { route = .init(uid: profile.uid, gesture: gesture) }; bindingName = nil }
            }
        }
        .sheet(item: $route) { route in NavigationStack { BindingEditorView(uid: route.uid, gesture: route.gesture).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.route = nil } } } } }
    }
    private func refresh(force: Bool = false) {
        guard started, model.link.isReady, scenePhase == .active else { return }
        if force || Date() >= renewAt { model.link.send(.lab(true)); renewAt = Date().addingTimeInterval(300) }
    }
    private func names(_ finger: String, _ action: String, _ derived: String) -> some View {
        let names = GestureLabRecord.bandNames(finger: finger, action: action, derived: derived)
        let named = GestureLabRecord.namedGestures(finger: finger, action: action, derived: derived)
        return VStack(alignment: .leading, spacing: 6) {
            if !named.isEmpty { Text("Named: " + named.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.mint) }
            ForEach(names, id: \.self) { name in
                HStack { Text(name).font(.caption.monospaced()); Spacer(); Button("Bind…") { bindingName = name }.buttonStyle(.borderless) }
            }
        }
    }
}
