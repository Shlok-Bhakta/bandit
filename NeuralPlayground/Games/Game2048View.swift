import BandKit
import BandProtocol
import SwiftUI

/// 2048 with thumb swipes. Tiles slide, merging tiles slide into each other and pop, new tiles scale
/// in. Merges buzz the band, harder for bigger tiles. Middle hold = new game.
@MainActor
@Observable
final class Game2048 {
    struct Tile: Identifiable, Equatable {
        let id = UUID()
        var value: Int
        var row: Int
        var column: Int
        /// Slid into another tile this move; removed once the slide finishes.
        var consumed = false
        /// The doubled value a merge lands on this tile, shown once the slide finishes.
        var pending: Int?
    }

    static let slide = 0.12

    private(set) var tiles: [Tile] = []
    private(set) var score = 0
    private(set) var best = UserDefaults.standard.integer(forKey: "2048.best")
    private(set) var over = false
    private(set) var won = false
    private(set) var animating = false

    init() { reset() }

    func reset() {
        tiles = []
        score = 0
        over = false
        won = false
        spawn()
        spawn()
    }

    private func value(_ row: Int, _ column: Int) -> Int? {
        tiles.first { !$0.consumed && $0.row == row && $0.column == column }?.value
    }

    private func spawn() {
        var empty: [(Int, Int)] = []
        for r in 0..<4 { for c in 0..<4 where value(r, c) == nil { empty.append((r, c)) } }
        guard let (r, c) = empty.randomElement() else { return }
        tiles.append(Tile(value: Double.random(in: 0..<1) < 0.9 ? 2 : 4, row: r, column: c))
    }

    /// Phase 1 (animated): every tile moves to its destination; merging tiles land on the same cell,
    /// the survivor doubles. Returns (moved, biggest merge). Call `settle()` after the slide.
    func move(_ direction: SwipeDirection) -> (Bool, Int) {
        guard !over, !animating else { return (false, 0) }
        var moved = false
        var biggest = 0
        var next = tiles
        for line in 0..<4 {
            // Indices of this line's tiles, ordered from the edge they slide toward.
            let indices = next.indices.filter { index in
                switch direction {
                case .left, .right: next[index].row == line
                case .up, .down: next[index].column == line
                }
            }.sorted { a, b in
                switch direction {
                case .left: next[a].column < next[b].column
                case .right: next[a].column > next[b].column
                case .up: next[a].row < next[b].row
                case .down: next[a].row > next[b].row
                }
            }
            var slot = 0
            var lastIndex: Int?
            var lastMerged = false
            for index in indices {
                if let last = lastIndex, !lastMerged, next[last].value == next[index].value {
                    // Merge: slide onto the previous tile, which doubles when the slide lands.
                    let doubled = next[last].value * 2
                    next[last].pending = doubled
                    biggest = max(biggest, doubled)
                    score += doubled
                    next[index].row = next[last].row
                    next[index].column = next[last].column
                    next[index].consumed = true
                    lastMerged = true
                    moved = true
                    continue
                }
                let target = direction == .left || direction == .up ? slot : 3 - slot
                let (row, column) = direction == .left || direction == .right ? (line, target) : (target, line)
                if next[index].row != row || next[index].column != column { moved = true }
                next[index].row = row
                next[index].column = column
                lastIndex = index
                lastMerged = false
                slot += 1
            }
        }
        guard moved else { return (false, 0) }
        tiles = next
        animating = true
        if biggest >= 2048 { won = true }
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: "2048.best")
        }
        return (true, biggest)
    }

    /// Phase 2: remove the tiles that merged away and spawn a new one.
    func settle() {
        for index in tiles.indices {
            if let pending = tiles[index].pending {
                tiles[index].value = pending
                tiles[index].pending = nil
            }
        }
        tiles.removeAll(where: \.consumed)
        spawn()
        over = !canMove()
        animating = false
    }

    private func canMove() -> Bool {
        for r in 0..<4 {
            for c in 0..<4 {
                guard let v = value(r, c) else { return true }
                if c < 3, value(r, c + 1) == v { return true }
                if r < 3, value(r + 1, c) == v { return true }
            }
        }
        return false
    }
}

struct Game2048View: View {
    @Environment(BandClient.self) private var band
    @Environment(AppModel.self) private var model
    @State private var game = Game2048()
    @State private var lastSource: EventSource?
    @State private var queued: [SwipeDirection] = []

