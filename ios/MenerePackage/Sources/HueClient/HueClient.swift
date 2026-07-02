import Dependencies
import DependenciesMacros
import FamilyDomain
import Foundation

/// Read-only Philips Hue consumer for the "house" card. Deliberately tiny: no device browser, no
/// per-light controls, no writes beyond scene recall. Every operation is keyed off a
/// `HueBridgeConfig` (one bridge's identity + app key); a household may have **several** bridges
/// (P12-C3) and the aggregate helpers (`readBridge`/`readHouse`) fan reads across them with
/// per-bridge resilience.
///
/// **Ported from NowSpinning's `HueClient`** (trimmed): the `HueURLSession` shell (async/await
/// URLSession, 10s/30s timeouts, and the self-signed-cert trust bypass restricted to private-IP
/// hosts), the V1 group/light decoding, and the `{"error":{...}}` response scan. **New here:** V1
/// scenes, V1 ZLLTemperature sensors (centi-°C → °F), cloud rediscovery, pairing, and MOCK MODE.
@DependencyClient
public struct HueClient: Sendable {
    /// Short-timeout reachability probe (GET `/config`). Never throws for a *reachable* bridge.
    public var testConnection: @Sendable (_ bridge: HueBridgeConfig) async throws -> Bool
    /// Rooms/zones (V1 groups filtered to Room/Zone).
    public var rooms: @Sendable (_ bridge: HueBridgeConfig) async throws -> [HueRoom]
    /// All lights with on/off state.
    public var lights: @Sendable (_ bridge: HueBridgeConfig) async throws -> [HueLight]
    /// Recallable scenes.
    public var scenes: @Sendable (_ bridge: HueBridgeConfig) async throws -> [HueScene]
    /// Recall `sceneId` onto `groupId` (PUT group action `{"scene": …}`).
    public var recallScene: @Sendable (_ bridge: HueBridgeConfig, _ groupId: String, _ sceneId: String) async throws -> Void

    // MARK: Granular control (P12-C4)
    //
    // SEAM (P14): agent tools wrap these verbs — a natural-language "turn off the kitchen" resolves
    // to `setGroupState`, "dim Oliver's lamp to 30%" to `setLightState` (with `HueBrightness.bri`).
    // The verbs are deliberately reducer-independent (plain client calls keyed off a `HueBridgeConfig`)
    // so the agent harness can call them exactly as the House UI does. Writes use a ~400ms
    // transitiontime for smooth slider ramps; Hue bridges dislike >10 req/s, so *callers* MUST
    // debounce slider spam (the House reducer does — see `HouseReducer`).

    /// Set a room/zone group's power and/or brightness (V1 PUT `/groups/<id>/action`). `on == nil`
    /// leaves power untouched (a pure brightness change); `brightness` is clamped to 1–254.
    public var setGroupState: @Sendable (_ bridge: HueBridgeConfig, _ groupId: String, _ on: Bool?, _ brightness: Int?) async throws -> Void
    /// Set a single light's power and/or brightness (V1 PUT `/lights/<id>/state`). Same nil/clamp
    /// semantics as `setGroupState`.
    public var setLightState: @Sendable (_ bridge: HueBridgeConfig, _ lightId: String, _ on: Bool?, _ brightness: Int?) async throws -> Void
    /// ZLLTemperature sensors → °F readings.
    public var temperatures: @Sendable (_ bridge: HueBridgeConfig) async throws -> [HueTemperature]
    /// ZLLTemperature sensors → id + bridge name (no reading). Used by the pairing binding step to
    /// list/label sensors and capture `sensorNames`.
    public var sensors: @Sendable (_ bridge: HueBridgeConfig) async throws -> [HueSensorInfo]
    /// Re-find a bridge's current LAN IP via cloud discovery, matched on `bridgeId`. Nil when the
    /// bridge isn't listed (offline / different network). Powers IP-drift self-healing.
    public var rediscover: @Sendable (_ bridgeId: String) async throws -> String?

    // MARK: Pairing (P12-C2/C3) — LIVE-only (a mock config never pairs; these have no mock branch).

