import SwiftUI

/// Browse Spotify-biblioteket og vælg en sang at spille.
struct LibraryView: View {
    let api: SpotifyAPI
    @ObservedObject var playback: PlaybackController
    @EnvironmentObject private var auth: SpotifyAuthManager

    enum Source: String, CaseIterable, Identifiable {
        case top = "Mest spillede"
        case liked = "Gemte"
        case playlists = "Playlister"
        var id: String { rawValue }
    }

    @State private var source: Source = .top
    @State private var tracks: [Track] = []
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Kilde", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                content
            }
            .navigationTitle("Vælg en sang")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log ud") { auth.logout() }
                }
            }
            .task(id: source) { await reload() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer(); ProgressView("Henter fra Spotify…"); Spacer()
        } else if let errorText {
            Spacer()
            ContentUnavailableView("Kunne ikke hente", systemImage: "wifi.slash", description: Text(errorText))
            Spacer()
        } else {
            switch source {
            case .playlists:
                List(playlists) { playlist in
                    NavigationLink {
                        PlaylistTracksView(api: api, playback: playback, playlist: playlist)
                    } label: {
                        PlaylistRow(playlist: playlist)
                    }
                }
                .listStyle(.plain)
            case .top, .liked:
                List(tracks) { track in
                    NavigationLink {
                        GameSetupView(track: track, playback: playback, api: api)
                    } label: {
                        TrackRow(track: track)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func reload() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            switch source {
            case .top: tracks = try await api.topTracks()
            case .liked: tracks = try await api.savedTracks()
            case .playlists: playlists = try await api.userPlaylists()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Sangene i en valgt playliste.
struct PlaylistTracksView: View {
    let api: SpotifyAPI
    @ObservedObject var playback: PlaybackController
    let playlist: Playlist

    @State private var tracks: [Track] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Henter sange…")
            } else {
                List(tracks) { track in
                    NavigationLink {
                        GameSetupView(track: track, playback: playback, api: api)
                    } label: {
                        TrackRow(track: track)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
        .task {
            tracks = (try? await api.tracks(inPlaylist: playlist.id)) ?? []
            isLoading = false
        }
    }
}

// MARK: - Rækker

struct TrackRow: View {
    let track: Track
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.artworkURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: playlist.artworkURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(playlist.trackCount) sange · \(playlist.ownerName)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct Artwork: View {
    let url: URL?
    let size: CGFloat
    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.gray.opacity(0.3))
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
