import Foundation

/// Identity + family-mapping config for the household's Philips Hue **bridges**, decoded from
/// Firestore at `households/{hid}/config/hue`. This is the *stable* half of the config/live split
/// (P12): it holds who-owns-what and which scene means "Bedtime"/"Dinner"; the bridges themselves
/// supply the live inventory (rooms, lights, scenes, sensor temps).
///
/// ## Multi-bridge (P12-C3)
/// A household can pair **several** bridges (Michael has three: Downstairs + two upstairs). The
/// canonical shape carries a `bridges` array; every ritual and sensor entry is **scoped to a
/// bridgeId** so a ritual button routes its scene recall to the right bridge and a sensor label
/// belongs to the bridge that owns that sensor id.
///
/// ## Migration (decode-safe both ways)
/// P12-C1/C2 wrote a **single-bridge** doc with top-level `bridgeId`/`bridgeIP`/`applicationKey`,
/// flat `rituals` (no bridgeId) and flat `sensorLabels`/`sensorNames` (`[sensorId: value]`). When
/// those legacy fields are present (and no `bridges` array), `init(from:)` folds them into a
/// one-element `bridges` array and scopes the existing rituals + sensor maps to that bridge's id —
/// **losslessly** (the app key is preserved verbatim). Encoding **always** writes the new shape, so
/// the doc upgrades organically on the next save. See `HueConfigMigrationTests`.
///
/// ## Sensor keying choice
/// `sensorLabels` / `sensorNames` are **nested per-bridge**: `[bridgeId: [sensorId: value]]`. Sensor
/// ids are only unique within a bridge, so nesting keeps them unambiguous across bridges and keeps
/// the JSON a plain dict-of-dicts (Firestore/Codable-friendly — no delimiter parsing).
public struct HueConfig: Codable, Equatable, Sendable {
    /// Every paired bridge. One element after a single pairing; more as bridges are added.
    public var bridges: [HueBridgeConfig]
    /// The family rituals surfaced as one-tap buttons on Today. Each is scoped to the bridge whose
    /// scene it recalls (`HueRitual.bridgeId`).
    public var rituals: [HueRitual]
    /// Optional groupId → memberId map (which room "belongs" to which family member). Reserved for
    /// later member-flavored automations; decoded but not yet surfaced by the card.
    public var roomOwners: [String: String]?
    /// `[bridgeId: [sensorId: label]]` — human labels for the ZLLTemperature sensors we treat as
    /// room thermometers. Only labeled sensors appear on the card.
    public var sensorLabels: [String: [String: String]]
    /// `[bridgeId: [sensorId: bridgeName]]` — each temperature sensor's *bridge name* at pairing
    /// time, captured for **every** sensor so a re-pair against a fresh bridge can re-match by name
    /// and carry old labels forward. Nil on docs that never captured names.
    public var sensorNames: [String: [String: String]]?

    public init(
        bridges: [HueBridgeConfig],
        rituals: [HueRitual] = [],
        roomOwners: [String: String]? = nil,
        sensorLabels: [String: [String: String]] = [:],
        sensorNames: [String: [String: String]]? = nil
    ) {
        self.bridges = bridges
        self.rituals = rituals
        self.roomOwners = roomOwners
        self.sensorLabels = sensorLabels
        self.sensorNames = sensorNames
    }

    /// Legacy single-bridge convenience — folds top-level identity into a one-element `bridges`
    /// array and scopes the flat rituals/sensor maps to that bridge. Used by tests and by internal
    /// migration. `mock` propagates to the single bridge.
    public init(
        bridgeId: String,
        bridgeIP: String,
        applicationKey: String,
        rituals: [HueRitual] = [],
        roomOwners: [String: String]? = nil,
        sensorLabels: [String: String] = [:],
        sensorNames: [String: String]? = nil,
        mock: Bool? = nil,
        bridgeName: String? = nil
    ) {
        self.bridges = [HueBridgeConfig(
            bridgeId: bridgeId, bridgeIP: bridgeIP, applicationKey: applicationKey,
            name: bridgeName, mock: mock
        )]
        self.rituals = rituals.map { r in
            r.bridgeId.isEmpty ? HueRitual(key: r.key, label: r.label, sceneId: r.sceneId, groupId: r.groupId, bridgeId: bridgeId) : r
        }
        self.roomOwners = roomOwners
        self.sensorLabels = sensorLabels.isEmpty ? [:] : [bridgeId: sensorLabels]
        self.sensorNames = sensorNames.map { [bridgeId: $0] }
    }

