import Foundation

/// Antal kolonner (lanes) i spillet.
let kLaneCount = 4

/// Status for en enkelt tile under spillet.
enum TileState {
    case pending   // falder ned, endnu ikke ramt
    case hit       // ramt korrekt
    case missed    // passerede hit-linjen uden et tryk
}

/// En enkelt tile i et beatmap.
struct Tile: Identifiable {
    let id = UUID()
    let lane: Int        // 0 ..< kLaneCount
    let time: Double     // tidspunkt (sekunder) hvor den skal rammes
    var state: TileState = .pending
}

/// Et beatmap er en tidsordnet liste af tiles for en bestemt sang.
struct Beatmap {
    let bpm: Double
    let tiles: [Tile]

    /// Sidste tidspunkt hvor noget sker — bruges til at afgøre hvornår spillet er slut.
    var endTime: Double { (tiles.map(\.time).max() ?? 0) + 2.0 }
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

        // Start lidt inde i sangen så intro ikke straffer spilleren, og stop før outro.
        let start = max(1.0, secondsPerBeat * 2)
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
            tiles.append(Tile(lane: lane, time: t))
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
