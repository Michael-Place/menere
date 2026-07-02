import Dependencies
import DependenciesMacros
import FamilyDomain
import Foundation

/// Read-only Philips Hue consumer for the "house" card. Deliberately tiny: no pairing, no device
/// browser, no writes beyond scene recall. Everything is keyed off a `HueConfig` (identity +
/// mappings) that is written outside the app.
///
/// **Ported from NowSpinning's `HueClient`** (trimmed): the `HueURLSession` shell (async/await
/// URLSession, 10s/30s timeouts, and the self-signed-cert trust bypass restricted to private-IP
/// hosts), the V1 group/light decoding, and the `{"error":{...}}` response scan. **New here:** V1
/// scenes, V1 ZLLTemperature sensors (centi-°C → °F), cloud rediscovery, and MOCK MODE.
@DependencyClient
public struct HueClient: Sendable {
    /// Short-timeout reachability probe (GET `/config`). Never throws for a *reachable* bridge.
    public var testConnection: @Sendable (_ config: HueConfig) async throws -> Bool
    /// Rooms/zones (V1 groups filtered to Room/Zone).
    public var rooms: @Sendable (_ config: HueConfig) async throws -> [HueRoom]
    /// All lights with on/off state.
    public var lights: @Sendable (_ config: HueConfig) async throws -> [HueLight]
    /// Recallable scenes.
    public var scenes: @Sendable (_ config: HueConfig) async throws -> [HueScene]
    /// Recall `sceneId` onto `groupId` (PUT group action `{"scene": …}`).
    public var recallScene: @Sendable (_ config: HueConfig, _ groupId: String, _ sceneId: String) async throws -> Void
    /// ZLLTemperature sensors → °F readings.
    public var temperatures: @Sendable (_ config: HueConfig) async throws -> [HueTemperature]
    /// Re-find the bridge's current LAN IP via cloud discovery, matched on `bridgeId`. Nil when the
    /// bridge isn't listed (offline / different network). Powers IP-drift self-healing.
    public var rediscover: @Sendable (_ bridgeId: String) async throws -> String?
}

// MARK: - Live

extension HueClient: DependencyKey {
    public static var liveValue: HueClient {
        let session = HueURLSession()

        return HueClient(
            testConnection: { config in
                if config.isMock { return true }
                return try await session.testConnection(config)
            },
            rooms: { config in
                config.isMock ? HueFixtures.rooms : try await session.rooms(config)
            },
            lights: { config in
                config.isMock ? HueFixtures.lights : try await session.lights(config)
            },
            scenes: { config in
                config.isMock ? HueFixtures.scenes : try await session.scenes(config)
            },
            recallScene: { config, groupId, sceneId in
                if config.isMock {
                    // Believable latency, then success — the card shows its checkmark morph.
                    try? await Task.sleep(for: .milliseconds(300))
                    return
                }
                try await session.recallScene(config, groupId: groupId, sceneId: sceneId)
            },
            temperatures: { config in
                config.isMock ? HueFixtures.temperatures : try await session.temperatures(config)
            },
            rediscover: { bridgeId in
                // Discovery is a public cloud endpoint — same in mock and live (mock never needs it
                // because `testConnection` already returns true).
                try await session.rediscover(bridgeId: bridgeId)
            }
        )
    }

    public static let previewValue = HueClient(
        testConnection: { _ in true },
        rooms: { _ in HueFixtures.rooms },
        lights: { _ in HueFixtures.lights },
        scenes: { _ in HueFixtures.scenes },
        recallScene: { _, _, _ in },
        temperatures: { _ in HueFixtures.temperatures },
        rediscover: { _ in nil }
    )
}

public extension DependencyValues {
    var hue: HueClient {
        get { self[HueClient.self] }
        set { self[HueClient.self] = newValue }
    }
}

// MARK: - Fixtures (MOCK MODE)

