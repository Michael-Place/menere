import FamilyDomain
import Foundation

// The live SDM transport (P15-C3): OAuth-authed HTTPS calls to Google's Smart Device Management API.
// This is the cloud path Michael's (and Valentina's) phone runs once his Google/Nest account is linked;
// it is NOT exercised by the mock-based verification. Access tokens are cached in-memory and refreshed
// on demand from the long-lived refresh token; a 401 forces a single refresh + retry.

/// A thin injectable HTTP seam so the token-refresh / 401-retry logic is unit-testable without the
/// network. Live value is `URLSession.shared`.
struct NestHTTPClient: Sendable {
    var perform: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let live = NestHTTPClient { req in
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw NestError.requestFailed }
        return (data, http)
    }
}

/// In-memory access-token cache keyed by refresh token (the credential identity). Access tokens live ~1h;
/// we store them with a small safety margin and refresh past it. Shared across the app so repeated reads
/// (Today card + House screen) reuse one token; a 401 invalidates + refreshes.
actor NestTokenCache {
    static let shared = NestTokenCache()

    private var tokens: [String: (token: String, expiry: Date)] = [:]

    /// A still-valid cached token for this refresh token, or nil.
    func cached(for refreshToken: String, now: Date = Date()) -> String? {
        guard let entry = tokens[refreshToken], entry.expiry > now else { return nil }
        return entry.token
    }

    func store(_ token: String, expiry: Date, for refreshToken: String) {
        tokens[refreshToken] = (token, expiry)
    }

    func invalidate(for refreshToken: String) {
        tokens[refreshToken] = nil
    }
}

/// An OAuth-authed SDM session for one household config. Owns the access-token lifecycle: hand out a
/// cached token, refresh it from the refresh token when missing/expired, and — crucially — on a 401
/// force one refresh and retry the request exactly once.
struct NestSession: Sendable {
    let config: NestConfig
    var http: NestHTTPClient = .live
    var cache: NestTokenCache = .shared
    /// Injected clock for token-expiry math (defaults to wall time; overridable in tests).
    var now: @Sendable () -> Date = { Date() }

    /// A valid access token: cached when fresh, otherwise refreshed from the refresh token. `forceRefresh`
    /// bypasses the cache (used after a 401).
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let refreshToken = config.refreshToken, !refreshToken.isEmpty else {
            throw NestError.notConfigured
        }
        if !forceRefresh, let cached = await cache.cached(for: refreshToken, now: now()) {
            return cached
        }
        let (data, resp) = try await http.perform(NestOAuth.refreshRequest(config: config, refreshToken: refreshToken))
        guard (200..<300).contains(resp.statusCode) else { throw NestError.invalidTokenResponse }
        let tokens = try NestOAuth.parseTokens(data)
        // Expire 60s early so an in-flight request never races the boundary.
        let expiry = now().addingTimeInterval(TimeInterval(max(tokens.expiresIn - 60, 30)))
        await cache.store(tokens.accessToken, expiry: expiry, for: refreshToken)
        return tokens.accessToken
    }

    /// Perform an authed request built from the current access token. On HTTP 401, refresh once and
    /// retry a single time; any non-2xx (after the retry) throws `requestFailed`.
    func authed(_ makeRequest: @Sendable (_ token: String) -> URLRequest) async throws -> Data {
        let token = try await accessToken()
        var (data, resp) = try await http.perform(makeRequest(token))
        if resp.statusCode == 401 {
            let fresh = try await accessToken(forceRefresh: true)
            (data, resp) = try await http.perform(makeRequest(fresh))
        }
        guard (200..<300).contains(resp.statusCode) else { throw NestError.requestFailed }
        return data
    }

    // MARK: SDM calls

    private static let apiBase = "https://smartdevicemanagement.googleapis.com/v1"

    /// GET `enterprises/{projectId}/devices` → the household's thermostats.
    func thermostats() async throws -> [NestThermostat] {
        let projectId = config.projectId
        let data = try await authed { token in
            var req = URLRequest(url: URL(string: "\(Self.apiBase)/enterprises/\(projectId)/devices")!)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return req
        }
        return try NestDevice.parseThermostats(data)
    }

    /// POST `{name}:executeCommand` with a command + params body.
    func executeCommand(deviceName: String, body: [String: Any]) async throws {
        _ = try await authed { token in
            var req = URLRequest(url: URL(string: "\(Self.apiBase)/\(deviceName):executeCommand")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return req
        }
    }
}

