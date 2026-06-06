import SwiftUI

@main
struct TilesMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .portrait
    }
}

extension Notification.Name {
    static let spotifyCallbackURL = Notification.Name("spotifyCallbackURL")
}