/// The believable "Place house" fixture served when `config.mock == true`. Shared by the live
/// client's mock branch and the `previewValue`. Exists only while C0 hasn't paired the real
/// bridge; when the real config doc lands (no `mock` flag) these are never touched.
///
/// Four lights on across Living room + Kitchen (→ "4 lights on — Living room, Kitchen"); the boys'
/// rooms report thermometer temps. Scene ids match the mock config's rituals.
public enum HueFixtures {
    public static let rooms: [HueRoom] = [
        HueRoom(id: "1", name: "Living room", type: "Room", lightIds: ["1", "2"], anyOn: true),
        HueRoom(id: "2", name: "Kitchen", type: "Room", lightIds: ["3", "4"], anyOn: true),
        HueRoom(id: "3", name: "Oliver's room", type: "Room", lightIds: ["5"], anyOn: false),
        HueRoom(id: "4", name: "Famfis's room", type: "Room", lightIds: ["6"], anyOn: false),
        HueRoom(id: "5", name: "Bedroom", type: "Room", lightIds: ["7"], anyOn: false),
    ]

    public static let lights: [HueLight] = [
        HueLight(id: "1", name: "Living room ceiling", isOn: true),
        HueLight(id: "2", name: "Living room lamp", isOn: true),
        HueLight(id: "3", name: "Kitchen counter", isOn: true),
        HueLight(id: "4", name: "Kitchen sink", isOn: true),
        HueLight(id: "5", name: "Oliver's lamp", isOn: false),
        HueLight(id: "6", name: "Famfis's lamp", isOn: false),
        HueLight(id: "7", name: "Bedroom lamp", isOn: false),
    ]

    public static let scenes: [HueScene] = [
        HueScene(id: "bedtime-scene", name: "Bedtime", groupId: "3"),
        HueScene(id: "dinner-scene", name: "Dinner", groupId: "1"),
    ]

    /// sensorIds match the mock config's `sensorLabels` ("sensor-famfis" / "sensor-oliver").
    public static let temperatures: [HueTemperature] = [
        HueTemperature(sensorId: "sensor-famfis", tempF: 72.1, lastUpdated: "2026-07-02T14:00:00"),
        HueTemperature(sensorId: "sensor-oliver", tempF: 71.4, lastUpdated: "2026-07-02T14:00:00"),
    ]
}

// MARK: - URLSession implementation (ported + trimmed from NowSpinning)