    /// Cloud-discover bridges on the LAN (`discovery.meethue.com`). May return several.
    public var discoverBridges: @Sendable () async throws -> [DiscoveredBridge]
    /// Mint an application key against the bridge at `bridgeIP` (POST `/api`, devicetype
    /// `"bacan#iphone"`). Throws `HueError.linkButtonNotPressed` (error type 101) until the physical
    /// link button has been pressed within the last ~30s.
    public var authenticate: @Sendable (_ bridgeIP: String) async throws -> String
    /// Read the bridge's id + friendly name from `/api/<key>/config` after a fresh key is minted
    /// (confirms identity and captures the bridge's name for the Settings list).
    public var bridgeInfo: @Sendable (_ bridgeIP: String, _ applicationKey: String) async throws -> HueBridgeInfo
}

// MARK: - Aggregate helpers (multi-bridge)

public extension HueClient {
    /// Read one bridge's full live state. Throws `HueError.bridgeUnreachable` when the reachability
    /// probe fails; each individual read degrades to empty on failure (partial/stale, never error) —
    /// the card must show *something* for a reachable bridge rather than vanish.
    func readBridge(_ bridge: HueBridgeConfig) async throws -> BridgeSnapshot {
        guard (try? await testConnection(bridge)) == true else { throw HueError.bridgeUnreachable }
        async let rooms = self.rooms(bridge)
        async let lights = self.lights(bridge)
        async let scenes = self.scenes(bridge)
        async let temps = self.temperatures(bridge)
        return BridgeSnapshot(
            bridge: bridge,
            rooms: (try? await rooms) ?? [],
            lights: (try? await lights) ?? [],
            scenes: (try? await scenes) ?? [],
            temperatures: (try? await temps) ?? []
        )
    }

    /// Fan reads across all `bridges` concurrently with **per-bridge resilience**: an unreachable
    /// (or throwing) bridge is simply omitted, so one dead bridge never hides another's data. Result
    /// is sorted by bridge id for a stable card. Empty ⇢ no bridge was reachable.
    func readHouse(_ bridges: [HueBridgeConfig]) async -> [BridgeSnapshot] {
        await withTaskGroup(of: BridgeSnapshot?.self) { group in
            for bridge in bridges {
                group.addTask { try? await self.readBridge(bridge) }
            }
            var out: [BridgeSnapshot] = []
            for await snapshot in group {
                if let snapshot { out.append(snapshot) }
            }
            return out.sorted { $0.bridge.bridgeId < $1.bridge.bridgeId }
        }
    }
}

// MARK: - Live

extension HueClient: DependencyKey {
    public static var liveValue: HueClient {
        let session = HueURLSession()

        return HueClient(
            testConnection: { bridge in
                if bridge.isMock { return true }
                return try await session.testConnection(bridge)
            },
            rooms: { bridge in
                // Mock reads flow through the STATEFUL store so toggles/sliders persist for the
                // session and a re-read reflects a just-written change.
                bridge.isMock ? await HueMockStore.shared.rooms(for: bridge.bridgeId) : try await session.rooms(bridge)
            },
            lights: { bridge in
                bridge.isMock ? await HueMockStore.shared.lights(for: bridge.bridgeId) : try await session.lights(bridge)
            },
            scenes: { bridge in
                bridge.isMock ? HueFixtures.scenes(for: bridge.bridgeId) : try await session.scenes(bridge)
            },
            recallScene: { bridge, groupId, sceneId in
                if bridge.isMock {
                    // Believable latency, then success — the card shows its checkmark morph. The
                    // stateful store turns the target group on so a re-read agrees with the recall.
                    try? await Task.sleep(for: .milliseconds(300))
                    await HueMockStore.shared.recallScene(bridgeId: bridge.bridgeId, groupId: groupId)
                    return
                }
                try await session.recallScene(bridge, groupId: groupId, sceneId: sceneId)
            },
            setGroupState: { bridge, groupId, on, brightness in
                if bridge.isMock {
                    await HueMockStore.shared.setGroup(bridgeId: bridge.bridgeId, groupId: groupId, on: on, brightness: brightness)
                    return
                }
                try await session.setGroupState(bridge, groupId: groupId, on: on, brightness: brightness)
            },
            setLightState: { bridge, lightId, on, brightness in
                if bridge.isMock {
                    await HueMockStore.shared.setLight(bridgeId: bridge.bridgeId, lightId: lightId, on: on, brightness: brightness)
                    return
                }
                try await session.setLightState(bridge, lightId: lightId, on: on, brightness: brightness)
            },
            temperatures: { bridge in
                bridge.isMock ? HueFixtures.temperatures(for: bridge.bridgeId) : try await session.temperatures(bridge)
            },
            sensors: { bridge in
                bridge.isMock ? HueFixtures.sensors(for: bridge.bridgeId) : try await session.sensors(bridge)
            },
            rediscover: { bridgeId in
                // Discovery is a public cloud endpoint — same in mock and live (mock never needs it
                // because `testConnection` already returns true).
                try await session.rediscover(bridgeId: bridgeId)
            },
            discoverBridges: { try await session.discoverBridges() },
            authenticate: { bridgeIP in try await session.authenticate(bridgeIP: bridgeIP) },
            bridgeInfo: { bridgeIP, key in try await session.bridgeInfo(bridgeIP: bridgeIP, applicationKey: key) }
        )
    }

