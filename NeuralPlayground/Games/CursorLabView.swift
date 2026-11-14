import BandKit
import BandLogging
import BandProtocol
import SwiftUI

/// Mudra-style air cursor: hold an index pinch and move your forearm to steer; release to leave the
/// cursor where it is; a quick index tap clicks.
struct CursorLabView: View {
    enum Demo: String, CaseIterable, Identifiable {
        case targets = "Targets"
        case draw = "Draw"
        case buttons = "Buttons"
        var id: Self { self }
    }

    @Environment(BandClient.self) private var band
    @Environment(AppModel.self) private var model
    @State private var demo = Demo.targets
    @State private var cursor = CGPoint(x: 0.5, y: 0.5)
    @State private var filter = CursorFilter()
    @State private var lastFrame = ProcessInfo.processInfo.systemUptime
    @State private var wasClutched = false
    @State private var wasDrawing = false
    @State private var clickPulse = 0
    // Targets
    @State private var target = CGPoint(x: 0.3, y: 0.4)
    @State private var targetShownAt = ProcessInfo.processInfo.systemUptime
    @State private var hits: [Double] = []
    @State private var misses = 0
    // Draw
    @State private var strokes: [[CGPoint]] = []
    // Buttons
    @State private var lit: Int?
    @State private var buttonPresses = 0
    @State private var sensitivity = 1.0

    private var engine: MotionEngine { model.motion }
    /// Index hold steers everywhere; in Draw mode a middle hold also steers, with the pen down.
    private var clutched: Bool { engine.indexHeld || drawing }
    private var drawing: Bool { demo == .draw && engine.middleHeld }

