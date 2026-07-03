import FamilyDomain
import Foundation
import Testing

@testable import HubspaceClient

/// Locks the pure Hubspace wire layer (P15-C4): the Keycloak login builders/parsers, the metadevices
/// water-timer parsing (against a faithfully-shaped fixture), the state-write payload, the token
/// refresh / 401-retry, the single-flight guard, and the stateful mock. NONE of this touches the
/// network — Michael's first live sign-in is the live test.
struct HubspaceClientTests {

    // MARK: PKCE + authorize URL

    @Test func pkceChallengeIsBase64URLSHA256NoPadding() {
        // Known RFC 7636 vector for base64url(SHA256(verifier)).
        let pkce = HubspacePKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(!pkce.challenge.contains("="))
        #expect(!pkce.challenge.contains("+"))
        #expect(!pkce.challenge.contains("/"))
    }

    @Test func randomVerifierIsAlphanumericOnly() {
        // aioafero strips non-alphanumerics from the verifier.
        let v = HubspacePKCE().verifier
        #expect(!v.isEmpty)
        #expect(v.allSatisfy { $0.isLetter || $0.isNumber })
    }

    @Test func authorizeURLCarriesClientAndPKCE() throws {
        let url = HubspaceAuth.authorizeURL(codeChallenge: "CHAL")
        #expect(url.host == "accounts.hubspaceconnect.com")
        #expect(url.path == "/auth/realms/thd/protocol/openid-connect/auth")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func val(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(val("response_type") == "code")
        #expect(val("client_id") == "hubspace_android")
        #expect(val("redirect_uri") == "hubspace-app://loginredirect")
        #expect(val("code_challenge") == "CHAL")
        #expect(val("code_challenge_method") == "S256")
        #expect(val("scope") == "openid offline_access")
    }

    // MARK: login-form scrape

    @Test func extractsSessionCodeExecutionTabIdFromForm() throws {
        // A Keycloak login page: the form action carries the three values, &amp;-encoded.
        let html = """
        <html><body>
        <form id="kc-form-login" onsubmit="login.disabled = true; return true;"
              action="https://accounts.hubspaceconnect.com/auth/realms/thd/login-actions/authenticate?session_code=SC123&amp;execution=EX456&amp;tab_id=TAB789"
              method="post">
          <input name="username"/><input name="password"/>
        </form>
        </body></html>
        """
        let form = try #require(HubspaceAuth.extractLoginForm(html: html))
        #expect(form.sessionCode == "SC123")
        #expect(form.execution == "EX456")
        #expect(form.tabId == "TAB789")
    }

    @Test func extractLoginFormReturnsNilWithoutForm() {
        #expect(HubspaceAuth.extractLoginForm(html: "<html><body>no form here</body></html>") == nil)
    }

    @Test func credentialRequestCarriesSessionParamsAndBody() throws {
        let form = HubspaceAuth.LoginForm(sessionCode: "SC", execution: "EX", tabId: "TAB")
        let req = HubspaceAuth.credentialRequest(form: form, username: "me@example.com", password: "pw&secret")
        #expect(req.httpMethod == "POST")
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        func q(_ n: String) -> String? { comps.queryItems?.first { $0.name == n }?.value }
        #expect(comps.path == "/auth/realms/thd/login-actions/authenticate")
        #expect(q("session_code") == "SC")
        #expect(q("execution") == "EX")
        #expect(q("tab_id") == "TAB")
        // client_id is REQUIRED on this POST (aioafero `extract_login_codes`); its absence makes
        // Keycloak reject every login with HTTP 400 — the bug this pins against regressing.
        #expect(q("client_id") == "hubspace_android")
        #expect(req.value(forHTTPHeaderField: "x-requested-with") == "io.afero.partner.hubspace")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("username=me%40example.com"))
        #expect(body.contains("password=pw%26secret"))   // & escaped, not a separator
        #expect(body.contains("credentialId="))
    }

    // MARK: reference-conformance pins (aioafero v1_const.py)

