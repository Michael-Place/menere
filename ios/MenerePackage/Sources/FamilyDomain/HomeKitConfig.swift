import Foundation

/// The household's OPTIONAL Apple **HomeKit** config at `households/{hid}/config/homekit` (P15-C7).
///
/// ## Why this is optional (like Sonos, unlike Hue/Meross)
/// HomeKit is **local and keyless** — the app talks to `HMHomeManager` on-device; there is no IP, no
/// device key, no cloud token to persist. Pairing accessories happens in **Apple's Home app**, not here.
/// So unlike Hue/Lutron/Nest/Hubspace/Meross, an **absent doc does NOT hide HomeKit** — the House screen
/// still reads the live Home once the user grants permission. The doc exists for exactly one reason:
/// **`mock`** — to force the door-less verification path (there are no real accessories on the
/// simulator's empty simulated Home, so the mock carries the UI).
///
/// ## Decode-safety
/// Every field is optional; a hand-written `{ mock: true }` (or an empty `{}`) still resolves. An absent
/// doc simply means "no mock" → the live HomeKit path.
public struct HomeKitConfig: Codable, Equatable, Sendable {
    /// When true, `HomeKitClient` serves a stateful fixture Home (a garage door, a front-door lock, two
    /// temperature sensors, a smart plug) instead of reading `HMHomeManager` — the accessory-less
    /// verification path (mirrors `MerossConfig.mock` / `SonosConfig.mock`). Real households leave this
    /// nil/false and rely on the live local Home.
    public var mock: Bool?

    public init(mock: Bool? = nil) {
        self.mock = mock
    }

    private enum CodingKeys: String, CodingKey { case mock }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mock = try c.decodeIfPresent(Bool.self, forKey: .mock)
    }

    /// True when the client should serve the fixture Home rather than read the live `HMHomeManager`.
    public var isMock: Bool { mock == true }
}
