import Foundation

/// Letvægts-repræsentation af sangen der spilles – bruges til UI og highscore,
/// uafhængigt af hvilken kilde (Spotify / lokal) den kommer fra.
struct GameTrack: Hashable {
    let id: String
    let name: String
    let artist: String
    let artworkURL: URL?

    init(id: String, name: String, artist: String, artworkURL: URL? = nil) {
        self.id = id; self.name = name; self.artist = artist; self.artworkURL = artworkURL
    }

    init(_ track: Track) {
        self.init(id: track.id, name: track.name, artist: track.artist, artworkURL: track.artworkURL)
    }
}

/// Fælles afspilnings-grænseflade, så `GameView` kan drives af både Spotify
/// (App Remote) og lokal lyd (AVPlayer) uden at kende den konkrete type.
@MainActor
protocol GamePlayback: AnyObject {
    /// Kaldes når afspilningen faktisk er begyndt – bruges til at starte spillets ur.
    var onPlaybackStarted: (() -> Void)? { get set }
    /// Start afspilning af den allerede valgte sang.
    func begin()
    /// Pause / stop afspilning.
    func pause()
}
