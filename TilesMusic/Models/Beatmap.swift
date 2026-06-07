import Foundation

/// Antal kolonner (lanes) i spillet.
let kLaneCount = 4

/// Status for en enkelt tile under spillet.
enum TileState {
    case pending   // falder ned, endnu ikke ramt
    case holding   // hold-tile som spilleren holder nede netop nu
    case hit       // ramt korrekt
    case missed    // passerede hit-linjen uden et tryk (eller blev sluppet for tidligt)
}

/// En enkelt tile i et beatmap.
///
/// Hvis `duration > 0` er det en "hold-tile" (lang tone): den skal trykkes ved
/// `time` og holdes nede indtil `endTime`. Ellers er det en almindelig tap-tile.
struct Tile: Identifiable {
    let id = UUID()
    let lane: Int        // 0 ..< kLaneCount
    let time: Double     // tidspunkt (sekunder) hvor hovedet skal rammes
    let duration: Double // 0 = tap-tile, >0 = hold-tile
    var state: TileState = .pending

    var isHold: Bool { duration > 0 }
    var endTime: Double { time + duration }

    init(lane: Int, time: Double, duration: Double = 0) {
        self.lane = lane
        self.time = time
        self.duration = duration
    }
}

/// Et beatmap er en tidsordnet liste af tiles for en bestemt sang.
struct Beatmap {
    let bpm: Double
    let tiles: [Tile]

    /// Sidste tidspunkt hvor noget sker — bruges til at afgøre hvornår spillet er slut.
    var endTime: Double { (tiles.map(\.endTime).max() ?? 0) + 2.0 }
}

/// Sværhedsgrad styrer hvor mange tiles der genereres pr. takt.
enum Difficulty: String, CaseIterable, Identifiable {
    case easy = "Let"
    case medium = "Mellem"
    case hard = "Svær"

    var id: String { rawValue }

    /// Hvor mange tiles pr. beat. Easy = en hver anden beat, Hard = to pr. beat.
    var tilesPerBeat: Double {
        switch self {
        case .easy: return 0.5
        case .medium: return 1.0
        case .hard: return 2.0
        }
    }

    /// Tid (sekunder) en tile er synlig mens den falder. Hurtigere = sværere.
    var approachDuration: Double {
        switch self {
        case .easy: return 1.9
        case .medium: return 1.5
        case .hard: return 1.15
        }
    }

    /// Sandsynlighed (0–1) for at en tile bliver en hold-tile.
    var holdChance: Double {
        switch self {
        case .easy: return 0.08
        case .medium: return 0.16
        case .hard: return 0.24
        }
    }

    /// Sandsynlighed (0–1) for at to tiles falder samtidig (akkord – fx to baner ved siden af hinanden).
    var chordChance: Double {
        switch self {
        case .easy: return 0.0
        case .medium: return 0.12
        case .hard: return 0.28
        }
    }
}

/// Genererer et beatmap proceduremæssigt ud fra tempo (BPM) og varighed.
///
/// Vi har ikke adgang til præcise node-timings fra Spotify, så vi lægger tiles
/// på et regelmæssigt rytmisk grid afledt af sangens BPM. En seedet
/// tilfældighedsgenerator sikrer at den samme sang altid giver det samme mønster.
enum BeatmapGenerator {

    static func make(bpm: Double, durationSeconds: Double, difficulty: Difficulty, seed: UInt64) -> Beatmap {
        let safeBPM = (bpm > 30 && bpm < 260) ? bpm : 120
        let secondsPerBeat = 60.0 / safeBPM
        let interval = secondsPerBeat / difficulty.tilesPerBeat

        var rng = SeededGenerator(seed: seed)
        var tiles: [Tile] = []

        // Start efter nedtællingen (~2.85 s) + approachDuration så den første tile
        // begynder at falde præcis når spillet starter, og aldrig før musikken er begyndt.
        let start = max(3.6 + difficulty.approachDuration, secondsPerBeat * 4)
        let end = max(start, durationSeconds - 1.5)

        var t = start
        var lastLane = -1
        while t < end {
            // Undgå at den samme lane gentages to gange i træk (føles mere naturligt).
            var lane = Int(rng.next() % UInt64(kLaneCount))
            if lane == lastLane {
                lane = (lane + 1) % kLaneCount
            }
            lastLane = lane

            // Indimellem en hold-tile på 2–4 beats. Vi springer frem forbi holdets
            // varighed, så banen er "optaget" af den lange tone imens.
            let roll = Double(rng.next() % 1000) / 1000.0
            if roll < difficulty.holdChance {
                let beats = 2 + Int(rng.next() % 3)        // 2, 3 eller 4 beats
                let holdDuration = secondsPerBeat * Double(beats)
                if t + holdDuration < end {
                    tiles.append(Tile(lane: lane, time: t, duration: holdDuration))
                    t += holdDuration + interval
                    continue
                }
            }

            tiles.append(Tile(lane: lane, time: t))

            // Indimellem en akkord: en ekstra tap-tile i en bane med mindst
            // én fri bane imellem (aldrig to tiles direkte ved siden af hinanden).
            let chordRoll = Double(rng.next() % 1000) / 1000.0
            if chordRoll < difficulty.chordChance {
                let candidates = (0..<kLaneCount).filter { abs($0 - lane) >= 2 }
                if !candidates.isEmpty {
                    let second = candidates[Int(rng.next() % UInt64(candidates.count))]
                    tiles.append(Tile(lane: second, time: t))
                    lastLane = second
                }
            }

            t += interval
        }

        return Beatmap(bpm: safeBPM, tiles: tiles)
    }
}

/// Lille deterministisk RNG (SplitMix64), så et seed altid giver samme beatmap.
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed != 0 ? seed : 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Laver et stabilt seed ud fra et track-id.
func seed(forTrackID id: String) -> UInt64 {
    var hash: UInt64 = 1469598103934665603 // FNV-1a offset basis
    for byte in id.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211
    }
    return hash
}
