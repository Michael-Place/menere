import Foundation

/// Identity + credential for the household's **Refoss garage opener** driven over the **Meross LAN
/// protocol** (P15-C5) — the fleet's **sixth** ecosystem and the final chunk of P15. Decoded from
/// Firestore at `households/{hid}/config/meross`.
///
/// ## Why Meross (and how it's local)
/// Michael's garage opener is a **Refoss** — a rebadged **Meross** device. Refoss/Meross openers speak
/// the Meross HTTP-on-LAN protocol: a signed JSON envelope `POST`ed to `http://<device-ip>/config`.
/// There is **no cloud dependency** for control (unlike Nest/Hubspace) — the phone talks straight to the
/// opener on the home network. The reference is `krahabb/meross_lan` (the canonical LAN-protocol Home
/// Assistant integration); Home Assistant also ships a native `refoss` LAN integration.
///
/// ## The two pieces of the credential
/// - **`deviceIP`** — the opener's LAN address. Refoss/Meross LAN *discovery* is a UDP socket broadcast,
///   which on iOS needs the restricted multicast entitlement — so we deliberately **avoid discovery** and
///   ask for the IP directly (one field; honest; zero-entitlement). In a DHCP-reserved tech-enthusiast
///   home the opener has a stable address anyway.
/// - **`deviceKey`** — the Meross/Refoss account **device key**. Every message is signed
///   `MD5(messageId + key + timestamp)`; a cloud-paired device rejects a wrong key. The key is recoverable
///   from the Meross/Refoss account pairing (meross_lan documents how; ecosystem key-grabber tools exist).
///   Some devices accept an empty key — we allow that too (an empty string still signs).
///
/// ## Config/live split (same posture as the rest of the fleet)
/// The doc holds the *stable* identity — IP + key (+ the discovered `uuid` and a friendly `name` for the
/// status line) — while live door state (open/closed per channel) comes from the device on each read.
/// `mock` gates the door-less verification path.
///
/// ## Decode-safety
/// A hand-written or mock doc (e.g. `{ mock: true }`) still resolves: every field is optional. An absent
/// doc means "garage never set up" — the House "Garage" section simply doesn't render (silent degrade,
/// like Hue/Lutron/Nest/Hubspace).
public struct MerossConfig: Codable, Equatable, Sendable {
    /// The opener's LAN IP (e.g. `192.168.1.42`). The base of the control URL
    /// (`http://<deviceIP>/config`). Nil until setup captures it — its presence (or `mock`) gates
    /// "connected".
    public var deviceIP: String?
    /// The Meross/Refoss **device key** used to sign every envelope (`MD5(messageId + key + timestamp)`).
    /// May be an empty string for a device that accepts an unsigned key; nil until setup.
    public var deviceKey: String?
    /// The device **uuid** (`Appliance.System.All` → `all.system.hardware.uuid`), captured on connect.
    /// Echoed back in the `SET` payload's `state.uuid`, per the Meross garage protocol.
    public var uuid: String?
    /// A friendly device name for the "Connected · {name}" status line (defaults to "Garage" when the
    /// device reports none — LAN `System.All` usually omits the cloud-set name).
    public var name: String?
    /// When true, `MerossClient` serves a stateful fixture door ("Garage", closed) instead of hitting the
    /// device — the door-less verification path (mirrors `HubspaceConfig.mock`). Real households leave
    /// this nil/false.
    public var mock: Bool?

    public init(
        deviceIP: String? = nil,
        deviceKey: String? = nil,
        uuid: String? = nil,
        name: String? = nil,
        mock: Bool? = nil
    ) {
        self.deviceIP = deviceIP
        self.deviceKey = deviceKey
        self.uuid = uuid
        self.name = name
        self.mock = mock
    }

    private enum CodingKeys: String, CodingKey {
        case deviceIP, deviceKey, uuid, name, mock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceIP = try c.decodeIfPresent(String.self, forKey: .deviceIP)
        deviceKey = try c.decodeIfPresent(String.self, forKey: .deviceKey)
        uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        mock = try c.decodeIfPresent(Bool.self, forKey: .mock)
    }

    /// True when the client should serve the fixture door rather than reach the device.
    public var isMock: Bool { mock == true }

    /// True once setup has captured an IP (a `deviceKey` may be empty for a keyless device, so only the IP
    /// is required) — or in mock mode. The "Connected" gate for Settings and the House "Garage" section.
    public var isConnected: Bool {
        isMock || (deviceIP?.isEmpty == false)
    }
}
