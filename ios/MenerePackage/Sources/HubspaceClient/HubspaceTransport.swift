import FamilyDomain
import Foundation

// The live Hubspace transport (P15-C4): Keycloak-authed HTTPS calls to Afero's `api2.afero.net`. This
// is the cloud path Michael's (and Valentina's) phone runs once he's signed into Hubspace; it is NOT
// exercised by the mock-based verification. Access tokens are cached in-memory and refreshed on demand
// from the long-lived refresh token; a 401 forces a single refresh + retry. Device reads are
// single-flighted (the API rate-limits — the House screen polls no faster than ~30s and never overlaps
// a read).

/// A thin injectable HTTP seam so the token-refresh / 401-retry logic is unit-testable without the
/// network. `performNoRedirect` returns the response WITHOUT following redirects (the login step needs
/// the raw 302 `Location`).
struct HubspaceHTTPClient: Sendable {
    var perform: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Perform without following redirects; returns the response (whose `Location` header carries the
    /// auth `code`).
    var performNoRedirect: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let live: HubspaceHTTPClient = {
        let follow = URLSession(configuration: .ephemeral)
        let noFollow = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        return HubspaceHTTPClient(
            perform: { req in
                let (data, resp) = try await follow.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw HubspaceError.requestFailed }
                return (data, http)
            },
            performNoRedirect: { req in
                let (data, resp) = try await noFollow.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw HubspaceError.requestFailed }
                return (data, http)
            }
        )
    }()
}

/// A URLSession delegate that refuses to follow redirects, so the login step can read the 302 `Location`.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // stop; hand the 302 back to the caller
    }
}

/// In-memory access-token cache keyed by refresh token (the credential identity). Access tokens are
/// short-lived; a 401 invalidates + refreshes. Shared across the app so repeated reads (the House
/// screen's ~30s poll) reuse one token.
actor HubspaceTokenCache {
    static let shared = HubspaceTokenCache()

    private var tokens: [String: (token: String, expiry: Date)] = [:]

    func cached(for refreshToken: String, now: Date = Date()) -> String? {
        guard let entry = tokens[refreshToken], entry.expiry > now else { return nil }
        return entry.token
    }

    func store(_ token: String, expiry: Date, for refreshToken: String) {
        tokens[refreshToken] = (token, expiry)
    }

    func invalidate(for refreshToken: String) { tokens[refreshToken] = nil }
}

/// Coalesces concurrent device reads for one account so an overlapping poll + manual refresh hit the
/// rate-limited API only once (single-flight politeness). Callers awaiting during an in-flight read
/// share its result.
actor HubspaceSingleFlight {
    static let shared = HubspaceSingleFlight()

    private var inFlight: [String: Task<[HubspaceSpigot], Error>] = [:]

    func run(key: String, _ operation: @escaping @Sendable () async throws -> [HubspaceSpigot]) async throws -> [HubspaceSpigot] {
        if let existing = inFlight[key] { return try await existing.value }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

/// A Keycloak-authed Afero session for one household config. Owns the access-token lifecycle: hand out a
/// cached token, refresh it from the refresh token when missing/expired, and on a 401 force one refresh
/// + retry exactly once.
struct HubspaceSession: Sendable {
    let config: HubspaceConfig
    var http: HubspaceHTTPClient = .live
    var cache: HubspaceTokenCache = .shared
    var singleFlight: HubspaceSingleFlight = .shared
    var now: @Sendable () -> Date = { Date() }

    /// A valid access token: cached when fresh, otherwise refreshed. `forceRefresh` bypasses the cache.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let refreshToken = config.refreshToken, !refreshToken.isEmpty else {
            throw HubspaceError.notConfigured
        }
        if !forceRefresh, let cached = await cache.cached(for: refreshToken, now: now()) {
            return cached
        }
        let (data, resp) = try await http.perform(HubspaceAuth.refreshRequest(refreshToken: refreshToken))
        guard (200..<300).contains(resp.statusCode) else { throw HubspaceError.invalidTokenResponse }
        let tokens = try HubspaceAuth.parseTokenResponse(data)
        // Keycloak access tokens are short (~5 min for `thd`); cache for 4 min to stay clear of the edge.
        await cache.store(tokens.accessToken, expiry: now().addingTimeInterval(240), for: refreshToken)
        return tokens.accessToken
    }

    /// Perform an authed request; on HTTP 401 refresh once and retry a single time.
    func authed(_ makeRequest: @Sendable (_ token: String) -> URLRequest) async throws -> Data {
        let token = try await accessToken()
        var (data, resp) = try await http.perform(makeRequest(token))
        if resp.statusCode == 401 {
            let fresh = try await accessToken(forceRefresh: true)
            (data, resp) = try await http.perform(makeRequest(fresh))
        }
        guard (200..<300).contains(resp.statusCode) else { throw HubspaceError.requestFailed }
        return data
    }

    // MARK: Afero calls

    /// GET the account's metadevices (expanded with state) → the household's water-timer spigots.
    /// Single-flighted per account.
    func spigots() async throws -> [HubspaceSpigot] {
        guard let accountId = config.accountId, !accountId.isEmpty else { throw HubspaceError.notConfigured }
        return try await singleFlight.run(key: accountId) {
            let data = try await authed { token in
                var comps = URLComponents(string: "https://\(HubspaceAuth.apiHost)/v1/accounts/\(accountId)/metadevices")!
                comps.queryItems = [URLQueryItem(name: "expansions", value: "state,capabilities,semantics")]
                var req = URLRequest(url: comps.url!)
                req.httpMethod = "GET"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return req
            }
            return try HubspaceDevice.parseSpigots(data)
        }
    }

    /// PUT one outlet's state (`toggle` open/close + optional `timer` duration).
    func setSpigot(deviceId: String, instance: String, open: Bool, durationMinutes: Int?) async throws {
        guard let accountId = config.accountId, !accountId.isEmpty else { throw HubspaceError.notConfigured }
        let body = HubspaceWrite.spigotStateBody(
            metadeviceId: deviceId, instance: instance, open: open,
            durationMinutes: durationMinutes, now: now()
        )
        _ = try await authed { token in
            var req = URLRequest(url: URL(string: "https://\(HubspaceAuth.apiHost)/v1/accounts/\(accountId)/metadevices/\(deviceId)/state")!)
            req.httpMethod = "PUT"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            // The write host header points at the DATA host (per aioafero `base.py`).
            req.setValue(HubspaceAuth.dataHost, forHTTPHeaderField: "host")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return req
        }
    }
}

