import CryptoKit
import Foundation

// The Keycloak login leg of the Hubspace integration (P15-C4). Split into PURE builders / parsers
// (unit-tested, no network) and a thin live `HubspaceLogin` coordinator that drives the three HTTP
// round-trips. NONE of this is exercised by the mock verification path — it runs only once, when
// Michael enters his Hubspace email + password in Settings.
//
// ## Corrected auth flow (vs a naive password grant)
// Hubspace's Keycloak (`accounts.hubspaceconnect.com`, realm `thd`) does an **authorization_code +
// PKCE** dance with an **HTML login-form scrape** — faithfully ported from `aioafero`:
//   1. GET the OpenID `auth` endpoint (client_id `hubspace_android`, PKCE `S256`, scope
//      "openid offline_access") → an HTML login page. Scrape the `kc-form-login` action URL for its
//      `session_code`, `execution`, `tab_id`.
//   2. POST username+password to `login-actions/authenticate?session_code=…&execution=…&tab_id=…`
//      (form-encoded, header `x-requested-with: io.afero.partner.hubspace`), NOT following redirects →
//      a 302 whose `Location` carries `?code=…`.
//   3. POST that code to the `token` endpoint (grant_type=authorization_code + code_verifier) →
//      `{ access_token, refresh_token, id_token }`.
// Then GET `api2.afero.net/v1/users/me` (Bearer access token) → `accountAccess[0].account.accountId`.

/// Pure Hubspace/Keycloak URL + request builders and response parsers — the testable core of login.
public enum HubspaceAuth {
    // MARK: Constants (verbatim from aioafero `v1_const.py`)

    public static let clientId = "hubspace_android"
    public static let redirectURI = "hubspace-app://loginredirect"
    public static let redirectScheme = "hubspace-app"
    static let openidHost = "accounts.hubspaceconnect.com"
    static let realm = "thd"
    static let apiHost = "api2.afero.net"
    static let dataHost = "semantics2.afero.net"
    /// Sent on every Afero device call (aioafero `get_headers` / `DEFAULT_USERAGENT`). The client-name
    /// slot is filled with our app name; the shape is what Afero's edge expects.
    static let userAgent = "Mozilla/5.0 (Linux; Android 15; Bacan Build/test; wv) AppleWebKit/537.36"

    /// `https://accounts.hubspaceconnect.com/auth/realms/thd/protocol/openid-connect/auth`
    public static let authorizeEndpoint = URL(string: "https://\(openidHost)/auth/realms/\(realm)/protocol/openid-connect/auth")!
    /// `https://accounts.hubspaceconnect.com/auth/realms/thd/login-actions/authenticate`
    public static let loginActionEndpoint = URL(string: "https://\(openidHost)/auth/realms/\(realm)/login-actions/authenticate")!
    /// `https://accounts.hubspaceconnect.com/auth/realms/thd/protocol/openid-connect/token`
    public static let tokenEndpoint = URL(string: "https://\(openidHost)/auth/realms/\(realm)/protocol/openid-connect/token")!
    /// `https://api2.afero.net/v1/users/me`
    public static let accountEndpoint = URL(string: "https://\(apiHost)/v1/users/me")!

    // MARK: Step 1 — authorize URL