    private var engine: MotionEngine { model.motion }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                score("Score", game.score)
                score("Best", game.best)
                Spacer()
                if let lastSource { SourceBadge(source: lastSource) }
            }
            board
                .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    apply(abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up), source: .touch)
                })
            Text("Thumb swipes slide the tiles · merges buzz the band, harder for bigger tiles · hold your middle finger for a new game")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .screenBackground()
        .navigationTitle("2048")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionPill() } }
        .task {
            for await event in band.events.subscribe() {
                guard case .gesture(let gesture) = event, gesture.source == .band || model.simulationEnabled else { continue }
                switch gesture.gesture {
                case .swipe(let direction): apply(direction, source: gesture.source)
                case .tap(.middle, .hold):
                    withAnimation(.spring(duration: 0.25)) { game.reset() }
                    engine.pattern([(50, 150, 60), (50, 150, 0)])
                default: break
                }
            }
        }
    }

    private func apply(_ direction: SwipeDirection, source: EventSource) {
        lastSource = source
        // A swipe during the slide waits its turn instead of being dropped.
        guard !game.animating else {
            if queued.count < 2 { queued.append(direction) }
            return
        }
        let (moved, merged) = withAnimation(.easeInOut(duration: Game2048.slide)) { game.move(direction) }
        guard moved else {
            engine.tick(durationMs: 12, amplitude: 60)
            return
        }
        if merged > 0 {
            let level = Double(Int(log2(Double(merged)))) / 11 // 4 → gentle, 2048 → maximum
            engine.tick(durationMs: UInt64(25 + level * 70), amplitude: UInt8(90 + level * 165), spacing: 0)
        }
        Task {
            try? await Task.sleep(for: .seconds(Game2048.slide))
            withAnimation(.spring(duration: 0.22, bounce: 0.35)) { game.settle() }
            if game.over { engine.pattern([(300, 255, 0)]) }
            if game.won, merged >= 2048 { engine.pattern([(80, 255, 80), (80, 255, 80), (200, 255, 0)]) }
            if !queued.isEmpty { apply(queued.removeFirst(), source: source) }
        }
    }

    private func score(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            Text("\(value)").font(.title3.bold().monospacedDigit()).contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private var board: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 8
            let side = min(geometry.size.width, geometry.size.height)
            let cell = (side - gap * 5) / 4
            let position = { (row: Int, column: Int) in
                CGPoint(x: gap + cell / 2 + CGFloat(column) * (cell + gap), y: gap + cell / 2 + CGFloat(row) * (cell + gap))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.36, green: 0.33, blue: 0.3))
                ForEach(0..<16, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.8, green: 0.76, blue: 0.71).opacity(0.35))
                        .frame(width: cell, height: cell)
                        .position(position(index / 4, index % 4))
                }
                ForEach(game.tiles) { tile in
                    TileView(value: tile.value, size: cell)
                        .position(position(tile.row, tile.column))
                        .zIndex(tile.consumed ? 0 : 1)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
                if game.over {
                    VStack(spacing: 6) {
                        Text("Game over").font(.title.bold())
                        Text("Hold your middle finger").font(.callout)
                    }
                    .padding(20).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// One tile; pops when its value changes (a merge landed on it, after the slide).
private struct TileView: View {
    let value: Int
    let size: CGFloat

    private static let colors: [Int: Color] = [
        2: Color(red: 0.93, green: 0.89, blue: 0.85), 4: Color(red: 0.93, green: 0.88, blue: 0.78),
        8: Color(red: 0.95, green: 0.69, blue: 0.47), 16: Color(red: 0.96, green: 0.58, blue: 0.39),
        32: Color(red: 0.96, green: 0.49, blue: 0.37), 64: Color(red: 0.96, green: 0.37, blue: 0.23),
        128: Color(red: 0.93, green: 0.81, blue: 0.45), 256: Color(red: 0.93, green: 0.8, blue: 0.38),
        512: Color(red: 0.93, green: 0.78, blue: 0.31), 1024: Color(red: 0.93, green: 0.77, blue: 0.25),
        2048: Color(red: 0.93, green: 0.76, blue: 0.18),
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Self.colors[value] ?? Color(red: 0.24, green: 0.23, blue: 0.2))
            Text("\(value)")
                .font(.system(size: size * (value < 100 ? 0.42 : value < 1000 ? 0.36 : 0.28), weight: .heavy, design: .rounded))
                .foregroundStyle(value <= 4 ? Color(red: 0.47, green: 0.43, blue: 0.4) : .white)
        }
        .frame(width: size, height: size)
        .keyframeAnimator(initialValue: 1.0, trigger: value) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(1.18, duration: 0.08)
            CubicKeyframe(1.0, duration: 0.12)
        }
    }
}
