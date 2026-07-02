import CryptoKit
import FamilyDomain
import Foundation

#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

// The OAuth 2.0 authorization-code leg of the Nest SDM integration (P15-C3). Split into PURE builders /
// parsers (unit-tested, no network, no UI) and a thin `ASWebAuthenticationSession` coordinator that the
// live client drives on the main actor. NONE of this is exercised by the mock verification path — it
// runs only after Michael registers a Device Access project and links his Google/Nest account.

/// Errors from the Nest OAuth + SDM calls (P15-C3). The Climate section treats every failure as "hide /
/// show stale" — it never surfaces an error to the user (same degrade-silently contract as Hue/Lutron).
public enum NestError: Error, Equatable, Sendable {
    /// The config is missing a projectId / clientId, so we can't even build the auth URL.
    case notConfigured
    /// The user cancelled the ASWebAuthenticationSession consent screen.
    case userCancelled
    /// The OAuth redirect carried no `code` (denied / malformed).
    case noAuthorizationCode
    /// The token exchange / refresh response was malformed or missing the expected fields.
    case invalidTokenResponse
    /// SDM returned no refresh token on the exchange (usually a missing `access_type=offline` /
    /// `prompt=consent`, or a re-consent that reuses an earlier grant).
    case noRefreshToken
    /// An SDM API call failed after a token refresh + one retry.
    case requestFailed
    /// ASWebAuthenticationSession couldn't present (no window / unsupported).
    case cannotPresent
}

/// The parsed token response from `oauth2.googleapis.com/token` (both the code exchange and the
/// refresh share this shape; a refresh omits `refresh_token`).
public struct NestTokens: Equatable, Sendable {
    public let accessToken: String
    /// Present on the initial code exchange (`access_type=offline`); absent on a plain refresh.
    public let refreshToken: String?
    /// Access-token lifetime in seconds (SDM ≈ 3600).
    public let expiresIn: Int

    public init(accessToken: String, refreshToken: String?, expiresIn: Int) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}

/// Pure OAuth/SDM URL + request builders and response parsers — the testable core of the flow.
public enum NestOAuth {
    /// The SDM OAuth scope. Read + control for thermostats (and, later, other SDM device types).
    public static let scope = "https://www.googleapis.com/auth/sdm.service"

    /// Google's token endpoint (code exchange + refresh).
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// The custom-scheme redirect this app intercepts via `ASWebAuthenticationSession`. Its scheme is
    /// registered in `App/Info.plist` (CFBundleURLTypes), mirroring the firebaseauth entry. Michael
    /// registers this exact URI on the OAuth client (see the runbook).
    public static let redirectScheme = "com.copoche.menere.nest"
    public static let redirectURI = "com.copoche.menere.nest:/oauth2redirect"

    /// The SDM authorization URL. **Correction vs a plain `accounts.google.com` endpoint:** SDM requires
    /// the **Partner Connections Manager (PCM)** URL that embeds the Device Access `projectId` in the
    /// path — it walks the user through picking which Nest devices to share *and* the Google OAuth
    /// consent, then redirects to `redirect_uri?code=…`. We add PKCE (`code_challenge` + `S256`) so a
    /// secret-less public client also works; a Web client additionally sends its secret at token time.
    public static func authorizationURL(config: NestConfig, codeChallenge: String) -> URL? {
        guard config.hasCredentials else { return nil }
        var comps = URLComponents(string: "https://nestservices.google.com/partnerconnections/\(config.projectId)/auth")
        comps?.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "client_id", value: config.oauthClientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return comps?.url
    }

    /// Extract the `code` query param from the OAuth redirect URL (`com.copoche.menere.nest:/…?code=…`).
    public static func authorizationCode(from callbackURL: URL) -> String? {
        URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value
    }