    public static let previewValue = HueClient(
        testConnection: { _ in true },
        rooms: { _ in HueFixtures.rooms(for: "") },
        lights: { _ in HueFixtures.lights(for: "") },
        scenes: { _ in HueFixtures.scenes(for: "") },
        recallScene: { _, _, _ in },
        setGroupState: { _, _, _, _ in },
        setLightState: { _, _, _, _ in },
        temperatures: { _ in HueFixtures.temperatures(for: "") },
        sensors: { _ in HueFixtures.sensors(for: "") },
        rediscover: { _ in nil },
        discoverBridges: { [DiscoveredBridge(id: "001788FFFE000001", ip: "192.168.1.42")] },
        authenticate: { _ in "preview-app-key" },
        bridgeInfo: { _, _ in HueBridgeInfo(id: "001788FFFE000001", name: "Preview Bridge") }
    )
}

public extension DependencyValues {
    var hue: HueClient {
        get { self[HueClient.self] }
        set { self[HueClient.self] = newValue }
    }
}

// MARK: - Fixtures (MOCK MODE)

/// The believable "Place house" fixtures served when a bridge's `mock == true`. Shared by the live
/// client's mock branch and the `previewValue`.
///
/// **Per-bridge partitioning (P12-C3):** two known mock bridge ids split the house so a multi-bridge
/// config demonstrates aggregation — `downstairsId` owns Living room + Kitchen (4 lights on, dinner
/// scene), `upstairsId` owns the boys' rooms (bedtime scene + two thermometers). Any *other* mock
/// bridge id (single-bridge previews/tests) gets the **whole** house, preserving C1/C2 behavior.
public enum HueFixtures {
    /// The two partitioned mock bridge ids used by the P12-C3 multi-bridge verification seed.
    public static let downstairsId = "001788FFFEDOWN01"
    public static let upstairsId = "001788FFFEUP0002"

    // Whole-house fixture (default for any unpartitioned mock bridge). Group "6" is a Zone (skipped
    // in the ritual card, surfaced under "Zones" in the House surface); "7" is an Entertainment group
    // that the House surface omits.
    private static let allRooms: [HueRoom] = [
        HueRoom(id: "1", name: "Living room", type: "Room", lightIds: ["1", "2"], anyOn: true, brightness: 203),
        HueRoom(id: "2", name: "Kitchen", type: "Room", lightIds: ["3", "4"], anyOn: true, brightness: 230),
        HueRoom(id: "3", name: "Oliver's room", type: "Room", lightIds: ["5"], anyOn: false, brightness: 120),
        HueRoom(id: "4", name: "Famfis's room", type: "Room", lightIds: ["6"], anyOn: false, brightness: 90),
        HueRoom(id: "5", name: "Bedroom", type: "Room", lightIds: ["7"], anyOn: false, brightness: 150),
        HueRoom(id: "8", name: "Downstairs", type: "Zone", lightIds: ["1", "2", "3", "4"], anyOn: true, brightness: 215),
    ]
    private static let allLights: [HueLight] = [
        HueLight(id: "1", name: "Living room ceiling", isOn: true, brightness: 203),
        HueLight(id: "2", name: "Living room lamp", isOn: true, brightness: 178),
        HueLight(id: "3", name: "Kitchen counter", isOn: true, brightness: 254),
        HueLight(id: "4", name: "Kitchen sink", isOn: true, brightness: 220),
        HueLight(id: "5", name: "Oliver's lamp", isOn: false, brightness: 120),
        // Famfis's lamp is powered off at the wall — the bridge can't reach it. Renders ink-soft with
        // disabled controls in room detail (the P12-C4 unreachable case).
        HueLight(id: "6", name: "Famfis's lamp", isOn: false, brightness: 90, reachable: false),
        HueLight(id: "7", name: "Bedroom lamp", isOn: false, brightness: 150),
    ]
    private static let allScenes: [HueScene] = [
        HueScene(id: "bedtime-scene", name: "Bedtime", groupId: "3"),
        HueScene(id: "dinner-scene", name: "Dinner", groupId: "1"),
    ]
    private static let allTemps: [HueTemperature] = [
        HueTemperature(sensorId: "sensor-famfis", tempF: 72.1, lastUpdated: "2026-07-02T14:00:00"),
        HueTemperature(sensorId: "sensor-oliver", tempF: 71.4, lastUpdated: "2026-07-02T14:00:00"),
    ]
    private static let allSensors: [HueSensorInfo] = [
        HueSensorInfo(id: "sensor-famfis", name: "Famfis room sensor"),
        HueSensorInfo(id: "sensor-oliver", name: "Oliver room sensor"),
    ]

