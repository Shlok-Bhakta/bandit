import DongleProtocol
import SwiftUI

struct FirmwareFeatureNote: View {
    @Environment(DongleModel.self) private var model
    private var supported: Bool {
        guard let version = model.status?.firmware else { return false }
        return version.compare("0.15.0", options: .numeric) != .orderedAscending && version.first?.isNumber == true
    }
    var body: some View {
        Label(supported ? "Firmware supports flicks, band events and buzz patterns." : "Flicks, band events, buzz patterns and lab need firmware 0.15.0. Connected: \(model.status?.firmware ?? "no dongle").", systemImage: supported ? "checkmark.circle" : "info.circle")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct BuzzTimeline: View {
    let text: String
    var body: some View {
        if let pattern = try? ProfileFormat.parsePattern(text) {
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.08))
                    ForEach(Array(pattern.pulses.enumerated()), id: \.offset) { _, pulse in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.accent)
                            .frame(width: max(2, geometry.size.width * Double(pulse.ms) / Double(pattern.duration)), height: max(3, geometry.size.height * Double(pulse.strength) / 100))
                            .offset(x: geometry.size.width * Double(pulse.atMS) / Double(pattern.duration))
                    }
                }
            }
            .frame(height: 34)
            .accessibilityLabel("\(pattern.pulses.count) pulses, \(pattern.duration) milliseconds")
        }
    }
}

struct BuzzPlayButton: View {
    @Environment(DongleModel.self) private var model
    let text: String
    var body: some View {
        Button { model.link.send(.buzzTry(text)) } label: { Label("Play", systemImage: "play.fill") }
            .buttonStyle(.borderless)
            .disabled(!model.link.isReady || (try? ProfileFormat.parsePattern(text)) == nil)
            .accessibilityHint("Plays this pattern on the connected band")
    }
}

