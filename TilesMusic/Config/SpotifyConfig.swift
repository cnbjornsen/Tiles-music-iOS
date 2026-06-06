import Foundation

/// Central konfiguration af Spotify-integrationen.
///
/// SÅDAN KOMMER DU I GANG:
/// 1. Gå til https://developer.spotify.com/dashboard og log ind.
/// 2. Opret en ny app. Giv den et navn (fx "Tiles Music").
/// 3. Under "Redirect URIs" tilføjer du PRÆCIST:  tilesmusic://callback
/// 4. Under "APIs used" / settings: aktivér "iOS" og indtast dit Bundle ID
///    (standard her er `dk.grafikr.TilesMusic` — ret det hvis du ændrer det i Xcode).
/// 5. Kopiér "Client ID" og indsæt det nedenfor.
///
/// Bemærk: PKCE-flowet bruger IKKE client secret, så det er sikkert at have i appen.
enum SpotifyConfig {

    /// Indsæt dit Client ID fra Spotify Developer Dashboard her.
    static let clientID = "DIT_SPOTIFY_CLIENT_ID"

    /// Skal matche en Redirect URI registreret i dashboardet.
    static let redirectURI = "tilesmusic://callback"

    /// URL-schemet i Redirect URI (registreret i Info.plist under CFBundleURLTypes).
    static let callbackScheme = "tilesmusic"

    /// Rettigheder vi beder brugeren om.
    static let scopes = [
        "user-read-private",
        "user-read-email",
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-library-read",
        "user-top-read",
        "app-remote-control",
        "streaming",
    ]

    static var scopeString: String { scopes.joined(separator: " ") }

    /// True hvis udvikleren har udfyldt sit Client ID.
    static var isConfigured: Bool {
        !clientID.isEmpty && clientID != "DIT_SPOTIFY_CLIENT_ID"
    }

    // Endpoints
    static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    static let apiBaseURL = URL(string: "https://api.spotify.com/v1")!
}