/// URLSession shell that trusts the Hue bridge's self-signed cert **only** for private-IP hosts.
/// Ported from NowSpinning; the per-endpoint request builders are new (V1 scenes/sensors) or
/// trimmed (no pairing, no V2/gradient/effects).
private final class HueURLSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private let decoder = JSONDecoder()

    private func base(_ config: HueConfig) -> String {
        "https://\(config.bridgeIP)/api/\(config.applicationKey)"
    }

    // MARK: Reachability

    func testConnection(_ config: HueConfig) async throws -> Bool {
        guard let url = URL(string: "\(base(config))/config") else { throw HueError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4   // short probe — "not home" should fail fast, not hang the card
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw HueError.bridgeUnreachable
            }
            // A valid /config payload has a "name" field.
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["name"] != nil else {
                throw HueError.invalidResponse
            }
            return true
        } catch let error as HueError {
            throw error
        } catch {
            throw HueError.networkError(error.localizedDescription)
        }
    }

    // MARK: Groups (rooms/zones)

    func rooms(_ config: HueConfig) async throws -> [HueRoom] {
        let data = try await get("\(base(config))/groups")
        let dict = try decode([String: GroupResponse].self, data)
        return dict
            .filter { $0.value.type == "Room" || $0.value.type == "Zone" }
            .map { id, g in
                HueRoom(id: id, name: g.name, type: g.type, lightIds: g.lights, anyOn: g.state.any_on)
            }
            .sorted { $0.name < $1.name }
    }

    // MARK: Lights

    func lights(_ config: HueConfig) async throws -> [HueLight] {
        let data = try await get("\(base(config))/lights")
        let dict = try decode([String: LightResponse].self, data)
        return dict
            .map { id, l in HueLight(id: id, name: l.name, isOn: l.state.on) }
            .sorted { $0.name < $1.name }
    }

    // MARK: Scenes

    func scenes(_ config: HueConfig) async throws -> [HueScene] {
        let data = try await get("\(base(config))/scenes")
        let dict = try decode([String: SceneResponse].self, data)
        return dict
            .map { id, s in HueScene(id: id, name: s.name, groupId: s.group) }
            .sorted { $0.name < $1.name }
    }

    // MARK: Scene recall

    func recallScene(_ config: HueConfig, groupId: String, sceneId: String) async throws {
        guard let url = URL(string: "\(base(config))/groups/\(groupId)/action") else {
            throw HueError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scene": sceneId])
        do {
            let (data, _) = try await session.data(for: request)
            try validate(data)
        } catch let error as HueError {
            throw error
        } catch {
            throw HueError.networkError(error.localizedDescription)
        }
    }

    // MARK: Temperature sensors

    func temperatures(_ config: HueConfig) async throws -> [HueTemperature] {
        let data = try await get("\(base(config))/sensors")
        let dict = try decode([String: SensorResponse].self, data)
        return dict
            .filter { $0.value.type == "ZLLTemperature" }
            .compactMap { id, s -> HueTemperature? in
                guard let centiC = s.state.temperature else { return nil }
                // Hue reports centi-degrees Celsius; convert to °F for a US household.
                let celsius = Double(centiC) / 100.0
                let fahrenheit = celsius * 9.0 / 5.0 + 32.0
                return HueTemperature(sensorId: id, tempF: fahrenheit, lastUpdated: s.state.lastupdated)
            }
            .sorted { $0.sensorId < $1.sensorId }
    }

    // MARK: Rediscovery

    func rediscover(bridgeId: String) async throws -> String? {
        guard let url = URL(string: "https://discovery.meethue.com") else {
            throw HueError.discoveryFailed
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw HueError.discoveryFailed
            }
            let entries = try decoder.decode([DiscoveryEntry].self, from: data)
            // Bridge ids can differ in case between discovery and /config — match case-insensitively.
            return entries.first { $0.id.caseInsensitiveCompare(bridgeId) == .orderedSame }?.internalipaddress
        } catch let error as HueError {
            throw error
        } catch {
            throw HueError.networkError(error.localizedDescription)
        }
    }

    // MARK: Helpers

    private func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw HueError.invalidResponse }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw HueError.bridgeUnreachable
            }
            return data
        } catch let error as HueError {
            throw error
        } catch {
            throw HueError.networkError(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // A V1 error payload comes back as an array, not the expected dict — surface it.
            try validate(data)
            throw HueError.invalidResponse
        }
    }

    /// Scan a V1 response for `[{"error": {...}}]` and throw if present (ported pattern).
    private func validate(_ data: Data) throws {
        guard let responses = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return   // non-array (e.g. a resource dict, or empty) → nothing to complain about
        }
        for response in responses {
            if let error = response["error"] as? [String: Any],
               let type = error["type"] as? Int {
                throw HueError.apiError(type, error["description"] as? String ?? "Unknown error")
            }
        }
    }

    // MARK: URLSessionDelegate — trust the bridge's self-signed cert on private IPs only

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if isPrivateIPAddress(challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func isPrivateIPAddress(_ host: String) -> Bool {
        host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
            || host.hasPrefix("172.16.") || host.hasPrefix("172.17.")
            || host.hasPrefix("172.18.") || host.hasPrefix("172.19.")
            || host.hasPrefix("172.2")
            || host.hasPrefix("172.30.") || host.hasPrefix("172.31.")
    }
}

// MARK: - V1 wire models (private)

private struct GroupResponse: Decodable {
    let name: String
    let lights: [String]
    let type: String
    let state: GroupState
    struct GroupState: Decodable { let any_on: Bool }
}

private struct LightResponse: Decodable {
    let name: String
    let state: LightState
    struct LightState: Decodable { let on: Bool }
}

private struct SceneResponse: Decodable {
    let name: String
    let group: String?
    let type: String?
}

private struct SensorResponse: Decodable {
    let type: String
    let state: SensorState
    struct SensorState: Decodable {
        let temperature: Int?
        let lastupdated: String?
    }
}

private struct DiscoveryEntry: Decodable {
    let id: String
    let internalipaddress: String
}
