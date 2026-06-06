import SwiftUI

/// Selve spillet: tiles falder ned i fire baner, og man trykker i takt med musikken.
struct GameView: View {
    let track: Track
    let beatmap: Beatmap
    let difficulty: Difficulty
    @ObservedObject var playback: PlaybackController

    @StateObject private var engine = GameEngine()
    @State private var sound = SoundEngine()
    @State private var showResult = false
    @Environment(\.dismiss) private var dismiss

    private let laneColors: [Color] = [.cyan, .purple, .pink, .orange]
    private let hitLineInset: CGFloat = 130
    private let tileAspect: CGFloat = 1.4

    var body: some View {
        GeometryReader { geo in
            let laneWidth = geo.size.width / CGFloat(kLaneCount)
            let tileHeight = laneWidth * tileAspect
            let hitLineY = geo.size.height - hitLineInset

            ZStack {
                Color.black.ignoresSafeArea()

                laneSeparators(size: geo.size, laneWidth: laneWidth)

                fallingTiles(laneWidth: laneWidth, tileHeight: tileHeight, hitLineY: hitLineY)

                hitLine(width: geo.size.width, y: hitLineY)

                // Tap-områder (et pr. bane, så flere fingre kan ramme samtidig)
                HStack(spacing: 0) {
                    ForEach(0..<kLaneCount, id: \.self) { lane in
                        Color.white.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture { engine.tap(lane: lane) }
                    }
                }

                hud
            }
        }
        .navigationBarBackButtonHidden(true)
        .onChange(of: engine.isFinished) { _, finished in
            if finished {
                teardown()
                showResult = true
            }
        }
        .fullScreenCover(isPresented: $showResult) {
            ResultView(track: track, score: engine.score, maxCombo: engine.maxCombo,
                       didWin: engine.didWin) {
                showResult = false
                dismiss()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { quit() } label: { Label("Stop", systemImage: "xmark") }
            }
        }
        .onAppear { startGame() }
        .onDisappear { teardown() }
    }

    // MARK: - Spil-elementer

    private func fallingTiles(laneWidth: CGFloat, tileHeight: CGFloat, hitLineY: CGFloat) -> some View {
        Canvas { context, _ in
            let approach = engine.approachDuration
            for tile in engine.tiles where tile.state != .missed {
                let spawnTime = tile.time - approach
                let progress = (engine.currentTime - spawnTime) / approach
                guard progress >= 0, progress <= 1.25 else { continue }
                if tile.state == .hit && progress >= 1 { continue }

                let centerY = -tileHeight / 2 + CGFloat(progress) * (hitLineY + tileHeight / 2)
                let x = CGFloat(tile.lane) * laneWidth
                let rect = CGRect(x: x + 4, y: centerY - tileHeight / 2,
                                  width: laneWidth - 8, height: tileHeight)
                let path = Path(roundedRect: rect, cornerRadius: 12)

                let baseColor = laneColors[tile.lane]
                if tile.state == .hit {
                    context.fill(path, with: .color(.white.opacity(0.9)))
                } else {
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [baseColor.opacity(0.95), baseColor.opacity(0.6)]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                    context.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func laneSeparators(size: CGSize, laneWidth: CGFloat) -> some View {
        ZStack {
            ForEach(1..<kLaneCount, id: \.self) { i in
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 1, height: size.height)
                    .position(x: CGFloat(i) * laneWidth, y: size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func hitLine(width: CGFloat, y: CGFloat) -> some View {
        Rectangle()
            .fill(LinearGradient(colors: [.white.opacity(0), .white, .white.opacity(0)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: 3)
            .position(x: width / 2, y: y)
            .allowsHitTesting(false)
    }

    private var hud: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(engine.score)")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    if engine.combo > 1 {
                        Text("Combo ×\(engine.combo)")
                            .font(.headline).foregroundStyle(.yellow)
                    }
                }
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0..<GameEngine.startingLives, id: \.self) { i in
                        Image(systemName: i < engine.lives ? "heart.fill" : "heart")
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if let judgement = engine.lastJudgement {
                Text(judgement.rawValue)
                    .font(.title.weight(.black))
                    .foregroundStyle(judgement == .miss ? .red : .green)
                    .transition(.scale.combined(with: .opacity))
                    .id(engine.score) // re-trigger animationen
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: - Livscyklus

    private func startGame() {
        sound.start()
        engine.load(beatmap: beatmap, difficulty: difficulty) {
            sound.playHit()
        }
        playback.onPlaybackStarted = {
            engine.startClock()
        }
        playback.play(track: track)
    }

    private func teardown() {
        engine.stop()
        sound.stop()
        playback.pause()
        playback.onPlaybackStarted = nil
    }

    private func quit() {
        teardown()
        dismiss()
    }
}