    @Test func authConstantsMatchReference() {
        // Pinned verbatim to aioafero `AFERO_CLIENTS["hubspace"]` + `AFERO_GENERICS`. A drift in the
        // upstream reference must break this test, not Michael's sign-in.
        #expect(HubspaceAuth.clientId == "hubspace_android")
        #expect(HubspaceAuth.redirectURI == "hubspace-app://loginredirect")
        #expect(HubspaceAuth.openidHost == "accounts.hubspaceconnect.com")
        #expect(HubspaceAuth.realm == "thd")
        #expect(HubspaceAuth.apiHost == "api2.afero.net")
        #expect(HubspaceAuth.dataHost == "semantics2.afero.net")
        #expect(HubspaceAuth.authorizeEndpoint.absoluteString
            == "https://accounts.hubspaceconnect.com/auth/realms/thd/protocol/openid-connect/auth")
        #expect(HubspaceAuth.loginActionEndpoint.absoluteString
            == "https://accounts.hubspaceconnect.com/auth/realms/thd/login-actions/authenticate")
        #expect(HubspaceAuth.tokenEndpoint.absoluteString
            == "https://accounts.hubspaceconnect.com/auth/realms/thd/protocol/openid-connect/token")
        #expect(HubspaceAuth.accountEndpoint.absoluteString == "https://api2.afero.net/v1/users/me")
    }

    @Test func requiresOTPDetectsSecondFactorForm() {
        #expect(HubspaceAuth.requiresOTP(html: #"<form id="kc-otp-login-form" action="…">"#))
        #expect(!HubspaceAuth.requiresOTP(html: #"<form id="kc-form-login" action="…">"#))
    }

    @Test func extractsAuthorizationCodeFromRedirect() {
        #expect(HubspaceAuth.authorizationCode(fromRedirect: "hubspace-app://loginredirect?code=ABC123&session_state=x") == "ABC123")
        #expect(HubspaceAuth.authorizationCode(fromRedirect: "hubspace-app://loginredirect?error=access_denied") == nil)
    }

    // MARK: token exchange / refresh / parse

    @Test func tokenExchangeRequestBody() {
        let req = HubspaceAuth.tokenExchangeRequest(code: "CODE", codeVerifier: "VER")
        #expect(req.url == HubspaceAuth.tokenEndpoint)
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=CODE"))
        #expect(body.contains("code_verifier=VER"))
        #expect(body.contains("client_id=hubspace_android"))
        #expect(body.contains("redirect_uri=hubspace-app"))
    }

    @Test func refreshRequestBody() {
        let req = HubspaceAuth.refreshRequest(refreshToken: "RT")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=RT"))
        #expect(body.contains("client_id=hubspace_android"))
        #expect(body.contains("scope=openid"))
    }

    @Test func parsesTokenResponse() throws {
        let json = #"{"access_token":"AT","refresh_token":"RT","id_token":"ID","expires_in":300}"#
        let t = try HubspaceAuth.parseTokenResponse(Data(json.utf8))
        #expect(t.accessToken == "AT")
        #expect(t.refreshToken == "RT")
        // Refresh grants may omit refresh_token.
        let refreshOnly = try HubspaceAuth.parseTokenResponse(Data(#"{"access_token":"AT2"}"#.utf8))
        #expect(refreshOnly.refreshToken == nil)
    }

    @Test func parseTokenResponseThrowsOnMissingAccessToken() {
        #expect(throws: HubspaceError.self) { try HubspaceAuth.parseTokenResponse(Data(#"{"error":"invalid_grant"}"#.utf8)) }
    }

    @Test func parseAccountIdReadsFirstAccountAccess() throws {
        let json = """
        { "accountAccess": [ { "account": { "accountId": "acct-42" } } ] }
        """
        #expect(try HubspaceAuth.parseAccountId(Data(json.utf8)) == "acct-42")
        #expect(throws: HubspaceError.self) { try HubspaceAuth.parseAccountId(Data("{}".utf8)) }
    }

    // MARK: metadevices water-timer parse

    /// A faithfully-shaped metadevices response: one Husky water timer (two spigots) plus a non-water
    /// device (a Hubspace bulb) that must be filtered out.
    private let metadevicesJSON = """
    [
      {
        "typeId": "metadevice.device",
        "id": "wt-001",
        "deviceId": "dev-001",
        "friendlyName": "Front yard spigot",
        "description": {
          "device": {
            "defaultName": "Watering Timer",
            "deviceClass": "water-timer",
            "manufacturerName": "Husky",
            "model": "Watering Timer",
            "type": "device"
          }
        },
        "state": {
          "metadeviceId": "wt-001",
          "values": [
            { "functionClass": "toggle", "functionInstance": "spigot-1", "lastUpdateTime": 0, "value": "off" },
            { "functionClass": "toggle", "functionInstance": "spigot-2", "lastUpdateTime": 0, "value": "on" },
            { "functionClass": "timer", "functionInstance": "spigot-1", "lastUpdateTime": 0, "value": 0 },
            { "functionClass": "timer", "functionInstance": "spigot-2", "lastUpdateTime": 0, "value": 12 },
            { "functionClass": "max-on-time", "functionInstance": "spigot-1", "lastUpdateTime": 0, "value": 15 },
            { "functionClass": "battery-level", "functionInstance": null, "lastUpdateTime": 0, "value": 87 },
            { "functionClass": "available", "functionInstance": null, "lastUpdateTime": 0, "value": true }
          ]
        }
      },
      {
        "typeId": "metadevice.device",
        "id": "bulb-9",
        "friendlyName": "Porch light",
        "description": { "device": { "deviceClass": "light", "manufacturerName": "Hubspace" } },
        "state": { "values": [ { "functionClass": "power", "functionInstance": null, "value": "on" } ] }
      }
    ]
    """

    @Test func parsesOnlyWaterTimerWithTwoOutlets() throws {
        let spigots = try HubspaceDevice.parseSpigots(Data(metadevicesJSON.utf8))
        #expect(spigots.count == 1)   // bulb filtered out
        let s = try #require(spigots.first)
        #expect(s.id == "wt-001")
        #expect(s.name == "Front yard spigot")
        #expect(s.batteryPercent == 87)
        #expect(s.outlets.count == 2)
        // spigot-1 closed, no remaining.
        let one = try #require(s.outlets.first { $0.instance == "spigot-1" })
        #expect(one.isOpen == false)
        #expect(one.remainingMinutes == nil)
        #expect(one.statusLine == "Closed")
        // spigot-2 open with 12 min left.
        let two = try #require(s.outlets.first { $0.instance == "spigot-2" })
        #expect(two.isOpen == true)
        #expect(two.remainingMinutes == 12)
        #expect(two.statusLine == "Open · 12 min left")
        // Order: spigot-1 then spigot-2.
        #expect(s.outlets.map(\.instance) == ["spigot-1", "spigot-2"])
    }

    @Test func parsesSingleDeviceStateObject() throws {
        // The per-device /state read returns a single object, not an array.
        let single = """
        { "typeId": "metadevice.device", "id": "wt-001", "friendlyName": "Spigot",
          "description": { "device": { "deviceClass": "water-timer" } },
          "state": { "values": [ { "functionClass": "toggle", "functionInstance": "spigot-1", "value": "on" } ] } }
        """
        let spigots = try HubspaceDevice.parseSpigots(Data(single.utf8))
        #expect(spigots.count == 1)
        #expect(spigots.first?.outlets.first?.isOpen == true)
    }

    // MARK: state-write payload

    @Test func openWithDurationWritesToggleAndTimer() throws {
        let body = HubspaceWrite.spigotStateBody(metadeviceId: "wt-001", instance: "spigot-1", open: true, durationMinutes: 10, now: Date(timeIntervalSince1970: 100))
        #expect(body["metadeviceId"] as? String == "wt-001")
        let values = try #require(body["values"] as? [[String: Any]])
        #expect(values.count == 2)   // toggle + timer
        let toggle = try #require(values.first { ($0["functionClass"] as? String) == "toggle" })
        #expect(toggle["functionInstance"] as? String == "spigot-1")
        #expect(toggle["value"] as? String == "on")
        let timer = try #require(values.first { ($0["functionClass"] as? String) == "timer" })
        #expect(timer["value"] as? Int == 10)
        // Serializes to valid JSON (what the transport PUTs).
        #expect(throws: Never.self) { try JSONSerialization.data(withJSONObject: body) }
    }

    @Test func openUntilOffWritesOnlyToggle() throws {
        let body = HubspaceWrite.spigotStateBody(metadeviceId: "wt-001", instance: "spigot-2", open: true, durationMinutes: nil)
        let values = try #require(body["values"] as? [[String: Any]])
        #expect(values.count == 1)
        #expect(values.first?["value"] as? String == "on")
    }

    @Test func closeWritesToggleOffNoTimer() throws {
        let body = HubspaceWrite.spigotStateBody(metadeviceId: "wt-001", instance: "spigot-1", open: false, durationMinutes: 30)
        let values = try #require(body["values"] as? [[String: Any]])
        #expect(values.count == 1)   // duration ignored when closing
        #expect(values.first?["value"] as? String == "off")
    }

    // MARK: token refresh / 401 retry

    private actor CallLog {
        private(set) var urls: [String] = []
        private(set) var auths: [String?] = []
        private(set) var hosts: [String?] = []
        private(set) var userAgents: [String?] = []
        func record(_ req: URLRequest) {
            urls.append(req.url?.absoluteString ?? "")
            auths.append(req.value(forHTTPHeaderField: "Authorization"))
            hosts.append(req.value(forHTTPHeaderField: "host"))
            userAgents.append(req.value(forHTTPHeaderField: "user-agent"))
        }
        var count: Int { urls.count }
        var refreshCount: Int { urls.filter { $0.contains("openid-connect/token") }.count }
    }

    private func ok(_ url: URL, _ json: String) -> (Data, HTTPURLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private let config = HubspaceConfig(refreshToken: "R", accountId: "acct-1", email: "me@x.com")

    @Test func unauthorizedTriggersSingleRefreshAndRetry() async throws {
        let log = CallLog()
        let cache = HubspaceTokenCache()
        await cache.store("STALE", expiry: Date().addingTimeInterval(3600), for: "R")

        let http = HubspaceHTTPClient(
            perform: { req in
                await log.record(req)
                let url = req.url!
                if url.absoluteString.contains("openid-connect/token") {
                    return self.ok(url, #"{"access_token":"FRESH"}"#)
                }
                if req.value(forHTTPHeaderField: "Authorization") == "Bearer STALE" {
                    return (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
                }
                return self.ok(url, self.metadevicesJSON)
            },
            performNoRedirect: { _ in (Data(), HTTPURLResponse()) }
        )
        let session = HubspaceSession(config: config, http: http, cache: cache, singleFlight: HubspaceSingleFlight())
        let spigots = try await session.spigots()

        #expect(spigots.count == 1)
        #expect(await log.count == 3)          // metadevices(401) → refresh → metadevices(200)
        #expect(await log.refreshCount == 1)
        #expect(await log.auths == ["Bearer STALE", nil, "Bearer FRESH"])
    }

    /// The metadevices READ must carry `host: semantics2.afero.net` (the DATA host) — NOT the api2 URL
    /// host. Afero answers the correct path with HTTP 404 `not_found` when this header is missing (the
    /// live second bug, distinct from auth). This pins it against regressing. Also asserts the
    /// user-agent is present.
    @Test func metadevicesReadCarriesDataHostHeader() async throws {
        let log = CallLog()
        let cache = HubspaceTokenCache()
        await cache.store("GOOD", expiry: Date().addingTimeInterval(3600), for: "R")
        let http = HubspaceHTTPClient(
            perform: { req in await log.record(req); return self.ok(req.url!, self.metadevicesJSON) },
            performNoRedirect: { _ in (Data(), HTTPURLResponse()) }
        )
        let session = HubspaceSession(config: config, http: http, cache: cache, singleFlight: HubspaceSingleFlight())
        _ = try await session.spigots()
        // Request went to api2.afero.net (the URL host) …
        #expect(await log.urls.first?.contains("api2.afero.net/v1/accounts/") == true)
        // … but the host header overrides to the DATA host so the read isn't 404'd.
        #expect(await log.hosts.first == "semantics2.afero.net")
        let ua = await log.userAgents.first ?? nil
        #expect(ua?.isEmpty == false)
    }

    @Test func cachedTokenIsReusedWithoutRefresh() async throws {
        let log = CallLog()
        let cache = HubspaceTokenCache()
        await cache.store("GOOD", expiry: Date().addingTimeInterval(3600), for: "R")
        let http = HubspaceHTTPClient(
            perform: { req in await log.record(req); return self.ok(req.url!, self.metadevicesJSON) },
            performNoRedirect: { _ in (Data(), HTTPURLResponse()) }
        )
        let session = HubspaceSession(config: config, http: http, cache: cache, singleFlight: HubspaceSingleFlight())
        _ = try await session.spigots()
        #expect(await log.count == 1)
        #expect(await log.refreshCount == 0)
    }

    // MARK: single-flight

    @Test func concurrentReadsCoalesceIntoOneFetch() async throws {
        let counter = FetchCounter()
        let flight = HubspaceSingleFlight()   // fresh actor so the test is isolated
        let key = "sf-concurrent-key"
        // Two concurrent same-key runs share one underlying fetch (the second's op never runs).
        // Both ops return the same result so the assertion doesn't depend on which call wins the race
        // to become the single-flight leader; the point is that only ONE op body executes.
        async let x = flight.run(key: key) {
            await counter.bump()
            try? await Task.sleep(for: .milliseconds(50))
            return [HubspaceFixtures.frontYard]
        }
        async let y = flight.run(key: key) {
            await counter.bump()
            try? await Task.sleep(for: .milliseconds(50))
            return [HubspaceFixtures.frontYard]
        }
        let rx = try await x
        let ry = try await y
        #expect(rx.count == 1)
        #expect(ry.count == 1)   // coalesced → shared the leader's result
        #expect(await counter.value == 1)   // exactly one underlying fetch ran
    }

    private actor FetchCounter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    // MARK: 3-leg login flow (cookie-session + client_id + error typing)

    private static let loginPageHTML = """
    <html><body>
    <form id="kc-form-login"
          action="https://accounts.hubspaceconnect.com/auth/realms/thd/login-actions/authenticate?session_code=SC&amp;execution=EX&amp;tab_id=TAB"
          method="post"><input name="username"/><input name="password"/></form>
    </body></html>
    """

    /// Records which HTTP seam each request used, so we can prove leg 1 (GET auth) shares the
    /// no-redirect session with leg 2 (the credential POST) — the cookie-jar fix.
    private actor SeamLog {
        private(set) var noRedirectPaths: [String] = []
        private(set) var performPaths: [String] = []
        func noRedirect(_ p: String) { noRedirectPaths.append(p) }
        func perform(_ p: String) { performPaths.append(p) }
    }

    private func html200(_ url: URL) -> (Data, HTTPURLResponse) {
        (Data(Self.loginPageHTML.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    /// Happy path: authorize (no-redirect) → credentials (no-redirect, 302+code) → token → users/me.
    @Test func loginFlowSharesSessionSendsClientIdAndReturnsTokens() async throws {
        let log = SeamLog()
        let http = HubspaceHTTPClient(
            perform: { req in
                await log.perform(req.url!.path)
                let url = req.url!
                if url.path.contains("openid-connect/token") {
                    return self.ok(url, #"{"access_token":"AT","refresh_token":"RT","id_token":"ID"}"#)
                }
                return self.ok(url, #"{"accountAccess":[{"account":{"accountId":"acct-42"}}]}"#)
            },
            performNoRedirect: { req in
                await log.noRedirect(req.url!.path)
                let url = req.url!
                if url.path.contains("login-actions/authenticate") {
                    // Assert the credential POST carries client_id (the bug fix).
                    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    #expect(items.first { $0.name == "client_id" }?.value == "hubspace_android")
                    let resp = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                        headerFields: ["Location": "hubspace-app://loginredirect?code=THE_CODE"])!
                    return (Data(), resp)
                }
                return self.html200(url)   // the authorize GET → login page
            }
        )
        let tokens = try await HubspaceLogin(http: http).login(email: "me@x.com", password: "pw")
        #expect(tokens.refreshToken == "RT")
        #expect(tokens.accountId == "acct-42")
        // Leg 1 (authorize) AND leg 2 (credentials) both went through the no-redirect session, so the
        // Keycloak session cookies set on leg 1 are replayed on leg 2.
        #expect(await log.noRedirectPaths == [
            "/auth/realms/thd/protocol/openid-connect/auth",
            "/auth/realms/thd/login-actions/authenticate",
        ])
    }

    /// A non-302, non-OTP credential response is a rejected password → `.invalidCredentials`
    /// (distinct from a flow break), so the UI can say "wrong password" only when it really is.
    @Test func loginRejectedPasswordThrowsInvalidCredentials() async throws {
        let http = HubspaceHTTPClient(
            perform: { req in self.ok(req.url!, "{}") },
            performNoRedirect: { req in
                let url = req.url!
                if url.path.contains("login-actions/authenticate") {
                    // 400 re-rendering the login page (Keycloak's bad-password signature).
                    return (Data("<html>login</html>".utf8),
                            HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!)
                }
                return self.html200(url)
            }
        )
        await #expect(throws: HubspaceError.invalidCredentials) {
            try await HubspaceLogin(http: http).login(email: "me@x.com", password: "bad")
        }
    }

    /// An OTP form back from the credential POST → `.otpRequired`, never a bad-password message.
    @Test func loginOTPFormThrowsOtpRequired() async throws {
        let http = HubspaceHTTPClient(
            perform: { req in self.ok(req.url!, "{}") },
            performNoRedirect: { req in
                let url = req.url!
                if url.path.contains("login-actions/authenticate") {
                    return (Data(#"<form id="kc-otp-login-form"></form>"#.utf8),
                            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                return self.html200(url)
            }
        )
        await #expect(throws: HubspaceError.otpRequired) {
            try await HubspaceLogin(http: http).login(email: "me@x.com", password: "pw")
        }
    }

    // MARK: stateful mock

    @Test func mockStorePersistsSpigotWrites() async {
        let store = HubspaceMockStore()
        await store.reset()

        var spigots = await store.spigots()
        let s = spigots.first!
        #expect(s.name == "Front yard spigot")
        #expect(s.batteryPercent == 87)
        #expect(s.outlets.first { $0.instance == "spigot-1" }?.isOpen == false)   // Garden beds closed
        #expect(s.outlets.first { $0.instance == "spigot-2" }?.isOpen == true)    // Drip line open
        #expect(s.outlets.first { $0.instance == "spigot-2" }?.remainingMinutes == 12)

        // Open spigot-1 for 15 min — persists.
        await store.setSpigot(deviceId: HubspaceFixtures.frontYardId, instance: "spigot-1", open: true, durationMinutes: 15)
        spigots = await store.spigots()
        let one = spigots.first!.outlets.first { $0.instance == "spigot-1" }!
        #expect(one.isOpen == true)
        #expect(one.remainingMinutes == 15)

        // Close spigot-2 — clears its remaining.
        await store.setSpigot(deviceId: HubspaceFixtures.frontYardId, instance: "spigot-2", open: false, durationMinutes: nil)
        spigots = await store.spigots()
        let two = spigots.first!.outlets.first { $0.instance == "spigot-2" }!
        #expect(two.isOpen == false)
        #expect(two.remainingMinutes == nil)
    }
}
