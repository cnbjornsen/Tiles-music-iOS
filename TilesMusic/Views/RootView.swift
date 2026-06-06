import SwiftUI

/// Vælger mellem login og biblioteket alt efter om brugeren er logget ind.
struct RootView: View {
    @EnvironmentObject private var auth: SpotifyAuthManager
    @StateObject private var playback: PlaybackController
    @State private var api: SpotifyAPI?

    init() {
        // Bruger den delte auth-instans, så tokens deles på tværs af appen.
        _playback = StateObject(wrappedValue: PlaybackController(auth: .shared))
    }

    var body: some View {
        Group {
            if auth.isLoggedIn {
                if let api {
                    HomeView(api: api, playback: playback)
                } else {
                    ProgressView().onAppear { api = SpotifyAPI(auth: auth) }
                }
            } else {
                LoginView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spotifyCallbackURL)) { note in
            if let url = note.object as? URL {
                _ = playback.handleOpenURL(url)
            }
        }
    }
}
