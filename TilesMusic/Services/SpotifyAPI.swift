import Foundation

/// Klient til Spotify Web API. Henter profil, playlister, sange og tempo.
@MainActor
final class SpotifyAPI {
    private let auth: SpotifyAuthManager

    init(auth: SpotifyAuthManager) {
        self.auth = auth
    }

    // MARK: - Profil

    func currentUserName() async throws -> String {
        let json = try await get("/me")
        return (json["display_name"] as? String) ?? "Spotify-bruger"
    }

    // MARK: - Playlister

    func userPlaylists() async throws -> [Playlist] {
        let json = try await get("/me/playlists", query: ["limit": "50"])
        let items = (json["items"] as? [[String: Any]]) ?? []
        return items.compactMap(Playlist.init(json:))
    }

    func tracks(inPlaylist id: String) async throws -> [Track] {
        let json = try await get("/playlists/\(id)/tracks", query: ["limit": "100"])
        let items = (json["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let trackJSON = item["track"] as? [String: Any] else { return nil }
            return Track(json: trackJSON)
        }
    }

    /// Brugerens gemte sange ("Liked Songs").
    func savedTracks() async throws -> [Track] {
        let json = try await get("/me/tracks", query: ["limit": "50"])
        let items = (json["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let trackJSON = item["track"] as? [String: Any] else { return nil }
            return Track(json: trackJSON)
        }
    }

    /// Brugerens mest spillede sange – god start-liste.
    func topTracks() async throws -> [Track] {
        let json = try await get("/me/top/tracks", query: ["limit": "50", "time_range": "medium_term"])
        let items = (json["items"] as? [[String: Any]]) ?? []
        return items.compactMap(Track.init(json:))
    }

    // MARK: - Tempo

    /// Forsøger at hente sangens tempo (BPM) via audio-features.
    ///
    /// Bemærk: Spotify har begrænset adgang til dette endpoint for nye apps.
    /// Returnerer nil ved fejl, så spillet kan falde tilbage til sværhedsgradens standardtempo.
    func tempo(forTrack id: String) async -> Double? {
        do {
            let json = try await get("/audio-features/\(id)")
            return json["tempo"] as? Double
        } catch {
            return nil
        }
    }

    // MARK: - Lavniveau

    @discardableResult
    private func get(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        let token = try await auth.validAccessToken()
        var components = URLComponents(url: SpotifyConfig.apiBaseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyError.requestFailed(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SpotifyError.requestFailed(http.statusCode)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
