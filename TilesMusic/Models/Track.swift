import Foundation

/// En sang fra Spotify, trimmet til det vi har brug for i spillet.
struct Track: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let artist: String
    let uri: String           // fx "spotify:track:..." — bruges til afspilning via App Remote
    let durationMs: Int
    let artworkURL: URL?

    var durationSeconds: Double { Double(durationMs) / 1000.0 }
}

// MARK: - Afkodning fra Spotify Web API

extension Track {
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String,
              let uri = json["uri"] as? String else { return nil }

        let artists = (json["artists"] as? [[String: Any]]) ?? []
        let artistNames = artists.compactMap { $0["name"] as? String }

        let album = json["album"] as? [String: Any]
        let images = (album?["images"] as? [[String: Any]]) ?? []
        let artworkString = images.first?["url"] as? String

        self.id = id
        self.name = name
        self.artist = artistNames.joined(separator: ", ")
        self.uri = uri
        self.durationMs = (json["duration_ms"] as? Int) ?? 0
        self.artworkURL = artworkString.flatMap(URL.init(string:))
    }
}
