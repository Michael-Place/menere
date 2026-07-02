import Foundation

/// Optional configuration for the household's Sonos speakers (P15-C2), decoded from Firestore at
/// `households/{hid}/config/sonos`. **Unlike Hue and Lutron, this doc is entirely optional** — Sonos
/// control is pure LAN UPnP with NO pairing and NO credentials, so discovery is the whole setup. An
/// absent doc means "live-discover the speakers"; the doc exists only to (a) force the stateful MOCK
/// fixtures for bridge-less verification (`mock: true`) and (b) carry a cosmetic `roomOrder`.
///
/// ## Why there is no credential here
/// Sonos players advertise on the LAN via Bonjour (`_sonos._tcp`) and answer UPnP/SOAP on port 1400
/// with no authentication whatsoever. There is nothing to pair and nothing secret to store — which is
/// why this chunk adds no Settings pairing flow (a deliberate design feature, not an omission). The
/// config doc is a convenience, not a requirement.
///
/// ## Decode-safety
/// Every field is optional; an empty `{}` doc, a `{ "mock": true }` doc, or an absent doc all resolve
/// cleanly — the same decode-safe contract every family config carries.
public struct SonosConfig: Codable, Equatable, Sendable {
    /// When true, `SonosClient` serves stateful in-memory fixtures instead of touching the LAN — the
    /// speaker-less verification path (mirrors `LutronConfig.mock`). Live households leave this nil.
    public var mock: Bool?
    /// Optional cosmetic ordering of the Speakers section, by room name (case-insensitive match against
    /// a group's coordinator / member ZoneNames). Rooms not listed fall to the end, alphabetically.
    public var roomOrder: [String]?

    public init(mock: Bool? = nil, roomOrder: [String]? = nil) {
        self.mock = mock
        self.roomOrder = roomOrder
    }

    private enum CodingKeys: String, CodingKey {
        case mock, roomOrder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mock = try c.decodeIfPresent(Bool.self, forKey: .mock)
        roomOrder = try c.decodeIfPresent([String].self, forKey: .roomOrder)
    }

    /// True when the client should serve fixtures rather than hit the LAN.
    public var isMock: Bool { mock == true }
}
