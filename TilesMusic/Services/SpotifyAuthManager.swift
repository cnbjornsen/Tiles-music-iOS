import Foundation
import UIKit

#if canImport(SpotifyiOS)
@preconcurrency import SpotifyiOS
#else
import AuthenticationServices
import CryptoKit
#endif

/// Håndterer Spotify-login og token-management.
///
/// Med Spotify iOS SDK: bruger SPTSessionManager – åbner Spotify-appen direkte.
/// Uden SDK: PKCE-web-flow via ASWebAuthenticationSession som fallback.
@MainActor
final class SpotifyAuthManager: NSObject, ObservableObject {

    static let shared = SpotifyAuthManager()

    @Published private(set) var isLoggedIn = false
    @Published var lastError: String?

    private(set) var accessToken: String?
    private var expiresAt: Date = .distantPast
    private var renewalContinuations: [CheckedContinuation<String, Error>] = []

#if canImport(SpotifyiOS)
    private lazy var sessionManager: SPTSessionManager = {
        let cfg = SPTConfiguration(clientID: SpotifyConfig.clientID,
                                   redirectURL: URL(string: SpotifyConfig.redirectURI)!)
        return SPTSessionManager(configuration: cfg, delegate: self)
    }()
#else
    private var refreshToken: String?
    private var codeVerifier: String?
    private var webAuthSession: ASWebAuthenticationSession?
    private let refreshTokenKey = "spotify.refreshToken"
#endif

    override init() {
        super.init()
        restoreSession()
    }

    // MARK: - Platform-specific public API

#if canImport(SpotifyiOS)

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: "spotify.session"),
              let session = try? NSKeyedUnarchiver.unarchivedObject(ofClass: SPTSession.self, from: data)
        else { return }
        sessionManager.session = session
        if !session.isExpired {
            accessToken = session.accessToken
            expiresAt = session.expirationDate
        }
        isLoggedIn = true
    }

    func login() {
        guard SpotifyConfig.isConfigured else {
            lastError = "Du mangler at indsætte dit Spotify Client ID i SpotifyConfig.swift."
            return
        }
        let scopes: SPTScope = [
            .appRemoteControl, .streaming,
            .playlistReadPrivate, .playlistReadCollaborative,
            .userLibraryRead, .userTopRead,
            .userReadPrivate, .userReadEmail,
        ]
        // Empty OptionSet == rawValue 0 == default (Spotify app if installed, else browser).
        sessionManager.initiateSession(with: scopes, options: [], campaign: nil)
    }

    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        // Only hand auth-code callbacks to SPTSessionManager.
        // App Remote access_token callbacks are handled separately by PlaybackController.
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "code" }) == true else { return false }
        return sessionManager.application(UIApplication.shared, open: url, options: [:])
    }

    func logout() {
        UserDefaults.standard.removeObject(forKey: "spotify.session")
        accessToken = nil
        expiresAt = .distantPast
        isLoggedIn = false
    }

    func validAccessToken() async throws -> String {
        if let token = accessToken, Date() < expiresAt.addingTimeInterval(-30) { return token }
        return try await withCheckedThrowingContinuation { cont in
            renewalContinuations.append(cont)
            sessionManager.renewSession()
        }
    }

#else

    private func restoreSession() {
        if let saved = Keychain.get(refreshTokenKey) {
            refreshToken = saved
            isLoggedIn = true
        }
    }

    func login() {
        guard SpotifyConfig.isConfigured else {
            lastError = "Du mangler at indsætte dit Spotify Client ID i SpotifyConfig.swift."
            return
        }
        let verifier = Self.randomCodeVerifier()
        codeVerifier = verifier
        let challenge = Self.codeChallenge(for: verifier)

        var components = URLComponents(url: SpotifyConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: SpotifyConfig.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: SpotifyConfig.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: SpotifyConfig.scopeString),
        ]

        let session = ASWebAuthenticationSession(
            url: components.url!,
            callbackURLScheme: SpotifyConfig.callbackScheme
        ) { [weak self] callbackURL, error in
            guard let self else { return }
            if let error {
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
                Task { @MainActor in self.lastError = error.localizedDescription }
                return
            }
            guard let callbackURL,
                  let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "code" })?.value else {
                Task { @MainActor in self.lastError = "Manglede autorisationskode fra Spotify." }
                return
            }
            Task { await self.exchangeCode(code) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        webAuthSession = session
        session.start()
    }

    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool { false }

    func logout() {
        Keychain.delete(refreshTokenKey)
        accessToken = nil
        refreshToken = nil
        expiresAt = .distantPast
        isLoggedIn = false
    }

    func validAccessToken() async throws -> String {
        if let token = accessToken, Date() < expiresAt.addingTimeInterval(-30) { return token }
        guard refreshToken != nil else { throw SpotifyError.notAuthenticated }
        return try await withCheckedThrowingContinuation { cont in
            renewalContinuations.append(cont)
            Task { try? await self.refreshAccessToken() }
        }
    }

