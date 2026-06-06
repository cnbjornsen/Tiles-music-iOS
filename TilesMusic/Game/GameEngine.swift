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

    static let startingLives = 5

    // Tidsvinduer for at ramme en tile (sekunder)
    private let perfectWindow = 0.09
    private let goodWindow = 0.20

    private var displayLink: CADisplayLink?
    private var clockStart: CFTimeInterval?
    private var onHit: (() -> Void)?

    enum Judgement: String { case perfect = "Perfekt!", good = "Godt", miss = "Miss" }

    // MARK: - Livscyklus

    func load(beatmap: Beatmap, difficulty: Difficulty, onHit: @escaping () -> Void) {
        self.beatmap = beatmap
        self.tiles = beatmap.tiles
        self.approachDuration = difficulty.approachDuration
        self.onHit = onHit
        score = 0; combo = 0; maxCombo = 0; lives = Self.startingLives
        isFinished = false; didWin = false; lastJudgement = nil
        currentTime = 0
    }

    /// Starter uret. Kald når Spotify rent faktisk begynder at spille.
    func startClock() {
        guard displayLink == nil else { return }
        clockStart = CACurrentMediaTime()
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
        detectMisses()

        if lives <= 0 {
            finish(won: false)
        } else if currentTime > beatmap.endTime {
            finish(won: true)
        }
        objectWillChange.send() // få viewet til at gentegne hver frame
    }

    private func detectMisses() {
        for index in tiles.indices where tiles[index].state == .pending {
            if currentTime - tiles[index].time > goodWindow {
                tiles[index].state = .missed
                registerMiss()
            }
        }
    }

    /// Brugeren har trykket i en bane. Find den nærmeste tile der kan rammes.
    func tap(lane: Int) {
        var bestIndex: Int?
        var bestDelta = Double.greatestFiniteMagnitude

        for index in tiles.indices where tiles[index].state == .pending && tiles[index].lane == lane {
            let delta = abs(tiles[index].time - currentTime)
            if delta < bestDelta { bestDelta = delta; bestIndex = index }
        }

        guard let bestIndex, bestDelta <= goodWindow else {
            // Tryk uden for ethvert vindue: bryd combo som lille straf.
            combo = 0
            return
        }

        tiles[bestIndex].state = .hit
        let isPerfect = bestDelta <= perfectWindow
        combo += 1
        maxCombo = max(maxCombo, combo)
        let base = isPerfect ? 100 : 50
        let multiplier = 1 + combo / 10            // combo giver bonus
        score += base * multiplier
        lastJudgement = isPerfect ? .perfect : .good
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