    /// The token-exchange POST (authorization code → tokens). Form-urlencoded; includes PKCE
    /// `code_verifier` and the client secret when the config carries one.
    public static func tokenExchangeRequest(config: NestConfig, code: String, codeVerifier: String) -> URLRequest {
        var params: [String: String] = [
            "client_id": config.oauthClientId,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        if let secret = config.oauthClientSecret, !secret.isEmpty { params["client_secret"] = secret }
        return formPOST(tokenEndpoint, params)
    }

    /// The refresh POST (refresh token → a fresh access token). Includes the client secret when present.
    public static func refreshRequest(config: NestConfig, refreshToken: String) -> URLRequest {
        var params: [String: String] = [
            "client_id": config.oauthClientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]
        if let secret = config.oauthClientSecret, !secret.isEmpty { params["client_secret"] = secret }
        return formPOST(tokenEndpoint, params)
    }

    /// Parse a token response body into `NestTokens` (throws `invalidTokenResponse` on a missing
    /// `access_token`).
    public static func parseTokens(_ data: Data) throws -> NestTokens {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = obj["access_token"] as? String, !accessToken.isEmpty
        else { throw NestError.invalidTokenResponse }
        let refresh = obj["refresh_token"] as? String
        // expires_in may decode as Int or Double depending on the JSON number.
        let expires = (obj["expires_in"] as? Int) ?? (obj["expires_in"] as? Double).map(Int.init) ?? 3600
        return NestTokens(accessToken: accessToken, refreshToken: refresh, expiresIn: expires)
    }

    /// A form-urlencoded POST request.
    static func formPOST(_ url: URL, _ params: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = params
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        return req
    }

    /// x-www-form-urlencoded value escaping.
    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - PKCE

/// A PKCE verifier/challenge pair (RFC 7636, `S256`). The verifier is a high-entropy random string; the
/// challenge is its base64url-encoded SHA-256. Kept a plain value type so the flow can generate one per
/// authorization and hold the verifier for the token exchange.
public struct NestPKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    /// Generate a fresh pair (128-char verifier).
    public init() {
        let verifier = NestPKCE.randomVerifier()
        self.verifier = verifier
        self.challenge = NestPKCE.challenge(for: verifier)
    }

    /// Deterministic init (for tests).
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = NestPKCE.challenge(for: verifier)
    }

    static func randomVerifier(length: Int = 96) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    /// base64url(SHA256(verifier)).
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    /// base64url without padding.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - ASWebAuthenticationSession coordinator

#if canImport(AuthenticationServices) && canImport(UIKit)
import UIKit

/// Drives the consent web flow on the main actor: builds the PCM auth URL, presents
/// `ASWebAuthenticationSession` anchored to the app's key window, and returns the redirect URL. Retained
/// for the session's lifetime (ASWebAuthenticationSession requires a live presentation-context provider).
///
/// **How the presentation anchor is wired through TCA:** the `NestClient.authorize` dependency takes only
/// a `NestConfig` (per the chunk's surface), and the LIVE implementation resolves the anchor here — the
/// app's foreground key window IS the anchor, looked up on the main actor. This keeps the anchor out of
/// reducer state/actions (which stay `Equatable`) while satisfying Apple's API. Tests never reach this
/// class (they inject a `NestClient` whose `authorize` returns a canned token).
@MainActor
final class NestAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// Present consent for `config` and return the OAuth `code` (throws on cancel / denial).
    func authorize(config: NestConfig, pkce: NestPKCE) async throws -> String {
        guard let url = NestOAuth.authorizationURL(config: config, codeChallenge: pkce.challenge) else {
            throw NestError.notConfigured
        }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: NestOAuth.redirectScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: NestError.userCancelled)
                } else {
                    continuation.resume(throwing: NestError.cannotPresent)
                }
            }
            session.presentationContextProvider = self
            // A fresh session each time so a re-consent isn't short-circuited by a stale cookie.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { continuation.resume(throwing: NestError.cannotPresent) }
        }
        guard let code = NestOAuth.authorizationCode(from: callback) else { throw NestError.noAuthorizationCode }
        return code
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        Self.keyWindow() ?? ASPresentationAnchor()
    }

    /// The app's foreground key window (the presentation anchor).
    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first
    }
}
#endif