    var body: some View {
        VStack(spacing: 10) {
            Picker("Demo", selection: $demo) { ForEach(Demo.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            header
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.35))
                    content(size: geometry.size)
                    cursorView.position(x: cursor.x * geometry.size.width, y: cursor.y * geometry.size.height)
                }
                .contentShape(Rectangle())
                // Touch fallback for testing without the band (labeled).
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    cursor = CGPoint(x: value.location.x / geometry.size.width, y: value.location.y / geometry.size.height)
                }.onEnded { _ in click(size: geometry.size, source: .touch) })
                .onChange(of: clickPulse) { _, _ in click(size: geometry.size, source: .band) }
            }
            HStack {
                Text("Sensitivity").font(.caption)
                Slider(value: $sensitivity, in: 0.4...2.5)
                Text(String(format: "%.1f×", sensitivity)).font(.caption.monospacedDigit())
            }
        }
        .padding()
        .screenBackground()
        .navigationTitle("Air Cursor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionPill() } }
        .task {
            // ~120 Hz cursor integration from the motion engine.
            _ = engine.takeAimDelta()
            while !Task.isCancelled {
                step()
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        .task {
            for await event in band.events.subscribe() {
                guard case .gesture(let gesture) = event, gesture.source == .band || model.simulationEnabled else { continue }
                switch gesture.gesture {
                case .tap(.index, .tap): clickPulse += 1
                case .tap(.index, .doubleTap) where demo == .draw: strokes.removeAll(); engine.tick(durationMs: 60, amplitude: 120)
                case .tap(.middle, .tap) where demo != .draw: cursor = CGPoint(x: 0.5, y: 0.5); engine.tick()
                default: break
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Label(drawing ? "Drawing" : clutched ? "Moving" : (demo == .draw ? "Index hold = move · middle hold = draw" : "Pinch & hold to steer · tap to click"),
                  systemImage: drawing ? "pencil.tip" : clutched ? "hand.pinch.fill" : "hand.pinch")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(drawing ? Theme.warn : clutched ? Theme.mint : .secondary)
            Spacer()
            switch demo {
            case .targets:
                let average = hits.isEmpty ? 0 : hits.reduce(0, +) / Double(hits.count)
                Text("\(hits.count) hits · \(misses) misses · \(hits.isEmpty ? "—" : String(format: "%.2fs", average))")
                    .font(.caption.monospacedDigit())
            case .draw: Text("Index double tap clears").font(.caption).foregroundStyle(.secondary)
            case .buttons: Text("\(buttonPresses) presses").font(.caption.monospacedDigit())
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private func content(size: CGSize) -> some View {
        switch demo {
        case .targets:
            Circle().fill(Theme.warn.gradient).frame(width: 64, height: 64)
                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 3))
                .position(x: target.x * size.width, y: target.y * size.height)
                .animation(.spring(duration: 0.3), value: target)
        case .draw:
            Canvas { context, canvasSize in
                for stroke in strokes where stroke.count > 1 {
                    var path = Path()
                    path.move(to: CGPoint(x: stroke[0].x * canvasSize.width, y: stroke[0].y * canvasSize.height))
                    for point in stroke.dropFirst() { path.addLine(to: CGPoint(x: point.x * canvasSize.width, y: point.y * canvasSize.height)) }
                    context.stroke(path, with: .linearGradient(Gradient(colors: [Theme.accent, Theme.mint]),
                                                               startPoint: .zero, endPoint: CGPoint(x: canvasSize.width, y: canvasSize.height)),
                                   style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
            }
        case .buttons:
            let columns = 2, rows = 3
            ForEach(0..<(columns * rows), id: \.self) { index in
                let rect = buttonRect(index, columns: columns, rows: rows, size: size)
                RoundedRectangle(cornerRadius: 18)
                    .fill(lit == index ? Theme.mint : Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15)))
                    .overlay(Image(systemName: ["music.note", "lightbulb", "camera", "bell", "heart", "star"][index]).font(.title))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeOut(duration: 0.2), value: lit)
            }
        }
    }

    private var cursorView: some View {
        ZStack {
            Circle().fill(Color.white.opacity(clutched ? 0.25 : 0.12)).frame(width: 46, height: 46)
                .scaleEffect(clutched ? 1.15 : 1)
            Circle().fill(cursorColor).frame(width: drawing ? 10 : 14, height: drawing ? 10 : 14)
            Circle().stroke(clutched ? cursorColor : .white.opacity(0.6), lineWidth: 2).frame(width: 30, height: 30)
        }
        .shadow(color: cursorColor.opacity(0.6), radius: 8)
        .animation(.spring(duration: 0.2), value: clutched)
        .allowsHitTesting(false)
    }

    private var cursorColor: Color { drawing ? Theme.warn : clutched ? Theme.mint : .white }

    private func buttonRect(_ index: Int, columns: Int, rows: Int, size: CGSize) -> CGRect {
        let gap: CGFloat = 16
        let width = (size.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
        let height = (size.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        let column = index % columns, row = index / columns
        return CGRect(x: gap + CGFloat(column) * (width + gap), y: gap + CGFloat(row) * (height + gap), width: width, height: height)
    }

    private func step() {
        let now = ProcessInfo.processInfo.systemUptime
        filter.sensitivity = sensitivity
        let delta = engine.takeAimDelta()
        let move = filter.move(aimDelta: delta, speed: engine.speed, clutched: clutched, now: now)
        if clutched != wasClutched {
            wasClutched = clutched
            if clutched { engine.tick(durationMs: 20, amplitude: 90) }
        }
        if drawing != wasDrawing {
            wasDrawing = drawing
            // Pen down starts a new stroke where the cursor is; pen up ends it.
            if drawing {
                strokes.append([cursor])
                engine.tick(durationMs: 30, amplitude: 140)
            }
        }
        guard move != .zero else { return }
        cursor.x = min(1, max(0, cursor.x + move.dx))
        cursor.y = min(1, max(0, cursor.y + move.dy))
        if drawing, !strokes.isEmpty {
            strokes[strokes.count - 1].append(cursor)
        }
        lastFrame = now
    }

    private func click(size: CGSize, source: EventSource) {
        let point = CGPoint(x: cursor.x * size.width, y: cursor.y * size.height)
        switch demo {
        case .targets:
            let center = CGPoint(x: target.x * size.width, y: target.y * size.height)
            if hypot(point.x - center.x, point.y - center.y) <= 40 {
                hits.append(ProcessInfo.processInfo.systemUptime - targetShownAt)
                engine.pattern([(30, 220, 40), (30, 255, 0)])
                target = CGPoint(x: .random(in: 0.12...0.88), y: .random(in: 0.12...0.88))
                targetShownAt = ProcessInfo.processInfo.systemUptime
                logInfo(.games, "Air cursor hit (\(source.rawValue)) in \(String(format: "%.2f", hits.last ?? 0)) s")
            } else {
                misses += 1
                engine.tick(durationMs: 15, amplitude: 70)
            }
        case .buttons:
            if let index = (0..<6).first(where: { buttonRect($0, columns: 2, rows: 3, size: size).contains(point) }) {
                lit = index
                buttonPresses += 1
                engine.tick(durationMs: 40, amplitude: 200)
                Task { try? await Task.sleep(for: .milliseconds(400)); if lit == index { lit = nil } }
            }
        case .draw:
            engine.tick(durationMs: 15, amplitude: 80)
        }
    }
}
