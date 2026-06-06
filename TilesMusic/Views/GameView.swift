import SwiftUI

/// Selve spillet: tiles falder ned i fire baner, og man trykker i takt med musikken.
struct GameView: View {
    let track: GameTrack
    let beatmap: Beatmap
    let difficulty: Difficulty
    let playback: any GamePlayback

    @StateObject private var engine = GameEngine()
    @State private var showResult = false
    @State private var record = HighscoreStore.Result(best: 0, isNewRecord: false)

    // Animationstilstand
    @State private var pressedLanes = [Bool](repeating: false, count: kLaneCount)
    @State private var comboScale: CGFloat = 1
    @State private var missFlash = false

    @Environment(\.dismiss) private var dismiss

    private let laneColors: [Color] = [.cyan, .purple, .pink, .orange]
    private let hitLineInset: CGFloat = 400
    private let tileAspect: CGFloat = 1.4

    var body: some View {
        GeometryReader { geo in
            let laneWidth = geo.size.width / CGFloat(kLaneCount)
            let tileHeight = laneWidth * tileAspect
            let hitLineY = geo.size.height - hitLineInset

            ZStack {
                Color.black.ignoresSafeArea()

                laneGlows(size: geo.size, laneWidth: laneWidth, hitLineY: hitLineY)
                laneSeparators(size: geo.size, laneWidth: laneWidth)

                fallingTiles(laneWidth: laneWidth, tileHeight: tileHeight, hitLineY: hitLineY)

                hitLine(width: geo.size.width, y: hitLineY)

                // Tap-/hold-områder (et pr. bane, så flere fingre kan ramme samtidig)
                HStack(spacing: 0) {
                    ForEach(0..<kLaneCount, id: \.self) { lane in
                        LaneTouchArea(
                            onDown: {
                                pressedLanes[lane] = true
                                engine.touchDown(lane: lane)
                            },
                            onUp: {
                                pressedLanes[lane] = false
                                engine.touchUp(lane: lane)
                            }
                        )
                    }
                }

                hud

                missVignette
            }
        }
        .navigationBarBackButtonHidden(true)
        .onChange(of: engine.combo) { _, _ in pulseCombo() }
        .onChange(of: engine.lives) { old, new in if new < old { flashMiss() } }
        .onChange(of: engine.isFinished) { _, finished in
            if finished {
                teardown()
                record = HighscoreStore.submit(score: engine.score, trackID: track.id, difficulty: difficulty)
                showResult = true
            }
        }
        .fullScreenCover(isPresented: $showResult) {
            ResultView(track: track, score: engine.score, maxCombo: engine.maxCombo,
                       bestScore: record.best, isNewRecord: record.isNewRecord, didWin: engine.didWin,
                       onDone: {
                           showResult = false
                           dismiss()
                       },
                       onReplay: {
                           showResult = false
                           startGame()
                       })
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { quit() } label: { Label("Stop", systemImage: "xmark") }
            }
        }
        .onAppear { startGame() }
        .onDisappear { teardown() }
    }

    // MARK: - Faldende tiles + hold + hit-effekter

    private func fallingTiles(laneWidth: CGFloat, tileHeight: CGFloat, hitLineY: CGFloat) -> some View {
        // Snapshot af motorens tilstand – Canvas-closuren kan ikke tilgå den
        // @MainActor-isolerede engine direkte, så vi læser værdierne her.
        let currentTime = engine.currentTime
        let approach = engine.approachDuration
        let tiles = engine.tiles
        let effects = engine.hitEffects
        let colors = laneColors

        return Canvas { context, size in
            let pxPerSec = (hitLineY + tileHeight) / approach
            // y for et punkt der skal krydse hit-linjen til tidspunktet ct.
            let yAt: (Double) -> CGFloat = { ct in
                hitLineY - CGFloat(ct - currentTime) * pxPerSec
            }

            // 1) Tiles (ramte/missede vises ikke – hit-effekten overtager)
            for tile in tiles where tile.state == .pending || tile.state == .holding {
                let x = CGFloat(tile.lane) * laneWidth
                let color = colors[tile.lane]

                if tile.isHold {
                    GameView.drawHold(tile, in: context, x: x, laneWidth: laneWidth,
                                      tileHeight: tileHeight, hitLineY: hitLineY, yAt: yAt, color: color)
                } else {
                    let centerY = yAt(tile.time)
                    guard centerY > -tileHeight, centerY < size.height + tileHeight else { continue }
                    let rect = CGRect(x: x + 4, y: centerY - tileHeight / 2,
                                      width: laneWidth - 8, height: tileHeight)
                    GameView.fill(context, Path(roundedRect: rect, cornerRadius: 12), color: color)
                }
            }

            // 2) Hit-effekter: en lysende ring der vokser og fader ved hit-linjen.
            for effect in effects {
                let progress = (currentTime - effect.time) / 0.35
                guard progress >= 0, progress <= 1 else { continue }
                let x = CGFloat(effect.lane) * laneWidth
                let inset = 4 - CGFloat(progress) * 10        // breder sig udad
                let rect = CGRect(x: x + inset, y: hitLineY - tileHeight / 2 - CGFloat(progress) * 12,
                                  width: laneWidth - inset * 2,
                                  height: tileHeight + CGFloat(progress) * 24)
                var ring = context
                ring.opacity = 1 - progress
                let glow = effect.perfect ? Color.white : colors[effect.lane]
                ring.addFilter(.blur(radius: 6))
                ring.stroke(Path(roundedRect: rect, cornerRadius: 16),
                            with: .color(glow), lineWidth: 4)
            }
        }
        .allowsHitTesting(false)
    }

    /// Tegner en hold-tile som en aflang bjælke. Mens den holdes, "spises" den
    /// nedefra, så halen falder ned mod hit-linjen indtil tonen er færdig.
    private static func drawHold(_ tile: Tile, in context: GraphicsContext, x: CGFloat, laneWidth: CGFloat,
                                 tileHeight: CGFloat, hitLineY: CGFloat, yAt: (Double) -> CGFloat, color: Color) {
        let headY = tile.state == .holding ? hitLineY : yAt(tile.time)
        let tailY = yAt(tile.endTime)
        let top = min(headY, tailY) - tileHeight / 2
        let bottom = max(headY, tailY) + tileHeight / 2
        guard bottom > 0 else { return }

        let rect = CGRect(x: x + 8, y: top, width: laneWidth - 16, height: bottom - top)
        let path = Path(roundedRect: rect, cornerRadius: laneWidth / 2 - 8)

        if tile.state == .holding {
            // Lys, glødende bjælke mens man holder.
            var glow = context
            glow.addFilter(.blur(radius: 8))
            glow.fill(path, with: .color(color.opacity(0.6)))
            context.fill(path, with: .linearGradient(
                Gradient(colors: [.white, color]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        } else {
            context.fill(path, with: .linearGradient(
                Gradient(colors: [color.opacity(0.9), color.opacity(0.45)]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            context.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 1.5)
        }
    }

    private static func fill(_ context: GraphicsContext, _ path: Path, color: Color) {
        context.fill(path, with: .linearGradient(
            Gradient(colors: [color.opacity(0.95), color.opacity(0.6)]),
            startPoint: CGPoint(x: path.boundingRect.midX, y: path.boundingRect.minY),
            endPoint: CGPoint(x: path.boundingRect.midX, y: path.boundingRect.maxY)))
        context.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 1)
    }

    // MARK: - Baner

    /// Lysende glød i en bane mens en finger holder den nede.
    private func laneGlows(size: CGSize, laneWidth: CGFloat, hitLineY: CGFloat) -> some View {
        ZStack {
            ForEach(0..<kLaneCount, id: \.self) { lane in
                LinearGradient(colors: [laneColors[lane].opacity(0), laneColors[lane].opacity(0.45)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: laneWidth, height: size.height)
                    .position(x: laneWidth * (CGFloat(lane) + 0.5), y: size.height / 2)
                    .opacity(pressedLanes[lane] ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: pressedLanes[lane])
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
            .shadow(color: .white.opacity(0.6), radius: 6)
            .allowsHitTesting(false)
    }

    // MARK: - HUD

    private var hud: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(engine.score)")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(value: Double(engine.score)))
                        .animation(.snappy, value: engine.score)
                    if engine.combo > 1 {
                        Text("Combo ×\(engine.combo)")
                            .font(.headline).foregroundStyle(.yellow)
                            .scaleEffect(comboScale)
                    }
                }
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0..<GameEngine.startingLives, id: \.self) { i in
                        Image(systemName: i < engine.lives ? "heart.fill" : "heart")
                            .foregroundStyle(.red)
                            .scaleEffect(i < engine.lives ? 1 : 0.85)
                            .animation(.bouncy, value: engine.lives)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if let judgement = engine.lastJudgement {
                Text(judgement.rawValue)
                    .font(.title.weight(.black))
                    .foregroundStyle(judgement == .miss ? .red : .green)
                    .shadow(radius: 4)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
                    .id("\(engine.score)-\(engine.lives)") // re-trigger ved hvert hit/miss
            }
            Spacer()
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: engine.lastJudgement)
        .allowsHitTesting(false)
    }

    /// Rød kant-flash når man misser.
    private var missVignette: some View {
        Rectangle()
            .stroke(Color.red, lineWidth: 14)
            .blur(radius: 12)
            .ignoresSafeArea()
            .opacity(missFlash ? 0.8 : 0)
            .allowsHitTesting(false)
    }

    // MARK: - Animationshjælpere

    private func pulseCombo() {
        comboScale = 1.35
        withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { comboScale = 1 }
    }

    private func flashMiss() {
        missFlash = true
        withAnimation(.easeOut(duration: 0.4)) { missFlash = false }
    }

    // MARK: - Livscyklus

    private func startGame() {
        engine.load(beatmap: beatmap, difficulty: difficulty, onHit: nil)
        playback.onPlaybackStarted = {
            engine.startClock()
        }
        playback.begin()
    }

    private func teardown() {
        engine.stop()
        playback.pause()
        playback.onPlaybackStarted = nil
    }

    private func quit() {
        teardown()
        dismiss()
    }
}

/// Et berøringsfelt for én bane. Skelner mellem tryk-ned og slip,
/// så hold-tiles kan håndteres, og flere fingre kan bruges samtidig.
private struct LaneTouchArea: View {
    let onDown: () -> Void
    let onUp: () -> Void
    @State private var isPressed = false

    var body: some View {
        Color.white.opacity(0.001)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed { isPressed = true; onDown() }
                    }
                    .onEnded { _ in
                        isPressed = false; onUp()
                    }
            )
    }
}