// MARK: - Live login coordinator (3-leg Keycloak flow)

/// Drives the one-time email/password login: authorize → scrape form → post credentials → exchange
/// code → look up the account id. Live-only (mock short-circuits in `HubspaceClient`).
struct HubspaceLogin: Sendable {
    var http: HubspaceHTTPClient = .live

    func login(email: String, password: String) async throws -> HubspaceTokens {
        let pkce = HubspacePKCE()

        // 1. GET the login page. This MUST go through the SAME (no-redirect) session as the credential
        //    POST in step 2: Keycloak sets session cookies here (AUTH_SESSION_ID / KC_AUTH_SESSION_HASH /
        //    KC_RESTART) and REQUIRES them back on the POST. Using two different URLSessions (each with
        //    its own ephemeral cookie jar) drops those cookies → Keycloak answers the POST with HTTP 400
        //    (re-rendering the login page), which surfaces to the user as a bogus "wrong password".
        var authReq = URLRequest(url: HubspaceAuth.authorizeURL(codeChallenge: pkce.challenge))
        authReq.setValue("io.afero.partner.hubspace", forHTTPHeaderField: "x-requested-with")
        let (pageData, pageResp) = try await http.performNoRedirect(authReq)
        guard (200..<400).contains(pageResp.statusCode),
              let html = String(data: pageData, encoding: .utf8),
              let form = HubspaceAuth.extractLoginForm(html: html) else {
            throw HubspaceError.loginFailed
        }

        // 2. POST credentials (no redirect follow, same session as step 1 → cookies replay) → 302
        //    Location carries ?code=…
        let credReq = HubspaceAuth.credentialRequest(form: form, username: email, password: password)
        let (credData, credResp) = try await http.performNoRedirect(credReq)
        guard credResp.statusCode == 302,
              let location = credResp.value(forHTTPHeaderField: "Location"),
              let code = HubspaceAuth.authorizationCode(fromRedirect: location) else {
            // The flow reached the auth server and posted credentials, so a non-302 here is a genuine
            // credential verdict — distinguish it from flow breakage so the UI can say the right thing.
            let body = String(data: credData, encoding: .utf8) ?? ""
            if HubspaceAuth.requiresOTP(html: body) { throw HubspaceError.otpRequired }
            throw HubspaceError.invalidCredentials
        }

        // 3. Exchange the code for tokens.
        let (tokData, tokResp) = try await http.perform(HubspaceAuth.tokenExchangeRequest(code: code, codeVerifier: pkce.verifier))
        guard (200..<300).contains(tokResp.statusCode) else { throw HubspaceError.invalidTokenResponse }
        let tokens = try HubspaceAuth.parseTokenResponse(tokData)
        guard let refresh = tokens.refreshToken, !refresh.isEmpty else { throw HubspaceError.invalidTokenResponse }

        // 4. Look up the account id (Bearer the fresh access token).
        let (meData, meResp) = try await http.perform(HubspaceAuth.accountRequest(accessToken: tokens.accessToken))
        guard (200..<300).contains(meResp.statusCode) else { throw HubspaceError.requestFailed }
        let accountId = try HubspaceAuth.parseAccountId(meData)

        return HubspaceTokens(refreshToken: refresh, accountId: accountId)
    }
}

