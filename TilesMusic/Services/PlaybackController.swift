import Foundation

/// Styrer afspilning af den valgte Spotify-sang under spillet.
///
/// VIGTIGT: Faktisk afspilning kræver Spotify iOS SDK (SpotifyiOS.xcframework)
/// OG Spotify Premium OG at Spotify-appen er installeret på enheden.
/// Se README for hvordan du tilføjer frameworket.
///
/// Hvis frameworket ikke er tilføjet, kompilerer appen stadig og spillet kan
/// spilles uden Spotify-lyd (kun klik-feedback). `#if canImport(SpotifyiOS)`
/// sørger for at den rigtige implementering kun bruges når SDK'et er til stede.
@MainActor
final class PlaybackController: NSObject, ObservableObject, GamePlayback {

    enum Status { case disconnected, connecting, playing, paused, failed(String) }

    @Published var status: Status = .disconnected

    /// Kaldes når afspilningen faktisk er begyndt – bruges til at synkronisere spillets ur.
    var onPlaybackStarted: (() -> Void)?

    private let auth: SpotifyAuthManager
    private var pendingURI: String?
    private var queuedTrack: Track?
    private var wantsPause = false

    init(auth: SpotifyAuthManager) {
        self.auth = auth
        super.init()
        setup()
    }

    /// Vælg sangen der skal spilles, før spillet starter (GamePlayback-flow).
    func prepare(track: Track) { queuedTrack = track }

    /// GamePlayback: start afspilning af den valgte sang.
    func begin() { if let track = queuedTrack { play(track: track) } }

    /// Skal kaldes fra `onOpenURL` så App Remote kan afslutte sin opkobling.
    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        handleAuthCallback(url)
    }

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

    func startPlayback(uri: String, accessToken: String?) {
        pendingURI = uri
        wantsPause = false
        if let accessToken {
            appRemote.connectionParameters.accessToken = accessToken
        }
        // Er vi allerede forbundet (fx replay eller ny runde med samme sang),
        // genstarter vi sangen fra begyndelsen via playerAPI i stedet for at
        // skifte til Spotify-appen igen.
        if appRemote.isConnected, let playerAPI = appRemote.playerAPI {
            status = .playing
            playerAPI.play(uri, callback: { [weak self] _, _ in
                Task { @MainActor in self?.onPlaybackStarted?() }
            })
        } else {
            // Første gang: vækker Spotify-appen, starter sangen og kobler App Remote op.
            status = .connecting
            appRemote.authorizeAndPlayURI(uri)
        }
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
        // Hvis App Remote endnu ikke er forbundet, husk ønsket og pause når
        // forbindelsen er etableret, så musikken ikke fortsætter efter spillet.
        if appRemote.isConnected, let playerAPI = appRemote.playerAPI {
            playerAPI.pause(nil)
            wantsPause = false
        } else {
            wantsPause = true
        }
    }
    func resumePlayback() { appRemote.playerAPI?.resume(nil) }

    func teardown() {
        if appRemote.isConnected {
            appRemote.playerAPI?.pause(nil)
            appRemote.disconnect()
        }
        wantsPause = false
        status = .disconnected
    }

    // MARK: SPTAppRemoteDelegate

    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            appRemote.playerAPI?.delegate = self
            appRemote.playerAPI?.subscribe(toPlayerState: nil)
            if wantsPause {
                appRemote.playerAPI?.pause(nil)
                wantsPause = false
                return
            }
            if let uri = pendingURI {
                appRemote.playerAPI?.play(uri, callback: { [weak self] _, _ in
                    Task { @MainActor in
                        self?.status = .playing
                        self?.onPlaybackStarted?()
                    }
                })
            }
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor [weak self] in
            self?.status = .failed(error?.localizedDescription ?? "Kunne ikke forbinde til Spotify.")
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor [weak self] in self?.status = .disconnected }
    }

    // MARK: SPTAppRemotePlayerStateDelegate

    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        Task { @MainActor [weak self] in
            self?.status = playerState.isPaused ? .paused : .playing
        }
    }
}

#else

// MARK: - Fallback UDEN Spotify SDK (spillet kører, men uden Spotify-lyd)

extension PlaybackController {
    func setup() {}

    func startPlayback(uri: String, accessToken: String?) {
        // SDK ikke tilføjet endnu – start spillet med det samme uden Spotify-lyd.
        status = .playing
        onPlaybackStarted?()
    }

    func handleAuthCallback(_ url: URL) -> Bool { false }
    func pausePlayback() { status = .paused }
    func resumePlayback() { status = .playing }
    func teardown() { status = .disconnected }
}

#endif
