import SwiftUI

/// Hjemmeskærm efter login: vælg hvad du vil – Spotify-bibliotek, egen musik,
/// highscores – eller log ud.
struct HomeView: View {
    let api: SpotifyAPI
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject private var auth: SpotifyAuthManager

    @State private var showLocalMusic = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.12),
                                        Color(red: 0.10, green: 0.02, blue: 0.20)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                VStack(spacing: 28) {
                    Spacer()

                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 76, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: [.cyan, .purple],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("Tiles Music")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))

                    Spacer()

                    VStack(spacing: 16) {
                        NavigationLink {
                            LibraryView(api: api, playback: playback)
                        } label: {
                            menuLabel("Vælg en sang fra Spotify", icon: "music.note.list",
                                      tint: Color(red: 0.11, green: 0.73, blue: 0.33))
                        }

                        Button {
                            showLocalMusic = true
                        } label: {
                            menuLabel("Spil din egen musik", icon: "folder.fill", tint: .blue)
                        }

                        NavigationLink {
                            HighscoresView()
                        } label: {
                            menuLabel("Highscores", icon: "trophy.fill", tint: .orange)
                        }
                    }
                    .padding(.horizontal, 32)

                    Spacer()

                    Button("Log ud") { auth.logout() }
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))

                    Spacer()
                }
            }
            .fullScreenCover(isPresented: $showLocalMusic) { LocalMusicView() }
        }
    }

    private func menuLabel(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 30)
            Text(title)
                .font(.headline)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.4))
        }
        .foregroundStyle(.white)
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .background(tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.5), lineWidth: 1))
    }
}
