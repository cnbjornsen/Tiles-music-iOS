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

    /// URI der skal afspilles ved næste tilkobling. Ryddes så snart afspilningen starter,
    /// så en spontan gen-tilkobling under spillet ikke genstarter sangen.
    private var pendingURI: String?

    /// URI på den senest startede sang – bruges til at tvinge tilkobling for pause.
    private var lastPlayedURI: String?

    private var queuedTrack: Track?
    private var wantsPause = false

    init(auth: SpotifyAuthManager) {
        self.auth = auth
        super.init()
        setup()
    }

    /// Vælg sangen der skal spilles, før spillet starter (GamePlayback-flow).
    func prepare(track: Track) { queuedTrack = track }

    /// GamePlayback: start afspilning af den allerede valgte sang.
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
        lastPlayedURI = uri
        wantsPause = false
        if let accessToken { appRemote.connectionParameters.accessToken = accessToken }

        if appRemote.isConnected, let playerAPI = appRemote.playerAPI {
            // Forbundet: søg til start og afspil direkte – ingen app-skift.
            // seek(toPosition:0) sikrer at replay altid starter forfra, selv
            // hvis den samme sang allerede er loaded i Spotify.
            playerAPI.seek(toPosition: 0, callback: nil)
            playerAPI.play(uri, callback: { [weak self] _, _ in
                Task { @MainActor in self?.notifyPlaybackStarted() }
            })
        } else {
            // Prøv stille tilkobling (ingen app-skift); ved fejl går vi via
            // authorizeAndPlayURI i didFailConnectionAttemptWithError.
            status = .connecting
            appRemote.connect()
        }
    }

    /// Kaldes præcis én gang pr. sang, uanset om App Remote eller `authorizeAndPlayURI` startede den.
    private func notifyPlaybackStarted() {
        status = .playing
        // Ryd pendingURI – en spontan gen-tilkobling under spillet skal
        // IKKE genstarte sangen; den er allerede i gang.
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
        if appRemote.isConnected {
            appRemote.playerAPI?.pause(nil)
        } else if appRemote.connectionParameters.accessToken != nil {
            // Forbindelsen er faldet – forsøg stille gen-tilkobling.
            // Hvis det fejler, tvinger didFail en tilkobling via Spotify-appen.
            appRemote.connect()
        }
    }

    func resumePlayback() {
        wantsPause = false
        appRemote.playerAPI?.resume(nil)
    }

    func teardown() {
        // Ryd pendingURI så gen-tilkobling ikke genstarter sangen.
        pendingURI = nil
        pausePlayback()
        status = .paused
    }

    // MARK: SPTAppRemoteDelegate

    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            appRemote.playerAPI?.delegate = self
            appRemote.playerAPI?.subscribe(toPlayerState: nil)

            if wantsPause {
                // Vil pause: send pause nu. Vi RYDDER IKKE wantsPause her –
                // playerStateDidChange bekræfter at sangen faktisk er pauset.
                // Det fanger kapløbet hvor authorizeAndPlayURI lige har sat
                // sangen i gang igen efter den vækkede Spotify-socketten.
                appRemote.playerAPI?.pause(nil)
                return
            }

            if let uri = pendingURI {
                // pendingURI er sat = sangen er endnu ikke startet. Start den.
                appRemote.playerAPI?.seek(toPosition: 0, callback: nil)
                appRemote.playerAPI?.play(uri, callback: { [weak self] _, _ in
                    Task { @MainActor in self?.notifyPlaybackStarted() }
                })
            }
            // pendingURI = nil = sangen kørte allerede, forbindelsen er
            // gen-etableret under spillet. Ingen handling nødvendig.
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if wantsPause {
                // Stille tilkobling til pause fejlede fordi Spotify-socketten er nede.
                // authorizeAndPlayURI vækker Spotify; det genstarter desværre sangen,
                // men playerStateDidChange sender pause igen indtil den faktisk standser.
                _ = await appRemote.authorizeAndPlayURI(lastPlayedURI ?? "")
                return
            }

            if let uri = pendingURI {
                // Første tilkobling til en ny sang fejlede – åbn Spotify-appen.
                _ = await appRemote.authorizeAndPlayURI(uri)
                return
            }

            // Gen-tilkobling under aktivt spil fejlede (pendingURI = nil, !wantsPause).
            // Sangen afspilles stadig i Spotify – intet at gøre.
            status = .disconnected
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            status = .disconnected
            // Gen-tilkobl kun hvis vi har en hensigt (pause skal sendes, eller en
            // sang skal startes) – ellers undgår vi en endeløs reconnect-storm.
            if (wantsPause || pendingURI != nil),
               appRemote.connectionParameters.accessToken != nil {
                appRemote.connect()
            }
        }
    }

    // MARK: SPTAppRemotePlayerStateDelegate

    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if wantsPause {
                if playerState.isPaused {
                    // Pause er bekræftet – stop med at forsøge.
                    wantsPause = false
                    status = .paused
                } else {
                    // Stadig i gang (fx fordi authorizeAndPlayURI genstartede den).
                    // Send pause igen indtil den faktisk standser.
                    appRemote.playerAPI?.pause(nil)
                }
                return
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