    private enum CodingKeys: String, CodingKey {
        // New shape
        case bridges, rituals, roomOwners, sensorLabels, sensorNames
        // Legacy single-bridge shape (decode-only)
        case bridgeId, bridgeIP, applicationKey, mock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Rituals decode uniformly: HueRitual is decode-safe for a missing `bridgeId` (defaults to
        // ""), so legacy rituals decode with an empty bridgeId that the migration branch fills in.
        let decodedRituals = try c.decodeIfPresent([HueRitual].self, forKey: .rituals) ?? []
        roomOwners = try c.decodeIfPresent([String: String].self, forKey: .roomOwners)

        if let bridges = try c.decodeIfPresent([HueBridgeConfig].self, forKey: .bridges) {
            // NEW shape.
            self.bridges = bridges
            self.rituals = decodedRituals
            self.sensorLabels = try c.decodeIfPresent([String: [String: String]].self, forKey: .sensorLabels) ?? [:]
            self.sensorNames = try c.decodeIfPresent([String: [String: String]].self, forKey: .sensorNames)
        } else {
            // LEGACY single-bridge shape → migrate. bridgeId/IP/key are required in a legacy doc.
            let bridgeId = try c.decode(String.self, forKey: .bridgeId)
            let bridgeIP = try c.decode(String.self, forKey: .bridgeIP)
            let applicationKey = try c.decode(String.self, forKey: .applicationKey)
            let mock = try c.decodeIfPresent(Bool.self, forKey: .mock)
            self.bridges = [HueBridgeConfig(
                bridgeId: bridgeId, bridgeIP: bridgeIP, applicationKey: applicationKey, name: nil, mock: mock
            )]
            self.rituals = decodedRituals.map { r in
                HueRitual(key: r.key, label: r.label, sceneId: r.sceneId, groupId: r.groupId, bridgeId: bridgeId)
            }
            let flatLabels = try c.decodeIfPresent([String: String].self, forKey: .sensorLabels) ?? [:]
            self.sensorLabels = flatLabels.isEmpty ? [:] : [bridgeId: flatLabels]
            let flatNames = try c.decodeIfPresent([String: String].self, forKey: .sensorNames)
            self.sensorNames = flatNames.map { [bridgeId: $0] }
        }
    }

    /// Encodes the NEW shape only — never the legacy top-level identity fields — so every save
    /// upgrades a legacy doc in place.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bridges, forKey: .bridges)
        try c.encode(rituals, forKey: .rituals)
        try c.encodeIfPresent(roomOwners, forKey: .roomOwners)
        try c.encode(sensorLabels, forKey: .sensorLabels)
        try c.encodeIfPresent(sensorNames, forKey: .sensorNames)
    }

    // MARK: - Convenience

    /// True when *every* paired bridge is a mock bridge (fixtures, no network). A config may also be
    /// mixed (some mock, some live); per-bridge `isMock` is the authoritative flag.
    public var isMock: Bool { !bridges.isEmpty && bridges.allSatisfy(\.isMock) }

    /// The bridge that owns `bridgeId`, if paired.
    public func bridge(_ bridgeId: String) -> HueBridgeConfig? {
        bridges.first { $0.bridgeId == bridgeId }
    }

    /// The labels for one bridge's sensors (empty when none).
    public func sensorLabels(for bridgeId: String) -> [String: String] {
        sensorLabels[bridgeId] ?? [:]
    }
}

/// One paired Philips Hue bridge: its identity, LAN address, and minted app key.
public struct HueBridgeConfig: Codable, Equatable, Sendable, Identifiable {
    /// Bridge id (MAC-derived) — the stable identity used to re-find the bridge via cloud discovery
    /// when its LAN IP drifts, and the scope key for rituals + sensor maps.
    public var bridgeId: String
    /// Current LAN IP of the bridge. May drift (DHCP); the client self-heals via `rediscover`.
    public var bridgeIP: String
    /// The whitelisted application key ("username") minted during pairing — required on every call.
    public var applicationKey: String
    /// The bridge's friendly `name` from its `/config` at pairing time (e.g. "Downstairs Hub"),
    /// shown in the Settings bridge list. Nil on docs migrated from before names were captured.
    public var name: String?
    /// When true, the live `HueClient` serves fixtures for this bridge instead of hitting the
    /// network. Real bridges leave this nil/false.
    public var mock: Bool?

