import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: SpotifyAuthManager
    @State private var showLocalMusic = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.12),
                                    Color(red: 0.10, green: 0.02, blue: 0.20)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 88, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .purple],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))

                VStack(spacing: 8) {
                    Text("Tiles Music")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                    Text("Ram tilene i takt med dine yndlingssange")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                if !SpotifyConfig.isConfigured {
                    Text("⚠️ Indsæt dit Spotify Client ID i SpotifyConfig.swift for at logge ind.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    auth.login()
                } label: {
                    Label("Log ind med Spotify", systemImage: "music.note")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .background(Color(red: 0.11, green: 0.73, blue: 0.33), in: Capsule())
                .foregroundStyle(.white)
                .padding(.horizontal, 40)
                .disabled(!SpotifyConfig.isConfigured)
                .opacity(SpotifyConfig.isConfigured ? 1 : 0.5)

                if let error = auth.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    showLocalMusic = true
                } label: {
                    Label("Spil din egen musik", systemImage: "folder")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.85))

                Spacer()
            }
            .padding()
        }
        .fullScreenCover(isPresented: $showLocalMusic) { LocalMusicView() }
    }
}