    public static func rooms(for bridgeId: String) -> [HueRoom] {
        switch bridgeId {
        case downstairsId: return allRooms.filter { ["1", "2", "8"].contains($0.id) }   // rooms + the Downstairs zone
        case upstairsId:   return allRooms.filter { ["3", "4"].contains($0.id) }
        default:           return allRooms
        }
    }
    public static func lights(for bridgeId: String) -> [HueLight] {
        switch bridgeId {
        case downstairsId: return allLights.filter { ["1", "2", "3", "4"].contains($0.id) }
        case upstairsId:   return allLights.filter { ["5", "6"].contains($0.id) }
        default:           return allLights
        }
    }
    public static func scenes(for bridgeId: String) -> [HueScene] {
        switch bridgeId {
        case downstairsId: return allScenes.filter { $0.id == "dinner-scene" }
        case upstairsId:   return allScenes.filter { $0.id == "bedtime-scene" }
        default:           return allScenes
        }
    }
    public static func temperatures(for bridgeId: String) -> [HueTemperature] {
        switch bridgeId {
        case downstairsId: return []
        case upstairsId:   return allTemps
        default:           return allTemps
        }
    }
    public static func sensors(for bridgeId: String) -> [HueSensorInfo] {
        switch bridgeId {
        case downstairsId: return []
        case upstairsId:   return allSensors
        default:           return allSensors
        }
    }
}

// MARK: - Stateful mock store (MOCK MODE, P12-C4)

/// In-memory, per-session mutable state for mock bridges. C1–C3 served *static* fixtures — fine for
/// read-only cards, but the granular House surface writes (toggles/sliders/scene recall) and needs a
/// re-read to reflect them. This actor is the mock's single source of truth: seeded lazily from
/// `HueFixtures` per bridge id, then mutated by `setLight`/`setGroup`/`recallScene`. Group `anyOn`
/// is recomputed from member lights after any write so the House room rows and Today's lights summary
/// stay consistent. State lives for the process lifetime (a sim session); a fresh launch re-seeds.
actor HueMockStore {
    static let shared = HueMockStore()

    private var lightsByBridge: [String: [HueLight]] = [:]
    private var roomsByBridge: [String: [HueRoom]] = [:]
    private var seeded: Set<String> = []

    private func seedIfNeeded(_ bridgeId: String) {
        guard !seeded.contains(bridgeId) else { return }
        seeded.insert(bridgeId)
        lightsByBridge[bridgeId] = HueFixtures.lights(for: bridgeId)
        roomsByBridge[bridgeId] = HueFixtures.rooms(for: bridgeId)
    }

    func rooms(for bridgeId: String) -> [HueRoom] {
        seedIfNeeded(bridgeId)
        return roomsByBridge[bridgeId] ?? []
    }

    func lights(for bridgeId: String) -> [HueLight] {
        seedIfNeeded(bridgeId)
        return lightsByBridge[bridgeId] ?? []
    }

    func setLight(bridgeId: String, lightId: String, on: Bool?, brightness: Int?) {
        seedIfNeeded(bridgeId)
        guard var lights = lightsByBridge[bridgeId], let i = lights.firstIndex(where: { $0.id == lightId }) else { return }
        if let on { lights[i].isOn = on }
        if let brightness {
            lights[i].brightness = max(1, min(254, brightness))
            if lights[i].isOn == false { lights[i].isOn = true }   // a bri change implies power-on (Hue behavior)
        }
        lightsByBridge[bridgeId] = lights
        recomputeRooms(bridgeId)
    }

    func setGroup(bridgeId: String, groupId: String, on: Bool?, brightness: Int?) {
        seedIfNeeded(bridgeId)
        guard var rooms = roomsByBridge[bridgeId], let ri = rooms.firstIndex(where: { $0.id == groupId }) else { return }
        let memberIds = Set(rooms[ri].lightIds)
        if var lights = lightsByBridge[bridgeId] {
            for i in lights.indices where memberIds.contains(lights[i].id) && lights[i].reachable {
                if let on { lights[i].isOn = on }
                if let brightness {
                    lights[i].brightness = max(1, min(254, brightness))
                    if let on, on == false {} else { lights[i].isOn = true }
                }
            }
            lightsByBridge[bridgeId] = lights
        }
        if let brightness { rooms[ri].brightness = max(1, min(254, brightness)) }
        roomsByBridge[bridgeId] = rooms
        recomputeRooms(bridgeId)
    }

    func recallScene(bridgeId: String, groupId: String) {
        // A scene recall turns its target group on (brightness left as fixture — scenes carry their
        // own per-light levels we don't model in mock).
        setGroup(bridgeId: bridgeId, groupId: groupId, on: true, brightness: nil)
    }

    /// Recompute every group's `anyOn` from its member lights so rows/summaries agree with writes.
    private func recomputeRooms(_ bridgeId: String) {
        guard var rooms = roomsByBridge[bridgeId], let lights = lightsByBridge[bridgeId] else { return }
        let onIds = Set(lights.filter(\.isOn).map(\.id))
        for i in rooms.indices {
            rooms[i].anyOn = rooms[i].lightIds.contains { onIds.contains($0) }
        }
        roomsByBridge[bridgeId] = rooms
    }
}