// MARK: - SDM device JSON → NestThermostat

/// Pure parsing of the SDM `devices.list` response into `[NestThermostat]` (unit-tested against a real
/// response fixture). Only thermostats — a device is treated as one iff it carries a `ThermostatMode`
/// trait, so we're robust to `type` string drift.
public enum NestDevice {
    static let modeKey = "sdm.devices.traits.ThermostatMode"
    static let tempKey = "sdm.devices.traits.Temperature"
    static let humidityKey = "sdm.devices.traits.Humidity"
    static let setpointKey = "sdm.devices.traits.ThermostatTemperatureSetpoint"
    static let infoKey = "sdm.devices.traits.Info"
    static let hvacKey = "sdm.devices.traits.ThermostatHvac"

    public static func parseThermostats(_ data: Data) throws -> [NestThermostat] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NestError.requestFailed
        }
        let devices = obj["devices"] as? [[String: Any]] ?? []
        return devices.compactMap(parseOne)
    }

    static func parseOne(_ dict: [String: Any]) -> NestThermostat? {
        let traits = dict["traits"] as? [String: Any] ?? [:]
        guard let modeTrait = traits[modeKey] as? [String: Any] else { return nil }  // not a thermostat

        let name = dict["name"] as? String ?? ""
        let mode = (modeTrait["mode"] as? String).flatMap(NestMode.init(rawValue:)) ?? .off
        let available = (modeTrait["availableModes"] as? [String] ?? []).compactMap(NestMode.init(rawValue:))

        let temp = traits[tempKey] as? [String: Any]
        let ambient = temp?["ambientTemperatureCelsius"] as? Double

        let humidityTrait = traits[humidityKey] as? [String: Any]
        let humidity = humidityTrait?["ambientHumidityPercent"] as? Double

        let setpoint = traits[setpointKey] as? [String: Any]
        let heat = setpoint?["heatCelsius"] as? Double
        let cool = setpoint?["coolCelsius"] as? Double

        let hvac = (traits[hvacKey] as? [String: Any])?["status"] as? String

        // Room name from parentRelations displayName; else the Info customName; else a default.
        let relations = dict["parentRelations"] as? [[String: Any]] ?? []
        let roomFromParent = relations.compactMap { $0["displayName"] as? String }.first { !$0.isEmpty }
        let customName = (traits[infoKey] as? [String: Any])?["customName"] as? String
        let room = roomFromParent ?? (customName?.isEmpty == false ? customName : nil) ?? "Thermostat"

        return NestThermostat(
            id: name,
            roomName: room,
            ambientCelsius: ambient,
            humidityPercent: humidity,
            mode: mode,
            availableModes: available,
            heatCelsius: heat,
            coolCelsius: cool,
            hvacStatus: hvac
        )
    }
}

// MARK: - SDM command bodies

/// Pure `:executeCommand` request-body builders (unit-tested for the exact command strings + Celsius
/// conversion). The single source of truth the live transport, the mock, and the P14 agent tools share.
public enum NestCommand {
    /// The body for a mode-appropriate setpoint change (converts °F → °C for the wire).
    public static func setpointBody(_ setpoint: NestSetpoint) -> [String: Any] {
        switch setpoint {
        case let .heat(f):
            return ["command": "sdm.devices.commands.ThermostatTemperatureSetpoint.SetHeat",
                    "params": ["heatCelsius": NestTemp.fToC(Double(f))]]
        case let .cool(f):
            return ["command": "sdm.devices.commands.ThermostatTemperatureSetpoint.SetCool",
                    "params": ["coolCelsius": NestTemp.fToC(Double(f))]]
        case let .range(heat, cool):
            return ["command": "sdm.devices.commands.ThermostatTemperatureSetpoint.SetRange",
                    "params": ["heatCelsius": NestTemp.fToC(Double(heat)),
                               "coolCelsius": NestTemp.fToC(Double(cool))]]
        }
    }

    /// The body for a mode change.
    public static func modeBody(_ mode: NestMode) -> [String: Any] {
        ["command": "sdm.devices.commands.ThermostatMode.SetMode",
         "params": ["mode": mode.rawValue]]
    }
}