    public var id: String { bridgeId }

    public init(bridgeId: String, bridgeIP: String, applicationKey: String, name: String? = nil, mock: Bool? = nil) {
        self.bridgeId = bridgeId
        self.bridgeIP = bridgeIP
        self.applicationKey = applicationKey
        self.name = name
        self.mock = mock
    }

    /// True when the client should serve fixtures rather than hit this bridge.
    public var isMock: Bool { mock == true }

    /// A user-facing name: the captured bridge name, else the bridge id.
    public var displayName: String { name ?? bridgeId }
}

/// One tappable family ritual: a named scene recalled onto a specific room/group of a specific
/// bridge.
public struct HueRitual: Codable, Equatable, Sendable, Identifiable {
    /// Stable ritual key. The card gives "bedtime"/"dinner" special symbols + prominence rules.
    public var key: String
    /// Button label, e.g. "Bedtime" or "Dinner's ready".
    public var label: String
    /// The Hue V1 scene id to recall.
    public var sceneId: String
    /// The Hue V1 group (room/zone) id the scene is recalled onto.
    public var groupId: String
    /// The bridge (`HueBridgeConfig.bridgeId`) this ritual lives on — routes the scene recall and
    /// gates the button on that bridge's reachability. Decode-safe: legacy rituals carried no
    /// bridgeId (defaults to "" and the config migration fills it from the single bridge).
    public var bridgeId: String

    /// **Cross-ecosystem shade actions (P15-C1).** When present, recalling this ritual ALSO drives
    /// the household's Lutron shades to the given levels, fire-and-forget alongside the Hue scene —
    /// so "Bedtime" both dims the boys' lights and closes their shades in one tap. Each entry names a
    /// LEAP zone id and a target level (0 = closed, 100 = open). Decode-safe (`decodeIfPresent`): a
    /// ritual with no `shadeActions` is exactly the pre-P15 behavior (Hue-only). There is no pairing
    /// UI to edit these yet — config-as-conversation: Michael can name his exact shades and the field
    /// gets written to his Bedtime ritual in the config doc (an editing UI is future polish).
    public var shadeActions: [ShadeAction]?

    /// Rituals are unique by (key, bridgeId): the same standard ritual could in principle exist on
    /// two bridges, though the app binds each standard ritual to one bridge at a time.
    public var id: String { "\(bridgeId)/\(key)" }

    public init(
        key: String, label: String, sceneId: String, groupId: String,
        bridgeId: String = "", shadeActions: [ShadeAction]? = nil
    ) {
        self.key = key
        self.label = label
        self.sceneId = sceneId
        self.groupId = groupId
        self.bridgeId = bridgeId
        self.shadeActions = shadeActions
    }

    private enum CodingKeys: String, CodingKey {
        case key, label, sceneId, groupId, bridgeId, shadeActions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        sceneId = try c.decode(String.self, forKey: .sceneId)
        groupId = try c.decode(String.self, forKey: .groupId)
        bridgeId = try c.decodeIfPresent(String.self, forKey: .bridgeId) ?? ""
        shadeActions = try c.decodeIfPresent([ShadeAction].self, forKey: .shadeActions)
    }
}

/// One shade-level target folded into a `HueRitual` (P15-C1). Pure data in `FamilyDomain` so the
/// ritual model stays free of any Lutron transport dependency; `LutronClient.setShadeLevel` consumes
/// `zoneId` + `level` at recall time.
public struct ShadeAction: Codable, Equatable, Sendable, Identifiable {
    /// The LEAP zone id (e.g. `"5"` for `/zone/5`) to drive.
    public var zoneId: String
    /// Target level 0–100 (0 = fully closed, 100 = fully open), clamped by the client.
    public var level: Int

    public var id: String { zoneId }

    public init(zoneId: String, level: Int) {
        self.zoneId = zoneId
        self.level = level
    }
}
