import Foundation
import UIKit
import AuthenticationServices
import CryptoKit

/// Håndterer Spotify-login via OAuth 2.0 Authorization Code + PKCE,
/// samt opbevaring og fornyelse af tokens.
@MainActor
final class SpotifyAuthManager: NSObject, ObservableObject {

    /// Delt instans, så auth, API og afspilning bruger samme tokens.
    static let shared = SpotifyAuthManager()

    @Published private(set) var isLoggedIn = false
    @Published var lastError: String?

    private(set) var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date = .distantPast

    private var codeVerifier: String?
    private var webAuthSession: ASWebAuthenticationSession?

    private let tokenKey = "spotify.refreshToken"

    override init() {
        super.init()
        // Genskab session hvis vi har et gemt refresh token.
        if let saved = Keychain.get(tokenKey) {
            self.refreshToken = saved
            self.isLoggedIn = true
        }
    }

    // MARK: - Public

    /// Starter login-flowet i et sikkert web-view.
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
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    return // brugeren lukkede selv – ingen fejl at vise
                }
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
        self.webAuthSession = session
        session.start()
    }

    func logout() {
        Keychain.delete(tokenKey)
        accessToken = nil
        refreshToken = nil
        expiresAt = .distantPast
        isLoggedIn = false
    }

    /// Returnerer et gyldigt access token, fornyer hvis nødvendigt.
    func validAccessToken() async throws -> String {
        if let token = accessToken, Date() < expiresAt.addingTimeInterval(-30) {
            return token
        }
        try await refreshAccessToken()
        guard let token = accessToken else {
            throw SpotifyError.notAuthenticated
        }
        return token
    }

    // MARK: - Token exchange

    private func exchangeCode(_ code: String) async {
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

    private func refreshAccessToken() async throws {
        guard let refreshToken else { throw SpotifyError.notAuthenticated }
        var request = URLRequest(url: SpotifyConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": SpotifyConfig.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        try await performTokenRequest(request)
    }

    private func performTokenRequest(_ request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Refresh token kan være ugyldigt – tving nyt login.
            await MainActor.run { self.logout() }
            throw SpotifyError.tokenRequestFailed
        }

        let newAccess = json["access_token"] as? String
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let newRefresh = json["refresh_token"] as? String

        await MainActor.run {
            self.accessToken = newAccess
            self.expiresAt = Date().addingTimeInterval(expiresIn)
            if let newRefresh {
                self.refreshToken = newRefresh
                Keychain.set(newRefresh, for: self.tokenKey)
            }
        }
    }

    // MARK: - Helpers

    private func formBody(_ params: [String: String]) -> Data {
        params.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
            return "\(key)=\(v)"
        }
        .joined(separator: "&")
        .data(using: .utf8)!
    }

    private static func randomCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

// MARK: - Presentation anchor

extension SpotifyAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}

// MARK: - Fejl

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

// MARK: - Base64 URL-safe

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
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
