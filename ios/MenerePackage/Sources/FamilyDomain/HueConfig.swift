import Foundation

/// Identity + family-mapping config for the household's Philips Hue bridge, decoded from
/// Firestore at `households/{hid}/config/hue`. This is the *stable* half of the config/live
/// split (P12): it holds who-owns-what and which scene means "Bedtime"/"Dinner"; the bridge
/// itself supplies the live inventory (rooms, lights, scenes, sensor temps).
///
/// The doc is written **outside the app** — a one-time C0 pairing session mints the app key and
/// writes this doc. The app is a pure consumer: no pairing UI, no discovery flow. Until that doc
/// exists there is simply no "house" card.
///
/// `mock == true` is the pre-C0 escape hatch: the live `HueClient` returns believable fixture
/// data instead of touching the network, so the card can be built and verified before the real
/// bridge is paired. C0's real doc omits `mock` (or sets it false) and everything else is
/// identical — the app needs **zero** code changes to go live.
public struct HueConfig: Codable, Equatable, Sendable {
    /// Bridge id (MAC-derived) — the stable identity used to re-find the bridge via cloud
    /// discovery when its LAN IP drifts.
    public var bridgeId: String
    /// Current LAN IP of the bridge. May drift (DHCP); the client self-heals via `rediscover`.
    public var bridgeIP: String
    /// The whitelisted application key ("username") minted during pairing — required on every call.
    public var applicationKey: String
    /// The family rituals surfaced as one-tap buttons on Today (e.g. "bedtime", "dinner").
    public var rituals: [HueRitual]
    /// Optional groupId → memberId map (which room "belongs" to which family member). Reserved for
    /// later member-flavored automations; decoded but not yet surfaced by the card.
    public var roomOwners: [String: String]?
    /// sensorId → human label for the ZLLTemperature sensors we treat as room thermometers
    /// (e.g. the boys' nursery motion sensors). Only labeled sensors appear on the card.
    public var sensorLabels: [String: String]
    /// When true, the live `HueClient` returns fixtures instead of hitting the bridge. Exists only
    /// while C0 hasn't run; a real config leaves this nil/false.
    public var mock: Bool?

    public init(
        bridgeId: String,
        bridgeIP: String,
        applicationKey: String,
        rituals: [HueRitual] = [],
        roomOwners: [String: String]? = nil,
        sensorLabels: [String: String] = [:],
        mock: Bool? = nil
    ) {
        self.bridgeId = bridgeId
        self.bridgeIP = bridgeIP
        self.applicationKey = applicationKey
        self.rituals = rituals
        self.roomOwners = roomOwners
        self.sensorLabels = sensorLabels
        self.mock = mock
    }

    private enum CodingKeys: String, CodingKey {
        case bridgeId, bridgeIP, applicationKey, rituals, roomOwners, sensorLabels, mock
    }

    /// Decode-safe: a hand-written or partial config doc tolerates missing collections (they
    /// default to empty), so the card degrades to "no rituals / no temps" rather than failing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bridgeId = try c.decode(String.self, forKey: .bridgeId)
        bridgeIP = try c.decode(String.self, forKey: .bridgeIP)
        applicationKey = try c.decode(String.self, forKey: .applicationKey)
        rituals = try c.decodeIfPresent([HueRitual].self, forKey: .rituals) ?? []
        roomOwners = try c.decodeIfPresent([String: String].self, forKey: .roomOwners)
        sensorLabels = try c.decodeIfPresent([String: String].self, forKey: .sensorLabels) ?? [:]
        mock = try c.decodeIfPresent(Bool.self, forKey: .mock)
    }

    /// True when the client should serve fixtures rather than hit the bridge.
    public var isMock: Bool { mock == true }
}

/// One tappable family ritual: a named scene recalled onto a specific room/group.
public struct HueRitual: Codable, Equatable, Sendable, Identifiable {
    /// Stable ritual key. The card gives "bedtime"/"dinner" special symbols + prominence rules.
    public var key: String
    /// Button label, e.g. "Bedtime" or "Dinner's ready".
    public var label: String
    /// The Hue V1 scene id to recall.
    public var sceneId: String
    /// The Hue V1 group (room/zone) id the scene is recalled onto.
    public var groupId: String

    public var id: String { key }

    public init(key: String, label: String, sceneId: String, groupId: String) {
        self.key = key
        self.label = label
        self.sceneId = sceneId
        self.groupId = groupId
    }
}
