import Foundation
import QuartzCore
import Combine

/// Spillets motor: holder styr på tid, tiles, point, combo og liv.
/// Drives af en CADisplayLink, så bevægelse og miss-detektion følger skærmens opdatering.
@MainActor
final class GameEngine: NSObject, ObservableObject {

    // Offentlig tilstand (UI observerer ændringer)
    @Published private(set) var score = 0
    @Published private(set) var combo = 0
    @Published private(set) var maxCombo = 0
    @Published private(set) var lives = startingLives
    @Published private(set) var isFinished = false
    @Published private(set) var didWin = false
    @Published private(set) var lastJudgement: Judgement?

    /// Aktuel tid i sangen (sekunder). Bruges af viewet til at placere tiles.
    private(set) var currentTime: Double = 0

    private(set) var beatmap = Beatmap(bpm: 120, tiles: [])
    private(set) var approachDuration: Double = 1.5
    private(set) var tiles: [Tile] = []

    /// Kortvarige visuelle effekter ved hit (bruges til "pop"-animationen).
    private(set) var hitEffects: [HitEffect] = []

    /// Svævende "+point"-tekster der vises kortvarigt ved hvert hit.
    private(set) var scorePopups: [ScorePopup] = []

    struct HitEffect: Identifiable {
        let id = UUID()
        let lane: Int
        let time: Double
        let perfect: Bool
    }

    struct ScorePopup: Identifiable {
        let id = UUID()
        let lane: Int
        let time: Double
        let points: Int
        let perfect: Bool
    }

    static let startingLives = 5
    private let effectLifetime = 0.35
    private let popupLifetime = 0.8

    // Tidsvinduer for at ramme en tile (sekunder)
    private let perfectWindow = 0.15
    private let goodWindow = 0.40

    private var displayLink: CADisplayLink?
    private var clockStart: CFTimeInterval?
    private var onHit: (() -> Void)?

    enum Judgement: String { case perfect = "Perfekt!", good = "Godt", miss = "Miss" }

    // MARK: - Livscyklus

    func load(beatmap: Beatmap, difficulty: Difficulty, onHit: (() -> Void)?) {
        self.beatmap = beatmap
        self.tiles = beatmap.tiles
        // Hastigheden følger sangens tempo; sværhedsgraden styrer kun antal/typer tiles.
        self.approachDuration = beatmap.approachDuration
        self.onHit = onHit
        score = 0; combo = 0; maxCombo = 0; lives = Self.startingLives
        isFinished = false; didWin = false; lastJudgement = nil
        currentTime = 0
        hitEffects = []
        scorePopups = []
        // Nulstil alle tiles til pending, så et replay starter forfra.
        for index in tiles.indices { tiles[index].state = .pending }
    }

    /// Starter uret. Kald når musikken rent faktisk begynder at spille.
    /// `offset` er sangens aktuelle position (sek.) så uret kan synkroniseres
    /// efter en nedtælling hvor musikken allerede er begyndt.
    func startClock(at offset: Double = 0) {
        guard displayLink == nil else { return }
        clockStart = CACurrentMediaTime() - offset
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Spil-loop

    @objc private func tick() {
        guard let clockStart else { return }
        currentTime = CACurrentMediaTime() - clockStart
        update()

        if lives <= 0 {
            finish(won: false)
        } else if currentTime > beatmap.endTime {
            finish(won: true)
        }
        objectWillChange.send() // få viewet til at gentegne hver frame
    }

    private func update() {
        for index in tiles.indices {
            switch tiles[index].state {
            case .pending:
                // Passerede hit-linjen uden tryk → miss.
                if currentTime - tiles[index].time > goodWindow {
                    tiles[index].state = .missed
                    registerMiss()
                }
            case .holding:
                // Holdt helt til enden → fuldført (selv hvis fingeren stadig er nede).
                if currentTime >= tiles[index].endTime {
                    tiles[index].state = .hit
                    registerHit(perfect: true, lane: tiles[index].lane)
                }
            default:
                break
            }
        }
        // Ryd gamle hit-effekter og score-popups.
        hitEffects.removeAll { currentTime - $0.time > effectLifetime }
        scorePopups.removeAll { currentTime - $0.time > popupLifetime }
    }

    // MARK: - Input (tryk ned / slip)

    /// Fingeren rammer en bane. Starter en tap eller et hold.
    func touchDown(lane: Int) {
        var bestIndex: Int?
        var bestDelta = Double.greatestFiniteMagnitude

        for index in tiles.indices where tiles[index].state == .pending && tiles[index].lane == lane {
            let delta = abs(tiles[index].time - currentTime)
            if delta < bestDelta { bestDelta = delta; bestIndex = index }
        }

        guard let bestIndex, bestDelta <= goodWindow else {
            combo = 0  // tryk uden for ethvert vindue bryder combo
            return
        }

        let isPerfect = bestDelta <= perfectWindow
        if tiles[bestIndex].isHold {
            tiles[bestIndex].state = .holding   // starter holdet – fuldføres ved endTime
        } else {
            tiles[bestIndex].state = .hit
        }
        registerHit(perfect: isPerfect, lane: lane)
    }

    /// Fingeren slipper en bane. Afslutter et evt. igangværende hold.
    func touchUp(lane: Int) {
        guard let index = tiles.firstIndex(where: { $0.state == .holding && $0.lane == lane }) else { return }
        if currentTime >= tiles[index].endTime - goodWindow {
            tiles[index].state = .hit
            registerHit(perfect: true, lane: lane)   // sluppet på rette tid
        } else {
            tiles[index].state = .missed             // sluppet for tidligt
            registerMiss()
        }
    }

    // MARK: - Scoring

    private func registerHit(perfect: Bool, lane: Int) {
        combo += 1
        maxCombo = max(maxCombo, combo)
        let base = perfect ? 100 : 50
        let multiplier = 1 + combo / 10            // combo giver bonus
        let gained = base * multiplier
        score += gained
        lastJudgement = perfect ? .perfect : .good
        hitEffects.append(HitEffect(lane: lane, time: currentTime, perfect: perfect))
        scorePopups.append(ScorePopup(lane: lane, time: currentTime, points: gained, perfect: perfect))
        onHit?()
    }

    private func registerMiss() {
        combo = 0
        lives -= 1
        lastJudgement = .miss
    }

    private func finish(won: Bool) {
        guard !isFinished else { return }
        isFinished = true
        didWin = won
        stop()
    }
}
