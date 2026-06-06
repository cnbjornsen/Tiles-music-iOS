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
                    // Auth-code callback (code=) → SPTSessionManager via auth manager.
                    // App Remote callback (access_token=) → PlaybackController via notification.
                    auth.handleOpenURL(url)
                    NotificationCenter.default.post(name: .spotifyCallbackURL, object: url)
                }
        }
    }
}

extension Notification.Name {
    static let spotifyCallbackURL = Notification.Name("spotifyCallbackURL")
}
