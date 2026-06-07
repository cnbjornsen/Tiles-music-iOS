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
    private func webPause() async {
        guard let token = try? await auth.validAccessToken() else { return }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/pause")!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
    }

    /// PUT /me/player/play — starter sangen fra position 0.
    /// Returnerer true hvis Web API lykkedes, false hvis Spotify-appen skal åbnes.
    ///
    /// Hvis der ikke er nogen aktiv enhed (404), slår vi tilgængelige enheder op
    /// og målretter afspilningen til den første – det "vækker" en inaktiv enhed
    /// (fx Spotify-appen i baggrunden) uden at åbne den i forgrunden.
    private func webPlay(uri: String) async -> Bool {
        guard let token = try? await auth.validAccessToken() else { return false }

        if await webPlayRequest(uri: uri, token: token, deviceID: nil) { return true }

        // Ingen aktiv enhed: find en tilgængelig og prøv igen målrettet.
        if let deviceID = await availableDeviceID(token: token) {
            return await webPlayRequest(uri: uri, token: token, deviceID: deviceID)
        }
        return false
    }

    private func webPlayRequest(uri: String, token: String, deviceID: String?) async -> Bool {
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/play")!
        if let deviceID { components.queryItems = [URLQueryItem(name: "device_id", value: deviceID)] }
        var req = URLRequest(url: components.url!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "uris": [uri], "position_ms": 0
        ])
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// GET /me/player/devices — returnerer id på en tilgængelig afspilningsenhed.
    private func availableDeviceID(token: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/devices")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [[String: Any]] else { return nil }
        // Foretræk en aktiv enhed, ellers den første tilgængelige.
        let active = devices.first { ($0["is_active"] as? Bool) == true }
        return (active?["id"] as? String) ?? (devices.first?["id"] as? String)
    }

    // MARK: - Afspilning

    func startPlayback(uri: String, accessToken: String?) {
        pendingURI = uri
        wantsPause = false
        playbackStartedFired = false
        if let accessToken { appRemote.connectionParameters.accessToken = accessToken }

        if appRemote.isConnected, let playerAPI = appRemote.playerAPI {
            // App Remote er forbundet: brug den direkte for præcis callback.
            playerAPI.seek(toPosition: 0, callback: nil)
            playerAPI.play(uri, callback: { [weak self] _, _ in
                Task { @MainActor in self?.notifyPlaybackStarted() }
            })
        } else {
            // App Remote socket er nede – brug Web API og forsøg App Remote i baggrunden.
            status = .connecting
            Task {
                let ok = await webPlay(uri: uri)
                if ok {
                    // Web API lykkedes. App Remote har 2 sek til at tilkoble og
                    // affyre onPlaybackStarted; ellers bruger vi timeren som fallback.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        self?.notifyPlaybackStarted()
                    }
                } else {
                    // Ingen aktiv Spotify-enhed – åbn Spotify-appen som last resort.
                    _ = await appRemote.authorizeAndPlayURI(uri)
                }
            }
            appRemote.connect()
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
        if let token = params?[SPTAppRemoteAccessTokenKey] {
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
            return true
        }
        return false
    }

    func pausePlayback() {
        wantsPause = true
        // Web API pause: øjeblikkelig og pålidelig – kræver ikke App Remote socket.
        Task { await webPause() }
        // Ekstra: pause via App Remote også hvis den er forbundet.
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            appRemote.playerAPI?.delegate = self
            appRemote.playerAPI?.subscribe(toPlayerState: nil)

            if wantsPause {
                appRemote.playerAPI?.pause(nil)
                return
            }
            if let uri = pendingURI {
                // App Remote tilkoblede før timeren: brug den for præcis callback.
                appRemote.playerAPI?.seek(toPosition: 0, callback: nil)
                appRemote.playerAPI?.play(uri, callback: { [weak self] _, _ in
                    Task { @MainActor in self?.notifyPlaybackStarted() }
                })
            }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
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