struct BuzzesView: View {
    @Environment(DongleModel.self) private var model
    var body: some View {
        List {
            Section { FirmwareFeatureNote() }
            Section {
                NavigationLink { BuzzDesignerView(name: "", initial: "60*70") } label: { Label("Create pattern", systemImage: "plus.circle") }
                    .disabled(model.store.set.buzzes.count >= 16)
            }
            Section("Your patterns") {
                if model.store.set.buzzes.isEmpty { Text("Create a buzz, or customize one below. Preview it on your band as you edit.").foregroundStyle(.secondary) }
                ForEach(model.store.set.buzzes.keys.sorted(), id: \.self) { name in row(name) }
            }
            Section("Built-in patterns") {
                ForEach(ProfileFormat.builtinBuzzes.map(\.name).filter { model.store.set.buzzes[$0] == nil }, id: \.self) { name in row(name) }
            }
        }
        .darkList().navigationTitle("Buzzes")
    }
    private func row(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                NavigationLink { BuzzDesignerView(name: name, initial: model.store.set.patternText(name)) } label: { Text(name).font(.headline) }
                BuzzPlayButton(text: model.store.set.patternText(name))
            }
            BuzzTimeline(text: model.store.set.patternText(name))
            Text(model.store.set.patternText(name)).font(.caption.monospaced()).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

struct BuzzDesignerView: View {
    @Environment(DongleModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    @State var text: String
    private let originalName: String
    @State private var duplicate = false
    init(name: String, initial: String) {
        _name = State(initialValue: name)
        _text = State(initialValue: initial)
        originalName = name
    }
    private var tokens: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    private var problem: String? {
        if !ProfileFormat.isValidID(name) || name == "none" { return "Name: 1–16 lowercase letters, digits or -, except none." }
        if name != originalName && model.store.set.buzzNames.contains(name) { return "That name is already used." }
        if model.store.set.buzzes[name] == nil && model.store.set.buzzes.count >= 16 { return "A set holds up to 16 custom patterns." }
        do { _ = try ProfileFormat.parsePattern(text); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        Form {
            Section {
                TextField("Pattern name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                BuzzTimeline(text: text)
                BuzzPlayButton(text: text)
                TextField("250 _200 250*90", text: $text, axis: .vertical).font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let problem { Text(problem).font(.caption).foregroundStyle(Theme.danger) }
            } footer: { Text("Pulse: milliseconds * strength. Pause: _milliseconds. Up to 16 steps and 8 seconds, starting and ending with a pulse.") }
            Section("Steps") {
                ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                    step(index, token)
                }
                .onDelete { offsets in var next = tokens; next.remove(atOffsets: offsets); text = next.joined(separator: " ") }
                HStack {
                    Button("Add pulse", systemImage: "waveform") { text = (tokens + ["60*70"]).joined(separator: " ") }
                    Spacer()
                    Button("Add pause", systemImage: "pause") { text = (tokens + ["_200"]).joined(separator: " ") }
                }.disabled(tokens.count >= 16)
            }
            Section {
                Button(originalName.isEmpty || duplicate ? "Save pattern" : "Save customization") {
                    model.store.set.buzzes[name] = text
                    dismiss()
                }.disabled(problem != nil)
                if !originalName.isEmpty {
                    Button("Duplicate with a new name") {
                        name = ""
                        duplicate = true
                    }
                    if model.store.set.buzzes[originalName] != nil {
                        Button("Remove customization", role: .destructive) {
                            model.store.set.buzzes[originalName] = nil
                            dismiss()
                        }
                    }
                }
            }
        }.darkList().navigationTitle("Buzz designer").navigationBarTitleDisplayMode(.inline)
    }
    private func step(_ index: Int, _ token: String) -> some View {
        let pause = token.hasPrefix("_")
        let parts = token.replacingOccurrences(of: "_", with: "").split(separator: "*")
        // Bounded, so text being typed (like "nan") can't crash the sliders.
        let ms = min(max(Double(parts.first ?? "60").flatMap { $0.isFinite ? $0 : nil } ?? 60, 20), pause ? 3000 : 2000)
        let strength = min(max(parts.count > 1 ? Double(parts[1]).flatMap { $0.isFinite ? $0 : nil } ?? 70 : 70, 1), 100)
        func change(_ duration: Double, _ power: Double) {
            var next = tokens
            guard next.indices.contains(index) else { return }
            next[index] = pause ? "_\(Int(duration))" : "\(Int(duration))*\(Int(power))"
            text = next.joined(separator: " ")
        }
        return VStack(alignment: .leading) {
            Text("\(pause ? "Pause" : "Pulse") · \(Int(ms)) ms\(pause ? "" : " · \(Int(strength))%")").font(.subheadline)
            Label { Slider(value: Binding(get: { ms }, set: { change($0, strength) }), in: 20...(pause ? 3000 : 2000), step: 10).accessibilityLabel("Duration in milliseconds") }
                icon: { Image(systemName: "timer").foregroundStyle(.secondary) }
            if !pause {
                Label { Slider(value: Binding(get: { strength }, set: { change(ms, $0) }), in: 1...100, step: 1).tint(Theme.mint).accessibilityLabel("Strength percent") }
                    icon: { Image(systemName: "waveform.path").foregroundStyle(.secondary) }
            }
        }
    }
}

struct FeedbackView: View {
    @Environment(DongleModel.self) private var model
    var body: some View {
        Form {
            Section { FirmwareFeatureNote() }
            ForEach(BuzzFeedback.all, id: \.name) { moment in
                Section {
                    Picker("Pattern", selection: Binding(get: { model.store.set.feedback[moment.name] ?? moment.pattern }, set: { model.store.set.feedback[moment.name] = $0 })) {
                        Text("None").tag("none")
                        ForEach(model.store.set.buzzNames, id: \.self) { Text($0).tag($0) }
                    }
                    let name = model.store.set.feedback[moment.name] ?? moment.pattern
                    if name != "none" {
                        BuzzTimeline(text: model.store.set.patternText(name))
                        BuzzPlayButton(text: model.store.set.patternText(name))
                    }
                } header: { Text(moment.detail) } footer: { Text(moment.name).font(.caption.monospaced()) }
            }
        }.darkList().navigationTitle("Feedback").navigationBarTitleDisplayMode(.inline)
    }
}

struct BandEventsView: View {
    @Environment(DongleModel.self) private var model
    let uid: UUID
    @State private var finger = "thumb"
    @State private var search = ""
    private let common = ["swipeIn", "swipeOut", "click", "partialPress", "partialRelease", "partialClick", "partialUp", "partialDown", "partialLeft", "partialRight"]
    var body: some View {
        List {
            Section {
                FirmwareFeatureNote()
                Text("Raw events fire alongside named gestures. Try Gesture lab to see what your band actually sends.").font(.callout).foregroundStyle(.secondary)
                Picker("Finger", selection: $finger) {
                    Text("Any").tag("")
                    ForEach(ProfileGesture.bandFingers, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            Section("Try these first") { rows(common) }
            Section { DisclosureGroup("All events") { rows(ProfileGesture.bandEvents.filter { !common.contains($0) }) } }
        }.darkList().navigationTitle("Band events").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find an event")
    }
    private func rows(_ events: [String]) -> some View {
        ForEach(events.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { event in
            let gesture = ProfileGesture(rawValue: "band." + (finger.isEmpty ? "" : finger + ".") + event)!
            NavigationLink { BindingEditorView(uid: uid, gesture: gesture) } label: {
                GestureRow(gesture: gesture, binding: model.store.set.profiles.first { $0.uid == uid }?[gesture], broken: false)
            }
        }
    }
}
