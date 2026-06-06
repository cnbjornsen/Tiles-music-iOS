import Foundation

/// Gemmer lokale rekorder pr. sang og sværhedsgrad i UserDefaults.
/// Udover den bedste score gemmes sangens navn/kunstner, så de kan vises på
/// en samlet highscore-skærm.
enum HighscoreStore {

    struct Result {
        let best: Int
        let isNewRecord: Bool
    }

    /// En gemt rekord for én sang på én sværhedsgrad.
    struct Entry: Codable, Identifiable {
        let trackID: String
        let name: String
        let artist: String
        let difficulty: String
        var score: Int
        var date: Date

        var id: String { "\(trackID)|\(difficulty)" }
    }

    private static let storeKey = "highscores.entries"

    // MARK: - Læsning

    /// Bedste score for en sang på en given sværhedsgrad (0 hvis ingen endnu).
    static func best(trackID: String, difficulty: Difficulty) -> Int {
        all().first { $0.trackID == trackID && $0.difficulty == difficulty.rawValue }?.score ?? 0
    }

    /// Alle rekorder, sorteret med højeste score først.
    static func all() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries.sorted { $0.score > $1.score }
    }

    // MARK: - Skrivning

    /// Indsender en score. Returnerer den gældende rekord, og om den lige blev slået.
    @discardableResult
    static func submit(score: Int, track: GameTrack, difficulty: Difficulty) -> Result {
        var entries = all()
        let entryID = "\(track.id)|\(difficulty.rawValue)"

        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            let previous = entries[index].score
            if score > previous {
                entries[index].score = score
                entries[index].date = Date()
                save(entries)
                return Result(best: score, isNewRecord: true)
            }
            return Result(best: previous, isNewRecord: false)
        } else {
            let entry = Entry(trackID: track.id, name: track.name, artist: track.artist,
                              difficulty: difficulty.rawValue, score: score, date: Date())
            entries.append(entry)
            save(entries)
            return Result(best: score, isNewRecord: true)
        }
    }

    /// Sletter alle rekorder.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    private static func save(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
