import SwiftUI

@main
struct TilesMusicApp: App {
    @StateObject private var auth = SpotifyAuthManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Spotify App Remote afslutter sin opkobling via dette callback.
                    NotificationCenter.default.post(name: .spotifyCallbackURL, object: url)
                }
        }
    }
}

extension Notification.Name {
    static let spotifyCallbackURL = Notification.Name("spotifyCallbackURL")
}
