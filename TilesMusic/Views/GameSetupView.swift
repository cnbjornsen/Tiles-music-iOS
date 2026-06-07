import SwiftUI

/// Skærm hvor man vælger sværhedsgrad og starter spillet for en valgt sang.
struct GameSetupView: View {
    let track: Track
    @ObservedObject var playback: PlaybackController
    let api: SpotifyAPI

    @State private var difficulty: Difficulty = .medium
    @State private var beatmap: Beatmap?
    @State private var isPreparing = false
    @State private var goToGame = false
    @State private var bestScore: Int = 0

    var body: some View {
        VStack(spacing: 24) {
            Artwork(url: track.artworkURL, size: 180)
                .shadow(radius: 12)

            VStack(spacing: 4) {
                Text(track.name).font(.title2.bold()).multilineTextAlignment(.center)
                Text(track.artist).font(.headline).foregroundStyle(.secondary)
            }

            Picker("Sværhedsgrad", selection: $difficulty) {
                ForEach(Difficulty.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Label(bestScore > 0 ? "Rekord: \(bestScore)" : "Ingen rekord endnu",
                  systemImage: bestScore > 0 ? "trophy.fill" : "trophy")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(bestScore > 0 ? .yellow : .secondary)

            Text("Tiles falder i takt med sangens tempo. Tryk i den rigtige bane lige når tilen rammer linjen. Lange tiles (hold-tiles) skal holdes nede til de er færdige.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task { await prepareAndStart() }
            } label: {
                Group {
                    if isPreparing {
                        ProgressView().tint(.white)
                    } else {
                        Label("Spil", systemImage: "play.fill").font(.title3.bold())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .background(Color(red: 0.11, green: 0.73, blue: 0.33), in: Capsule())
            .foregroundStyle(.white)
            .padding(.horizontal, 40)
            .disabled(isPreparing)

            Spacer()
        }
        .padding(.top, 32)
        .navigationTitle("Klar?")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            bestScore = HighscoreStore.best(trackID: track.id, difficulty: difficulty)
        }
        .task(id: difficulty) {
            bestScore = HighscoreStore.best(trackID: track.id, difficulty: difficulty)
        }
        .navigationDestination(isPresented: $goToGame) {
            if let beatmap {
                GameView(track: GameTrack(track), beatmap: beatmap, difficulty: difficulty, playback: playback)
            }
        }
    }

    private func prepareAndStart() async {
        isPreparing = true
        defer { isPreparing = false }

        // Hent tempo hvis muligt; ellers bruges sværhedsgradens standard via generatoren.
        let bpm = await api.tempo(forTrack: track.id) ?? 0
        beatmap = BeatmapGenerator.make(
            bpm: bpm,
            durationSeconds: track.durationSeconds > 0 ? track.durationSeconds : 120,
            difficulty: difficulty,
            seed: seed(forTrackID: track.id)
        )
        playback.prepare(track: track)   // vælg sangen App Remote skal spille
        goToGame = true
    }
}
