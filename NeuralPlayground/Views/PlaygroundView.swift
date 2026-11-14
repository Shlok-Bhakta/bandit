import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// Phase 3: the live dashboard.
struct PlaygroundView: View {
    @Environment(AppModel.self) private var model
    @Environment(BandClient.self) private var band
    @State private var counts: [RecognizedGesture: Int] = [:]
    @State private var lastSeen: [RecognizedGesture: Date] = [:]
    @State private var flash: [RecognizedGesture: Int] = [:]
    @State private var latest: GestureEvent?
    @State private var burst = 0

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: 16) {
                statusStrip
                WristQuickSwitch()
                heroCard
                Card(title: "Taps & holds", systemImage: "hand.tap") {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Finger.allCases, id: \.self) { finger in
                            ForEach(TapKind.allCases, id: \.self) { kind in tile(.tap(finger, kind)) }
                        }
                    }
                }
                Card(title: "Thumb swipes", systemImage: "hand.draw") { swipePad }
                PinchDialCard()
                OrientationCard()
                Card(title: "Raw band messages", systemImage: "waveform.path.ecg") {
                    if let raw = model.sensors.lastRaw {
                        InfoRow(label: "Last", value: "#\(raw.sequence) \(raw.finger) · \(raw.action) · \(raw.derivedAction)", monospaced: true)
                    } else {
                        Text("Presses, releases and other band messages appear here, including ones that aren't user-level gestures.").font(.footnote).foregroundStyle(.secondary)
                    }
                    InfoRow(label: "Gesture messages", value: "\(band.diagnostics.gestureMessages)")
                    InfoRow(label: "Recognized", value: "\(band.diagnostics.recognizedGestures)")
                }
                Card(title: "Tools", systemImage: "wrench.and.screwdriver") {
                    NavigationLink { SignalsView() } label: { Label("Live signals: EMG, gyro, all messages", systemImage: "waveform.path.ecg.rectangle") }
                    Divider()
                    NavigationLink { SystemControlView() } label: { Label("System Control (BCI HID)", systemImage: "accessibility") }
                    Divider()
                    NavigationLink { EventLogView() } label: { Label("Event log", systemImage: "list.bullet.rectangle") }
                    Divider()
                    NavigationLink { HapticsView() } label: { Label("Haptics lab", systemImage: "waveform") }
                    Divider()
                    NavigationLink { EMGView() } label: { Label("Raw EMG viewer (experimental)", systemImage: "waveform.path") }
                }
                Card(title: "Simulation", systemImage: "theatermasks") {
                    Toggle("Simulation mode", isOn: $model.simulationEnabled)
                    Text("Adds buttons that inject gestures marked SIMULATED. They're never counted as band events: the log, games and dashboard all label them.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.simulationEnabled { SimulationPad() }
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Playground")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionPill() } }
        .task {
            for await event in band.events.subscribe() {
                if case .gesture(let gesture) = event { trigger(gesture) }
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            metric("battery.75", band.battery.map { "\($0)%" } ?? "—")
            metric("antenna.radiowaves.left.and.right", band.rssi.map { "\($0)" } ?? "—")
            metric("cpu", band.deviceInfo?.firmware ?? "—")
            metric("speedometer", model.sensors.motionRate > 0 ? "\(Int(model.sensors.motionRate)) Hz" : "—")
        }
    }

    private func metric(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(value).lineLimit(1).minimumScaleFactor(0.6)
        }
        .font(.caption.monospacedDigit().weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.card, in: Capsule())
    }

    private var heroCard: some View {
        Card {
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .stroke((latest.map { Theme.color(for: $0.gesture) } ?? .gray).opacity(0.5), lineWidth: 2)
                        .scaleEffect(burst > 0 ? 1.6 + CGFloat(ring) * 0.35 : 0.6)
                        .opacity(burst > 0 ? 0 : 0.8)
                        .animation(.easeOut(duration: 0.8).delay(Double(ring) * 0.08), value: burst)
                }
                VStack(spacing: 8) {
                    Image(systemName: latest.map { Theme.symbol(for: $0.gesture) } ?? "hand.wave")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(latest.map { Theme.color(for: $0.gesture) } ?? .secondary)
                        .symbolEffect(.bounce, value: burst)
                    Text(latest?.gesture.title ?? (band.phase == .streaming ? "Make a gesture" : "Connect your band"))
                        .font(.title2.bold())
                        .contentTransition(.numericText())
                    if let latest, let raw = latest.raw, raw != latest.gesture {
                        Text("Band reported: \(raw.title)").font(.caption).foregroundStyle(Theme.warn)
                    }
                    if let latest {
                        HStack {
                            SourceBadge(source: latest.source)
                            Text(latest.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    private var swipePad: some View {
        VStack(spacing: 10) {
            tile(.swipe(.up)).frame(maxWidth: 120)
            HStack(spacing: 10) {
                tile(.swipe(.left))
                Image(systemName: "hand.raised.fingers.spread").font(.largeTitle).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                tile(.swipe(.right))
            }
            tile(.swipe(.down)).frame(maxWidth: 120)
        }
    }

    private func tile(_ gesture: RecognizedGesture) -> some View {
        let active = (flash[gesture] ?? 0) > 0
        let color = Theme.color(for: gesture)
        return VStack(spacing: 6) {
            Image(systemName: Theme.symbol(for: gesture)).font(.title2)
            Text(shortTitle(gesture)).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text("\(counts[gesture] ?? 0)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            if let seen = lastSeen[gesture] {
                Text(seen.formatted(.dateTime.hour().minute().second())).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 86)
        .background(color.opacity(active ? 0.55 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color.opacity(active ? 1 : 0.2), lineWidth: active ? 2 : 1))
        .scaleEffect(active ? 1.08 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: active)
    }

    private func shortTitle(_ gesture: RecognizedGesture) -> String {
        switch gesture {
        case .swipe(let direction): direction.rawValue.capitalized
        case .tap(let finger, .tap): "\(finger.rawValue.capitalized) tap"
        case .tap(let finger, .doubleTap): "\(finger.rawValue.capitalized) ×2"
        case .tap(let finger, .hold): "\(finger.rawValue.capitalized) hold"
        }
    }

    private func trigger(_ event: GestureEvent) {
        latest = event
        burst += 1
        counts[event.gesture, default: 0] += 1
        lastSeen[event.gesture] = event.date
        flash[event.gesture, default: 0] += 1
        let gesture = event.gesture
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            flash[gesture, default: 1] -= 1
        }
    }
}

struct SimulationPad: View {
    @Environment(BandClient.self) private var band

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SIMULATED INPUT").badgeStyle(Theme.warn)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 8) {
                ForEach(RecognizedGesture.all, id: \.self) { gesture in
                    Button(gesture.title) { band.simulate(gesture) }
                        .font(.caption2).buttonStyle(.bordered).tint(Theme.warn)
                }
            }
        }
    }
}

struct PinchDialCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Pinch & rotate", systemImage: "dial.medium") {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(.white.opacity(0.1), lineWidth: 10)
                    Circle().trim(from: 0, to: min(1, abs(model.sensors.dialAngle).truncatingRemainder(dividingBy: 360) / 360))
                        .stroke(model.sensors.dialAngle >= 0 ? Theme.mint : Theme.warn, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .scaleEffect(x: model.sensors.dialAngle >= 0 ? 1 : -1)
                    Capsule().fill(.white).frame(width: 4, height: 34).offset(y: -22)
                        .rotationEffect(.degrees(model.sensors.dialAngle))
                        .animation(.interactiveSpring, value: model.sensors.dialAngle)
                }
                .frame(width: 110, height: 110)
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.sensors.dialEngaged ? "Pinching" : "Released", systemImage: model.sensors.dialEngaged ? "hand.pinch.fill" : "hand.pinch")
                        .foregroundStyle(model.sensors.dialEngaged ? Theme.mint : .secondary).font(.headline)
                    Text(String(format: "%+.1f°", model.sensors.dialAngle)).font(.title.monospacedDigit().bold())
                    Text("Pinch your index finger and thumb, hold ~0.2 s, then turn your wrist. The angle is integrated from the gyro, so it's relative.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset") { model.sensors.resetDial() }.font(.caption)
                }
            }
        }
    }
}

