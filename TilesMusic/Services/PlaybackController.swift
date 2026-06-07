import Foundation

/// Styrer afspilning af den valgte Spotify-sang under spillet.
///
/// Strategi: Spotify Web API bruges til pause og play (pålidelig, virker uanset om
/// App Remote socket er oppe). App Remote bruges som sekundær kanal til
/// real-tids position og onPlaybackStarted-callback.
@MainActor
final class PlaybackController: NSObject, ObservableObject, GamePlayback {

    enum Status { case disconnected, connecting, playing, paused, failed(String) }

    @Published var status: Status = .disconnected

    var onPlaybackStarted: (() -> Void)?

    private let auth: SpotifyAuthManager
    private var pendingURI: String?
    private var queuedTrack: Track?
    private var wantsPause = false
    private var playbackStartedFired = false
    private var pauseTask: Task<Void, Never>?

    init(auth: SpotifyAuthManager) {
        self.auth = auth
        super.init()
        setup()
    }

    func prepare(track: Track) { queuedTrack = track }
    func begin() { if let track = queuedTrack { play(track: track) } }

    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool { handleAuthCallback(url) }

    func play(track: Track) {
        Task {
            let token = try? await auth.validAccessToken()
            startPlayback(uri: track.uri, accessToken: token)
        }
    }

    func pause() { pausePlayback() }
    func resume() { resumePlayback() }
    func disconnect() { teardown() }
}

// MARK: - Implementering MED Spotify SDK

#if canImport(SpotifyiOS)
@preconcurrency import SpotifyiOS

extension PlaybackController: SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {

    private static var appRemoteKey = 0

    private var appRemote: SPTAppRemote {
        if let existing = objc_getAssociatedObject(self, &Self.appRemoteKey) as? SPTAppRemote {
            return existing
        }
        let configuration = SPTConfiguration(clientID: SpotifyConfig.clientID,
                                             redirectURL: URL(string: SpotifyConfig.redirectURI)!)
        let remote = SPTAppRemote(configuration: configuration, logLevel: .info)
        remote.delegate = self
        objc_setAssociatedObject(self, &Self.appRemoteKey, remote, .OBJC_ASSOCIATION_RETAIN)
        return remote
    }

    func setup() {
        NotificationCenter.default.addObserver(
            forName: .spotifyCallbackURL, object: nil, queue: .main) { [weak self] note in
                guard let url = note.object as? URL else { return }
                Task { @MainActor in self?.handleOpenURL(url) }
        }
    }

    // MARK: - Spotify Web API

    /// PUT /me/player/pause — virker uden App Remote socket (Spotify baggrunds-kompatibel).
    /// Tjekker Task.isCancelled så et hurtigt genstart ikke pauser den nye sang.
    private func webPause() async {
        guard !Task.isCancelled else { return }
        guard let token = try? await auth.validAccessToken() else { return }
        guard !Task.isCancelled else { return }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/pause")!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Afspilning

    func startPlayback(uri: String, accessToken: String?) {
        // Annullér et evt. igangværende webPause-kald så det ikke pauser den nye sang.
        pauseTask?.cancel()
        pauseTask = nil
        pendingURI = uri
        wantsPause = false
        playbackStartedFired = false
        if let accessToken { appRemote.connectionParameters.accessToken = accessToken }

        if appRemote.isConnected, let playerAPI = appRemote.playerAPI {
            // App Remote er forbundet: start direkte (ingen Spotify-flash).
            playerAPI.seek(toPosition: 0, callback: nil)
            playerAPI.play(uri, callback: { [weak self] _, _ in
                Task { @MainActor in self?.notifyPlaybackStarted() }
            })
            return
        }

        // App Remote socket er nede. authorizeAndPlayURI er den eneste pålidelige
        // måde at vække Spotify og rent faktisk starte lyd: den åbner Spotify kort,
        // starter sangen og forbinder App Remote igen. Web API kan IKKE vække en
        // lukket/baggrunds-app – den styrer kun en allerede aktiv enhed.
        status = .connecting
        print("[PC] authorizeAndPlayURI: \(uri)")
        appRemote.authorizeAndPlayURI(uri) { [weak self] success in
            print("[PC] authorizeAndPlayURI callback: success=\(success)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !success {
                    print("[PC] Spotify-appen ikke installeret eller URI afvist")
                    self.status = .failed("Spotify-appen kunne ikke åbnes.")
                    return
                }
                // Fallback hvis App Remote ikke når at melde "spiller" indenfor 4 sek.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                print("[PC] 4s fallback: notifyPlaybackStarted")
                self.notifyPlaybackStarted()
            }
        }
    }

    private func notifyPlaybackStarted() {
        guard !playbackStartedFired else { return }
        playbackStartedFired = true
        status = .playing
        pendingURI = nil
        onPlaybackStarted?()
    }

    func handleAuthCallback(_ url: URL) -> Bool {
        let params = appRemote.authorizationParameters(from: url)
        if params?[SPTAppRemoteAccessTokenKey] != nil {
            // Brug IKKE URL-callback-tokenet: det har begrænset WAMP-autorisation og
            // medfører "not_authorized" på play(uri). PKCE-tokenet (sat i startPlayback)
            // virker for App Remote og har de rette rettigheder.
            print("[PC] handleAuthCallback: connecting with PKCE token")
            appRemote.connect()
            return true
        }
        return false
    }

    func pausePlayback() {
        wantsPause = true
        pauseTask?.cancel()
        pauseTask = Task { await webPause() }
        if appRemote.isConnected { appRemote.playerAPI?.pause(nil) }
        status = .paused
    }

    func resumePlayback() {
        wantsPause = false
        appRemote.playerAPI?.resume(nil)
    }

    func teardown() {
        pendingURI = nil
        pausePlayback()
    }

    // MARK: SPTAppRemoteDelegate

    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        print("[PC] appRemoteDidEstablishConnection")
        Task { @MainActor [weak self] in
            guard let self else { return }
            appRemote.playerAPI?.delegate = self
            // Subscribe – SDK sender øjeblikkeligt den aktuelle spiller-tilstand,
            // så playerStateDidChange(isPaused:false) bruges som præcist startsignal.
            appRemote.playerAPI?.subscribe(toPlayerState: nil)

            if wantsPause {
                print("[PC] wantsPause: pausing")
                appRemote.playerAPI?.pause(nil)
            }
            // Kalder IKKE play(uri) her: authorizeAndPlayURI startede allerede sangen,
            // og play(uri) giver "not_authorized" med URL-callback-tokenet.
            // playerStateDidChange fyrer notifyPlaybackStarted når Spotify melder "spiller".
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor [weak self] in
            self?.status = .disconnected
            // Web API håndterer afspilning og pause – ingen fallback nødvendig her.
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor [weak self] in self?.status = .disconnected }
    }

    // MARK: SPTAppRemotePlayerStateDelegate

    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        print("[PC] playerStateDidChange: isPaused=\(playerState.isPaused)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !playerState.isPaused && !self.wantsPause {
                self.notifyPlaybackStarted()
            }
            status = playerState.isPaused ? .paused : .playing
        }
    }
}

#else

// MARK: - Fallback UDEN Spotify SDK (spillet kører, men uden Spotify-lyd)

extension PlaybackController {
    func setup() {}

    func startPlayback(uri: String, accessToken: String?) {
        status = .playing
        onPlaybackStarted?()
    }

    func handleAuthCallback(_ url: URL) -> Bool { false }
    func pausePlayback() { status = .paused }
    func resumePlayback() { status = .playing }
    func teardown() { status = .paused }
}

#endif
