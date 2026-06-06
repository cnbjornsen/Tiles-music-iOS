import Foundation

/// En playliste fra brugerens Spotify-bibliotek.
struct Playlist: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let trackCount: Int
    let artworkURL: URL?
    let ownerName: String

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name

        let tracks = json["tracks"] as? [String: Any]
        self.trackCount = (tracks?["total"] as? Int) ?? 0

        let images = (json["images"] as? [[String: Any]]) ?? []
        let artworkString = images.first?["url"] as? String
        self.artworkURL = artworkString.flatMap(URL.init(string:))

        let owner = json["owner"] as? [String: Any]
        self.ownerName = (owner?["display_name"] as? String) ?? "Spotify"
    }
}