// MARK: - metadevices JSON → [HubspaceSpigot]

/// Pure parsing of the Afero `metadevices` response into `[HubspaceSpigot]` (unit-tested against a
/// water-timer fixture). Filters to `description.device.deviceClass == "water-timer"`; parses defensively
/// so a non-water-timer device (a Hubspace bulb, plug, etc.) is simply skipped.
public enum HubspaceDevice {
    public static func parseSpigots(_ data: Data) throws -> [HubspaceSpigot] {
        let root = try? JSONSerialization.jsonObject(with: data)
        // The list endpoint returns an array; a single-device /state read returns one object.
        let devices: [[String: Any]]
        if let arr = root as? [[String: Any]] { devices = arr }
        else if let one = root as? [String: Any] { devices = [one] }
        else { throw HubspaceError.requestFailed }
        return devices.compactMap(parseOne)
    }

    static func parseOne(_ dict: [String: Any]) -> HubspaceSpigot? {
        // Only real metadevices, and only water timers.
        if let typeId = dict["typeId"] as? String, typeId != "metadevice.device" { return nil }
        let device = (dict["description"] as? [String: Any])?["device"] as? [String: Any]
        guard (device?["deviceClass"] as? String) == HubspaceFunction.waterTimerDeviceClass else { return nil }

        guard let id = dict["id"] as? String else { return nil }
        let name = dict["friendlyName"] as? String
            ?? (device?["defaultName"] as? String) ?? "Water timer"

        let values = (dict["state"] as? [String: Any])?["values"] as? [[String: Any]] ?? []

        // Group per-instance toggle + timer; capture battery (instance null).
        var togglesByInstance: [String: Bool] = [:]
        var timerByInstance: [String: Int] = [:]
        var battery: Int?
        for v in values {
            let fc = v["functionClass"] as? String
            let instance = v["functionInstance"] as? String
            switch fc {
            case HubspaceFunction.toggle:
                if let inst = instance { togglesByInstance[inst] = (v["value"] as? String) == HubspaceFunction.on }
            case HubspaceFunction.timer:
                if let inst = instance { timerByInstance[inst] = intValue(v["value"]) ?? 0 }
            case HubspaceFunction.batteryLevel:
                battery = intValue(v["value"])
            default:
                break
            }
        }

        // Outlet order: the known spigot-1/spigot-2 first (if present), then any others, stable.
        let discovered = Set(togglesByInstance.keys)
        var ordered = HubspaceFunction.outletInstances.filter { discovered.contains($0) }
        ordered += discovered.subtracting(ordered).sorted()

        let outlets = ordered.map { inst -> SpigotOutlet in
            let open = togglesByInstance[inst] ?? false
            let timer = timerByInstance[inst] ?? 0
            return SpigotOutlet(
                instance: inst,
                name: HubspaceFunction.defaultOutletName(inst),
                isOpen: open,
                remainingMinutes: (open && timer > 0) ? timer : nil
            )
        }
        guard !outlets.isEmpty else { return nil }   // a water timer with no toggles isn't controllable
        return HubspaceSpigot(id: id, name: name, outlets: outlets, batteryPercent: battery)
    }

    /// Coerce a JSON number (Int / Double / numeric String) to Int.
    static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d.rounded()) }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - state PUT payload builder

/// Pure `state` write-body builder (unit-tested for the exact `functionClass` / value strings). The
/// single source of truth the live transport, the mock, and the P14 agent tools share.
public enum HubspaceWrite {
    /// The PUT body to open/close one outlet, optionally for a timed run (minutes). Opening with a
    /// duration writes BOTH the `toggle` (on) and the `timer` value for the instance; closing writes
    /// just `toggle` (off). Matches aioafero's `{ metadeviceId, values: [ … ] }` shape.
    public static func spigotStateBody(metadeviceId: String, instance: String, open: Bool,
                                       durationMinutes: Int?, now: Date = Date()) -> [String: Any] {
        let ms = Int(now.timeIntervalSince1970 * 1000)
        var values: [[String: Any]] = [[
            "functionClass": HubspaceFunction.toggle,
            "functionInstance": instance,
            "value": open ? HubspaceFunction.on : HubspaceFunction.off,
            "lastUpdateTime": ms,
        ]]
        if open, let minutes = durationMinutes, minutes > 0 {
            values.append([
                "functionClass": HubspaceFunction.timer,
                "functionInstance": instance,
                "value": minutes,
                "lastUpdateTime": ms,
            ])
        }
        return ["metadeviceId": metadeviceId, "values": values]
    }
}