    /// The GET authorize URL that returns the Keycloak HTML login page.
    public static func authorizeURL(codeChallenge: String) -> URL {
        var comps = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: "openid offline_access"),
        ]
        return comps.url!
    }

    // MARK: Step 1.5 — scrape the login form

    /// The three hidden values the Keycloak login form carries in its `action` URL.
    public struct LoginForm: Equatable, Sendable {
        public let sessionCode: String
        public let execution: String
        public let tabId: String
        public init(sessionCode: String, execution: String, tabId: String) {
            self.sessionCode = sessionCode
            self.execution = execution
            self.tabId = tabId
        }
    }

    /// Extract `session_code` / `execution` / `tab_id` from the `kc-form-login` action URL in the
    /// Keycloak HTML. Robust to attribute ordering and `&amp;` entity-encoding.
    public static func extractLoginForm(html: String) -> LoginForm? {
        // Find the <form ... id="kc-form-login" ... action="URL"> — action may precede or follow id.
        guard let formRange = rangeOfLoginForm(html) else { return nil }
        let formTag = String(html[formRange])
        guard let action = firstMatch(#"action="([^"]+)""#, in: formTag) else { return nil }
        let decoded = action.replacingOccurrences(of: "&amp;", with: "&")
        guard let comps = URLComponents(string: decoded) else { return nil }
        func q(_ n: String) -> String? { comps.queryItems?.first { $0.name == n }?.value }
        guard let session = q("session_code"), let exec = q("execution"), let tab = q("tab_id") else {
            return nil
        }
        return LoginForm(sessionCode: session, execution: exec, tabId: tab)
    }

    /// Range of the opening `<form …>` tag that carries `id="kc-form-login"`.
    private static func rangeOfLoginForm(_ html: String) -> Range<String.Index>? {
        var searchStart = html.startIndex
        while let open = html.range(of: "<form", range: searchStart..<html.endIndex) {
            guard let close = html.range(of: ">", range: open.upperBound..<html.endIndex) else { return nil }
            let tag = html[open.lowerBound..<close.upperBound]
            if tag.contains("kc-form-login") { return open.lowerBound..<close.upperBound }
            searchStart = close.upperBound
        }
        return nil
    }

    // MARK: Step 2 — credential POST

    /// The POST to `login-actions/authenticate` carrying username + password. The Keycloak session
    /// values ride as query params; the credentials are the form body.
    public static func credentialRequest(form: LoginForm, username: String, password: String) -> URLRequest {
        var comps = URLComponents(url: loginActionEndpoint, resolvingAgainstBaseURL: false)!
        // `client_id` is REQUIRED here — aioafero's `extract_login_codes` puts it in the query params.
        // Without it Keycloak can't resolve the client and rejects the POST with HTTP 400 (re-rendering
        // the login page), which reads to the user as "wrong password" even when the password is right.
        comps.queryItems = [
            URLQueryItem(name: "session_code", value: form.sessionCode),
            URLQueryItem(name: "execution", value: form.execution),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "tab_id", value: form.tabId),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("io.afero.partner.hubspace", forHTTPHeaderField: "x-requested-with")
        req.httpBody = formBody([
            "username": username,
            "password": password,
            "credentialId": "",
        ])
        return req
    }

    /// True when the credential-POST response is Keycloak's OTP (second-factor) form rather than a
    /// redirect — mirrors aioafero's `requires_otp` (`"kc-otp-login-form" in content`).
    public static func requiresOTP(html: String) -> Bool {
        html.contains("kc-otp-login-form")
    }

    /// Extract the `code` from the post-login redirect (`hubspace-app://loginredirect?code=…`).
    public static func authorizationCode(fromRedirect location: String) -> String? {
        guard let comps = URLComponents(string: location) else { return nil }
        return comps.queryItems?.first { $0.name == "code" }?.value
    }

    // MARK: Step 3 — token exchange + refresh

    /// The token-exchange POST (authorization code → tokens), form-urlencoded with PKCE `code_verifier`.
    public static func tokenExchangeRequest(code: String, codeVerifier: String) -> URLRequest {
        tokenPOST([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
            "client_id": clientId,
        ])
    }

    /// The refresh POST (refresh token → a fresh access token).
    public static func refreshRequest(refreshToken: String) -> URLRequest {
        tokenPOST([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid email offline_access profile",
            "client_id": clientId,
        ])
    }

    /// A parsed token response. A refresh may re-issue the refresh token (Keycloak does); both grants
    /// share this shape.
    public struct TokenResponse: Equatable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public init(accessToken: String, refreshToken: String?) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }
    }

    /// Parse a Keycloak token response (throws `invalidTokenResponse` on a missing `access_token`).
    public static func parseTokenResponse(_ data: Data) throws -> TokenResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, !access.isEmpty
        else { throw HubspaceError.invalidTokenResponse }
        return TokenResponse(accessToken: access, refreshToken: obj["refresh_token"] as? String)
    }

    // MARK: users/me → accountId

    /// Extract `accountAccess[0].account.accountId` from a `users/me` response.
    public static func parseAccountId(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["accountAccess"] as? [[String: Any]],
              let account = access.first?["account"] as? [String: Any],
              let id = account["accountId"] as? String, !id.isEmpty
        else { throw HubspaceError.noAccountId }
        return id
    }

    /// The GET `users/me` request (Bearer access token).
    public static func accountRequest(accessToken: String) -> URLRequest {
        var req = URLRequest(url: accountEndpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: helpers

    private static func tokenPOST(_ params: [String: String]) -> URLRequest {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(openidHost, forHTTPHeaderField: "host")
        req.httpBody = formBody(params)
        return req
    }

    static func formBody(_ params: [String: String]) -> Data {
        params.map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

// MARK: - PKCE

/// A PKCE verifier/challenge pair for the Hubspace login. Mirrors `aioafero`: the verifier is
/// base64url(random(40)) with non-alphanumerics stripped; the challenge is base64url(SHA256(verifier))
/// without padding.
public struct HubspacePKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    public init() {
        self.verifier = HubspacePKCE.randomVerifier()
        self.challenge = HubspacePKCE.challenge(for: verifier)
    }

    /// Deterministic init (for tests).
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = HubspacePKCE.challenge(for: verifier)
    }

    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 40)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let raw = base64URL(Data(bytes))
        // aioafero strips everything but [a-zA-Z0-9] from the verifier.
        return raw.filter { $0.isLetter || $0.isNumber }
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