#endif

    // MARK: - Shared helpers

    fileprivate func resumeRenewals(with token: String) {
        let conts = renewalContinuations; renewalContinuations = []
        conts.forEach { $0.resume(returning: token) }
    }

    fileprivate func failRenewals(with error: Error) {
        let conts = renewalContinuations; renewalContinuations = []
        conts.forEach { $0.resume(throwing: error) }
    }
}

// MARK: - SDK delegate conformance

#if canImport(SpotifyiOS)
extension SpotifyAuthManager: SPTSessionManagerDelegate {

    nonisolated func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            persist(session)
            accessToken = session.accessToken
            expiresAt = session.expirationDate
            isLoggedIn = true
            resumeRenewals(with: session.accessToken)
        }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            lastError = error.localizedDescription
            failRenewals(with: error)
        }
    }

    nonisolated func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            persist(session)
            accessToken = session.accessToken
            expiresAt = session.expirationDate
            resumeRenewals(with: session.accessToken)
        }
    }

    private func persist(_ session: SPTSession) {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: session, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: "spotify.session")
    }
}

// MARK: - No-SDK helpers

#else

extension SpotifyAuthManager: ASWebAuthenticationPresentationContextProviding {

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow ?? ASPresentationAnchor()
    }
}

extension SpotifyAuthManager {

    fileprivate func exchangeCode(_ code: String) async {
        guard let verifier = codeVerifier else { return }
        var request = URLRequest(url: SpotifyConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": SpotifyConfig.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyConfig.redirectURI,
            "code_verifier": verifier,
        ])
        do {
            try await performTokenRequest(request)
            await MainActor.run { self.isLoggedIn = true }
        } catch {
            await MainActor.run { self.lastError = "Login fejlede: \(error.localizedDescription)" }
        }
    }

    fileprivate func refreshAccessToken() async throws {
        guard let rt = refreshToken else { throw SpotifyError.notAuthenticated }
        var request = URLRequest(url: SpotifyConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": SpotifyConfig.clientID,
            "grant_type": "refresh_token",
            "refresh_token": rt,
        ])
        try await performTokenRequest(request)
    }

    private func performTokenRequest(_ request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            await MainActor.run { self.logout() }
            throw SpotifyError.tokenRequestFailed
        }
        let newAccess = json["access_token"] as? String
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let newRefresh = json["refresh_token"] as? String
        await MainActor.run {
            self.accessToken = newAccess
            self.expiresAt = Date().addingTimeInterval(expiresIn)
            if let t = newAccess { self.resumeRenewals(with: t) }
            if let r = newRefresh {
                self.refreshToken = r
                Keychain.set(r, for: self.refreshTokenKey)
            }
        }
    }

    private func formBody(_ params: [String: String]) -> Data {
        params.map { k, v in
            let enc = v.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? v
            return "\(k)=\(enc)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    private static func randomCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()
}

#endif

// MARK: - Shared error type

enum SpotifyError: LocalizedError {
    case notAuthenticated
    case tokenRequestFailed
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Ikke logget ind på Spotify."
        case .tokenRequestFailed: return "Kunne ikke hente token fra Spotify."
        case .requestFailed(let code): return "Spotify-forespørgsel fejlede (HTTP \(code))."
        }
    }
}