struct OrientationCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let euler = model.sensors.euler
        Card(title: "Wrist orientation & motion", systemImage: "gyroscope") {
            HStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [Theme.accent, Theme.mint], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 70, height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.4)).frame(width: 36, height: 24))
                        .rotation3DEffect(.degrees(euler.pitch), axis: (1, 0, 0))
                        .rotation3DEffect(.degrees(euler.roll), axis: (0, 1, 0))
                        .rotationEffect(.degrees(-euler.yaw))
                        .animation(.linear(duration: 0.05), value: euler.roll)
                }
                .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 6) {
                    angle("Roll", euler.roll)
                    angle("Pitch", euler.pitch)
                    angle("Yaw", euler.yaw)
                    if model.sensors.orientation == nil { Text("No orientation data yet").font(.caption).foregroundStyle(.secondary) }
                }
            }
            GyroTrace(history: model.sensors.gyroHistory).frame(height: 90)
            HStack {
                legend("X", .red); legend("Y", .green); legend("Z", .blue)
                Spacer()
                Text(String(format: "|ω| %.0f °/s", (model.sensors.gyro * model.sensors.gyro).sum().squareRoot()))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("The gyro scale (0.07 °/s per unit) and quaternion axes come from observation and aren't documented by Meta.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func angle(_ name: String, _ value: Double) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            Text(String(format: "%+6.1f°", value)).monospacedDigit().font(.headline)
        }
    }

    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(name) }.font(.caption2)
    }
}

struct GyroTrace: View {
    let history: [SIMD3<Double>]

    var body: some View {
        Canvas { context, size in
            guard history.count > 1 else { return }
            let scale = max(90, history.map { max(abs($0.x), abs($0.y), abs($0.z)) }.max() ?? 90)
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height / 2)); $0.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                           with: .color(.white.opacity(0.1)))
            for (axis, color) in [(0, Color.red), (1, Color.green), (2, Color.blue)] {
                var path = Path()
                for (index, sample) in history.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(history.count - 1)
                    let y = size.height / 2 - CGFloat(sample[axis] / scale) * size.height / 2
                    index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
                context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 1.5)
            }
        }
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EventLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var log = model.eventLog
        List {
            Section {
                Toggle("Pause", isOn: $log.paused)
                Toggle("Include raw band messages", isOn: $log.includeRawMessages)
                if log.paused, log.dropped > 0 { Text("\(log.dropped) events skipped while paused").font(.caption).foregroundStyle(.secondary) }
            }
            Section("\(log.items.count) events (newest first)") {
                ForEach(log.items) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Text(item.kind).font(.caption.weight(.bold))
                        }
                        .frame(width: 90, alignment: .leading)
                        Text(item.detail).font(.callout)
                        Spacer()
                        if item.source != .band { SourceBadge(source: item.source) }
                    }
                }
            }
        }
        .navigationTitle("Event log")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: log.csv, preview: SharePreview("band-events.csv")) { Image(systemName: "square.and.arrow.up") }
                Button(role: .destructive) { log.clear() } label: { Image(systemName: "trash") }
            }
        }
    }
}
