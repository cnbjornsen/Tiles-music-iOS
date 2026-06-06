import Foundation

/// Gemmer lokale rekorder pr. sang og sværhedsgrad i UserDefaults.
enum HighscoreStore {

    struct Result {
        let best: Int
        let isNewRecord: Bool
    }

    private static func key(trackID: String, difficulty: Difficulty) -> String {
        "highscore.\(trackID).\(difficulty.rawValue)"
    }

    /// Bedste score for en sang på en given sværhedsgrad (0 hvis ingen endnu).
    static func best(trackID: String, difficulty: Difficulty) -> Int {
        UserDefaults.standard.integer(forKey: key(trackID: trackID, difficulty: difficulty))
    }

    /// Indsender en score. Returnerer den gældende rekord, og om den lige blev slået.
    @discardableResult
    static func submit(score: Int, trackID: String, difficulty: Difficulty) -> Result {
        let storageKey = key(trackID: trackID, difficulty: difficulty)
        let previous = UserDefaults.standard.integer(forKey: storageKey)
        if score > previous {
            UserDefaults.standard.set(score, forKey: storageKey)
            return Result(best: score, isNewRecord: true)
        }
        return Result(best: previous, isNewRecord: false)
    }
}
