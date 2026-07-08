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
    /// **Fixtures (P16-fixtures)** — the family's Bacán-side "lamps & fixtures": each collapses two or
    /// more anonymous Hue bulbs into one named thing (a "Living room lamp", a "Kitchen ceiling") so a
    /// room reads as lamps + fixtures instead of raw bulbs. Purely a Bacán soft grouping — the bridge
    /// never learns about them; the House surface fans a fixture's control out to its member lights.
    /// Decode-safe (`decodeIfPresent` → `[]`): a doc that never defined a fixture behaves exactly as
    /// before. Merge-written on its own so a fixture edit never clobbers bridges/rituals/sensors.
    public var fixtures: [HueFixture]

    public init(
        bridges: [HueBridgeConfig],
        rituals: [HueRitual] = [],
        roomOwners: [String: String]? = nil,
        sensorLabels: [String: [String: String]] = [:],
        sensorNames: [String: [String: String]]? = nil,
        fixtures: [HueFixture] = []
    ) {
        self.bridges = bridges
        self.rituals = rituals
        self.roomOwners = roomOwners
        self.sensorLabels = sensorLabels
        self.sensorNames = sensorNames
        self.fixtures = fixtures
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
        bridgeName: String? = nil,
        fixtures: [HueFixture] = []
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
        self.fixtures = fixtures
    }

    private enum CodingKeys: String, CodingKey {
        // New shape
        case bridges, rituals, roomOwners, sensorLabels, sensorNames, fixtures
        // Legacy single-bridge shape (decode-only)
        case bridgeId, bridgeIP, applicationKey, mock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Rituals decode uniformly: HueRitual is decode-safe for a missing `bridgeId` (defaults to
        // ""), so legacy rituals decode with an empty bridgeId that the migration branch fills in.
        let decodedRituals = try c.decodeIfPresent([HueRitual].self, forKey: .rituals) ?? []
        roomOwners = try c.decodeIfPresent([String: String].self, forKey: .roomOwners)
        // Fixtures are a pure Bacán-side overlay and decode the same in either doc shape (legacy docs
        // simply never carried the key → []).
        fixtures = try c.decodeIfPresent([HueFixture].self, forKey: .fixtures) ?? []

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
        try c.encode(fixtures, forKey: .fixtures)
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

    // MARK: - Fixture CRUD (P16-fixtures)
    //
    // Pure value-level mutations on the `fixtures` array ONLY — every one leaves bridges / rituals /
    // roomOwners / sensorLabels / sensorNames untouched. The reducer applies one of these, then
    // merge-writes just the resulting `fixtures` array back to the doc (`updateHueFixtures`), so a
    // fixture edit can never clobber the paired-bridge / ritual / sensor data.

    /// The fixtures whose home is `roomId`, in insertion order.
    public func fixtures(inRoom roomId: String) -> [HueFixture] {
        fixtures.filter { $0.roomId == roomId }
    }

    /// The fixture that owns `lightId` (a light belongs to at most one fixture), if any.
    public func fixture(owningLight lightId: String) -> HueFixture? {
        fixtures.first { $0.lightIds.contains(lightId) }
    }

    /// Add a fixture, first pruning its member lights out of any *other* fixture so a bulb never lives
    /// in two lamps at once (last write wins). Returns a mutated copy.
    public func addingFixture(_ fixture: HueFixture) -> HueConfig {
        var copy = self
        let claimed = Set(fixture.lightIds)
        copy.fixtures = copy.fixtures.compactMap { existing in
            guard existing.id != fixture.id else { return nil }
            var e = existing
            e.lightIds.removeAll { claimed.contains($0) }
            return e.lightIds.isEmpty ? nil : e   // a fixture emptied by the claim dissolves
        }
        copy.fixtures.append(fixture)
        return copy
    }

    /// Remove a fixture entirely (un-combine → its bulbs render individually again). Returns a copy.
    public func removingFixture(_ fixtureId: String) -> HueConfig {
        var copy = self
        copy.fixtures.removeAll { $0.id == fixtureId }
        return copy
    }

    /// Rename a fixture (and optionally re-kind it). No-op when the id is unknown. Returns a copy.
    public func renamingFixture(_ fixtureId: String, name: String, kind: HueFixtureKind? = nil) -> HueConfig {
        var copy = self
        guard let i = copy.fixtures.firstIndex(where: { $0.id == fixtureId }) else { return self }
        copy.fixtures[i].name = name
        if let kind { copy.fixtures[i].kind = kind }
        return copy
    }

    /// Add a member light to a fixture (pruning it from any other fixture first). Returns a copy.
    public func addingLight(_ lightId: String, toFixture fixtureId: String) -> HueConfig {
        var copy = self
        guard copy.fixtures.contains(where: { $0.id == fixtureId }) else { return self }
        for i in copy.fixtures.indices { copy.fixtures[i].lightIds.removeAll { $0 == lightId } }
        if let i = copy.fixtures.firstIndex(where: { $0.id == fixtureId }), !copy.fixtures[i].lightIds.contains(lightId) {
            copy.fixtures[i].lightIds.append(lightId)
        }
        // Any fixture the prune emptied dissolves.
        copy.fixtures.removeAll { $0.lightIds.isEmpty }
        return copy
    }

    /// Remove a member light from a fixture; a fixture left with fewer than two bulbs dissolves (a
    /// "lamp" of one bulb is just a bulb). Returns a copy.
    public func removingLight(_ lightId: String, fromFixture fixtureId: String) -> HueConfig {
        var copy = self
        guard let i = copy.fixtures.firstIndex(where: { $0.id == fixtureId }) else { return self }
        copy.fixtures[i].lightIds.removeAll { $0 == lightId }
        if copy.fixtures[i].lightIds.count < 2 { copy.fixtures.remove(at: i) }
        return copy
    }
}

// MARK: - Fixtures (P16-fixtures)

/// The kind of physical fixture a ``HueFixture`` represents — drives its SF Symbol + a friendly label
/// in the combine picker. Decode-safe: an unknown raw value falls back to `.other`.
public enum HueFixtureKind: String, Codable, Sendable, CaseIterable, Equatable {
    case lamp
    case ceiling
    case sconce
    case floorLamp
    case pendant
    case other

    /// The SF Symbol shown on the collapsed fixture row + the kind picker.
    public var symbolName: String {
        switch self {
        case .lamp:      return "lamp.table.fill"
        case .ceiling:   return "light.recessed.fill"
        case .sconce:    return "light.cylindrical.ceiling.fill"
        case .floorLamp: return "lamp.floor.fill"
        case .pendant:   return "lightbulb.led.fill"
        case .other:     return "lightbulb.2.fill"
        }
    }

    /// A short, warm label for the picker ("Table lamp", "Ceiling"…).
    public var label: String {
        switch self {
        case .lamp:      return "Table lamp"
        case .ceiling:   return "Ceiling"
        case .sconce:    return "Sconce"
        case .floorLamp: return "Floor lamp"
        case .pendant:   return "Pendant"
        case .other:     return "Other"
        }
    }

    /// Decode-safe: an unknown/absent raw value resolves to `.other` rather than throwing, so a
    /// hand-written or newer doc never breaks the whole config decode.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HueFixtureKind(rawValue: raw) ?? .other
    }
}