// MARK: - URLSession implementation (ported + trimmed from NowSpinning)

/// URLSession shell that trusts the Hue bridge's self-signed cert **only** for private-IP hosts.
/// Ported from NowSpinning; the per-endpoint request builders are new (V1 scenes/sensors) or
/// trimmed (no V2/gradient/effects).
private final class HueURLSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private let decoder = JSONDecoder()

    private func base(_ bridge: HueBridgeConfig) -> String {
        "https://\(bridge.bridgeIP)/api/\(bridge.applicationKey)"
    }

    // MARK: Reachability

    func testConnection(_ bridge: HueBridgeConfig) async throws -> Bool {
        guard let url = URL(string: "\(base(bridge))/config") else { throw HueError.invalidResponse }
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

    func rooms(_ bridge: HueBridgeConfig) async throws -> [HueRoom] {
        let data = try await get("\(base(bridge))/groups")
        let dict = try decode([String: GroupResponse].self, data)
        return dict
            .filter { $0.value.type == "Room" || $0.value.type == "Zone" }
            .map { id, g in
                HueRoom(id: id, name: g.name, type: g.type, lightIds: g.lights, anyOn: g.state.any_on, brightness: g.action?.bri)
            }
            .sorted { $0.name < $1.name }
    }

    // MARK: Lights

    func lights(_ bridge: HueBridgeConfig) async throws -> [HueLight] {
        let data = try await get("\(base(bridge))/lights")
        let dict = try decode([String: LightResponse].self, data)
        return dict
            .map { id, l in HueLight(id: id, name: l.name, isOn: l.state.on, brightness: l.state.bri, reachable: l.state.reachable ?? true) }
            .sorted { $0.name < $1.name }
    }

    // MARK: Scenes

    func scenes(_ bridge: HueBridgeConfig) async throws -> [HueScene] {
        let data = try await get("\(base(bridge))/scenes")
        let dict = try decode([String: SceneResponse].self, data)
        return dict
            .map { id, s in HueScene(id: id, name: s.name, groupId: s.group) }
            .sorted { $0.name < $1.name }
    }

    // MARK: Scene recall

    func recallScene(_ bridge: HueBridgeConfig, groupId: String, sceneId: String) async throws {
        guard let url = URL(string: "\(base(bridge))/groups/\(groupId)/action") else {
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

    // MARK: State setting (P12-C4) — ported from NowSpinning's setLightState/setGroupState

    func setLightState(_ bridge: HueBridgeConfig, lightId: String, on: Bool?, brightness: Int?) async throws {
        guard let url = URL(string: "\(base(bridge))/lights/\(lightId)/state") else { throw HueError.invalidResponse }
        try await putState(url, on: on, brightness: brightness)
    }

    func setGroupState(_ bridge: HueBridgeConfig, groupId: String, on: Bool?, brightness: Int?) async throws {
        guard let url = URL(string: "\(base(bridge))/groups/\(groupId)/action") else { throw HueError.invalidResponse }
        try await putState(url, on: on, brightness: brightness)
    }

    /// Shared PUT for light `/state` and group `/action`. Omits `on` when nil (a pure brightness
    /// change), clamps `bri` to Hue's 1–254, and rides a ~400ms transition so slider ramps read
    /// smoothly rather than snapping.
    private func putState(_ url: URL, on: Bool?, brightness: Int?) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["transitiontime": 4]
        if let on { body["on"] = on }
        if let brightness { body["bri"] = max(1, min(254, brightness)) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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

    func temperatures(_ bridge: HueBridgeConfig) async throws -> [HueTemperature] {
        let data = try await get("\(base(bridge))/sensors")
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

    func sensors(_ bridge: HueBridgeConfig) async throws -> [HueSensorInfo] {
        let data = try await get("\(base(bridge))/sensors")
        let dict = try decode([String: SensorResponse].self, data)
        return dict
            .filter { $0.value.type == "ZLLTemperature" }
            .map { id, s in HueSensorInfo(id: id, name: s.name ?? id) }
            .sorted { $0.id < $1.id }
    }

    // MARK: Pairing (P12-C2/C3)

    /// Cloud discovery — same endpoint as `rediscover`, but returns *all* bridges (no id filter).
    func discoverBridges() async throws -> [DiscoveredBridge] {
        guard let url = URL(string: "https://discovery.meethue.com") else {
            throw HueError.discoveryFailed
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw HueError.discoveryFailed
            }
            let entries = try decoder.decode([DiscoveryEntry].self, from: data)
            return entries.map { DiscoveredBridge(id: $0.id, ip: $0.internalipaddress) }
        } catch let error as HueError {
            throw error
        } catch is DecodingError {
            throw HueError.invalidResponse
        } catch {
            throw HueError.networkError(error.localizedDescription)
        }
    }

    /// Mint an app key. POST `/api` `{"devicetype":"bacan#iphone"}`; error type 101 → not-pressed.
    func authenticate(bridgeIP: String) async throws -> String {
        guard let url = URL(string: "https://\(bridgeIP)/api") else { throw HueError.bridgeUnreachable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["devicetype": "bacan#iphone"])
        do {
            let (data, _) = try await session.data(for: request)
            return try parseAuthResponse(data)
        } catch let error as HueError {
            throw error
        } catch {
            throw HueError.networkError(error.localizedDescription)
        }
    }

    private func parseAuthResponse(_ data: Data) throws -> String {
        guard let responses = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = responses.first else {
            throw HueError.invalidResponse
        }
        if let success = first["success"] as? [String: Any],
           let username = success["username"] as? String {
            return username
        }
        if let error = first["error"] as? [String: Any], let type = error["type"] as? Int {
            if type == 101 { throw HueError.linkButtonNotPressed }
            throw HueError.apiError(type, error["description"] as? String ?? "Unknown error")
        }
        throw HueError.invalidResponse
    }

    /// GET `/api/<key>/config` → the bridge id + friendly name (confirms identity of the
    /// freshly-paired bridge and captures its name for the Settings list).
    func bridgeInfo(bridgeIP: String, applicationKey: String) async throws -> HueBridgeInfo {
        let data = try await get("https://\(bridgeIP)/api/\(applicationKey)/config")
        struct ConfigResponse: Decodable { let bridgeid: String; let name: String? }
        do {
            let cfg = try decoder.decode(ConfigResponse.self, from: data)
            return HueBridgeInfo(id: cfg.bridgeid, name: cfg.name ?? cfg.bridgeid)
        } catch {
            throw HueError.invalidResponse
        }
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
    /// The group's last-applied `action` (V1) — carries the group brightness we surface on the slider.
    let action: GroupAction?
    struct GroupState: Decodable { let any_on: Bool }
    struct GroupAction: Decodable { let bri: Int? }
}

private struct LightResponse: Decodable {
    let name: String
    let state: LightState
    struct LightState: Decodable {
        let on: Bool
        let bri: Int?
        let reachable: Bool?
    }
}

private struct SceneResponse: Decodable {
    let name: String
    let group: String?
    let type: String?
}

private struct SensorResponse: Decodable {
    let name: String?
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
