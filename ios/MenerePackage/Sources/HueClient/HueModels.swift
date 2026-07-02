import FamilyDomain
import Foundation

// Client-surface value types for the "house" card. These describe *live* bridge state (rooms,
// lights, scenes, sensor temps) — the identity/mapping half lives in `FamilyDomain.HueConfig`.
// All are Foundation-clean, Sendable, and Equatable so they flow through TCA state.

/// A freshly-paired bridge's identity + friendly name, read from `/config` during pairing (P12-C3).
/// The name (e.g. "Downstairs Hub") is stored in `HueBridgeConfig.name` and shown in Settings.
public struct HueBridgeInfo: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One reachable bridge's live state, produced by `HueClient.readBridge`. The Today "house" card
/// aggregates these across all reachable bridges (P12-C3): temps merge, lights sum, and each
/// ritual's button renders only when *its* bridge produced a snapshot.
public struct BridgeSnapshot: Equatable, Sendable, Identifiable {
    public var bridge: HueBridgeConfig
    public var rooms: [HueRoom]
    public var lights: [HueLight]
    public var scenes: [HueScene]
    public var temperatures: [HueTemperature]

    public var id: String { bridge.bridgeId }

    public init(
        bridge: HueBridgeConfig,
        rooms: [HueRoom] = [],
        lights: [HueLight] = [],
        scenes: [HueScene] = [],
        temperatures: [HueTemperature] = []
    ) {
        self.bridge = bridge
        self.rooms = rooms
        self.lights = lights
        self.scenes = scenes
        self.temperatures = temperatures
    }
}

/// A Hue V1 group we treat as a room/zone.
public struct HueRoom: Equatable, Sendable, Identifiable {
    /// The V1 group id.
    public let id: String
    public let name: String
    /// Raw V1 group type ("Room" / "Zone").
    public let type: String
    /// V1 light ids belonging to this group.
    public let lightIds: [String]
    /// Whether any light in the group is currently on. `var` so the House surface can flip it
    /// optimistically before the write lands.
    public var anyOn: Bool
    /// Group brightness 1–254 (Hue V1 group `action.bri`) — the last-set group level, used by the
    /// House room-detail slider. Nil when the bridge reports none.
    public var brightness: Int?

    public init(id: String, name: String, type: String, lightIds: [String], anyOn: Bool, brightness: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.lightIds = lightIds
        self.anyOn = anyOn
        self.brightness = brightness
    }
}

/// A single Hue light's state. The card needs only on-ness + name; the House surface (P12-C4) also
/// needs brightness (for the per-light slider) and reachability (unreachable lights dim + disable).
public struct HueLight: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// `var` so House rows flip optimistically ahead of the write.
    public var isOn: Bool
    /// Current brightness 1–254 (Hue V1 `state.bri`); nil when the light isn't dimmable / reports none.
    public var brightness: Int?
    /// Whether the bridge can currently reach the light (V1 `state.reachable`). Unreachable lights
    /// render ink-soft with disabled controls.
    public var reachable: Bool

    public init(id: String, name: String, isOn: Bool, brightness: Int? = nil, reachable: Bool = true) {
        self.id = id
        self.name = name
        self.isOn = isOn
        self.brightness = brightness
        self.reachable = reachable
    }
}

/// A recallable Hue V1 scene.
public struct HueScene: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// The group the scene targets, when the bridge reports one.
    public let groupId: String?

    public init(id: String, name: String, groupId: String?) {
        self.id = id
        self.name = name
        self.groupId = groupId
    }
}

/// A bridge found via cloud discovery (`discovery.meethue.com`) during pairing (P12-C2). Just an
/// identity + LAN address — the pairing flow mints an app key against `ip` and confirms `id` via
/// `/config`.
public struct DiscoveredBridge: Equatable, Sendable, Identifiable {
    /// Bridge id (MAC-derived), as reported by cloud discovery.
    public let id: String
    /// The bridge's current LAN IP.
    public let ip: String

    public init(id: String, ip: String) {
        self.id = id
        self.ip = ip
    }
}

/// A ZLLTemperature sensor's identity + bridge name, used by the pairing binding step (P12-C2) to
/// label sensors and capture `sensorNames` for future re-matching. (Distinct from `HueTemperature`,
/// which carries the live reading but not the name.)
public struct HueSensorInfo: Equatable, Sendable, Identifiable {
    public let id: String
    /// The sensor's `name` as reported by the bridge (e.g. "Hue motion sensor 1").
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A ZLLTemperature reading, already converted to °F (the family is US).
public struct HueTemperature: Equatable, Sendable, Identifiable {
    public let sensorId: String
    public let tempF: Double
    /// The sensor's `state.lastupdated` (ISO-ish string) when available.
    public let lastUpdated: String?

    public var id: String { sensorId }

    public init(sensorId: String, tempF: Double, lastUpdated: String?) {
        self.sensorId = sensorId
        self.tempF = tempF
        self.lastUpdated = lastUpdated
    }
}