/// One Bacán-side **fixture / lamp**: a named group of two-or-more Hue bulbs that most physical
/// fixtures carry, collapsed into a single controllable thing. Pure config data (no transport dep) — the
/// House surface fans a fixture's toggle / brightness / color out to `lightIds`, and reads their
/// aggregate back for the collapsed row. `roomId` is the Hue group/zone id the fixture lives in, so a
/// room can render `fixtures + ungrouped bulbs`. Decode-safe throughout.
public struct HueFixture: Codable, Sendable, Equatable, Identifiable {
    /// Stable id (a UUID string minted at combine time) — survives renames + membership edits.
    public var id: String
    /// Family-facing name, e.g. "Living room lamp".
    public var name: String
    /// What kind of fixture this is (icon + label).
    public var kind: HueFixtureKind
    /// The Hue V1 light ids this fixture collapses. Two or more in practice; the model doesn't hard-fail
    /// on one (the reducer's un-combine keeps it ≥2).
    public var lightIds: [String]
    /// The Hue group/zone id (room) this fixture belongs to, so room detail can group by room. Optional
    /// for a fixture that spans rooms / has no home yet.
    public var roomId: String?

    public init(id: String = UUID().uuidString, name: String, kind: HueFixtureKind, lightIds: [String], roomId: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.lightIds = lightIds
        self.roomId = roomId
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, lightIds, roomId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Fixture"
        kind = try c.decodeIfPresent(HueFixtureKind.self, forKey: .kind) ?? .other
        lightIds = try c.decodeIfPresent([String].self, forKey: .lightIds) ?? []
        roomId = try c.decodeIfPresent(String.self, forKey: .roomId)
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
