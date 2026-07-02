import Foundation

/// Identity + credential for the household's Lutron bridge (Caseta Smart Bridge / Smart Bridge Pro
/// or RadioRA3), decoded from Firestore at `households/{hid}/config/lutron`. Mirrors the config/live
/// split established for Hue (P12): this doc holds the *stable* identity — the bridge's LAN address
/// and the client TLS credential minted at pairing time — while live shade inventory + levels come
/// from the bridge over LEAP.
///
/// ## Why the credential lives in the shared config doc (not device Keychain)
/// Lutron pairing (LAP) mints a **client certificate + private key** (plus the bridge's CA), and
/// *that* — not an app-key string like Hue — is the credential every control call authenticates with.
/// Both Michael's and Valentina's phones must control the shades, so the credential MUST be readable
/// by both: it lives in the member-gated config doc as PEM strings (the same "member-gated Firestore
/// is acceptable for a private family app" decision made for the Hue app key), not in per-device
/// Keychain. See `LutronClient` for how the PEMs wire into `Network.framework`'s TLS options.
///
/// ## Decode-safety
/// A hand-written or mock doc (e.g. `{ bridgeIP, mock: true }`) still resolves: the three PEM fields
/// default to `""` when absent, and every optional stays nil. Mock configs never touch the network,
/// so empty PEMs are fine for them.
public struct LutronConfig: Codable, Equatable, Sendable {
    /// Current LAN IP of the Lutron bridge (mDNS-discovered at pairing time). May drift on DHCP.
    public var bridgeIP: String
    /// The bridge's stable id (serial / LEAP device id) when known — captured at pairing for the
    /// Settings status row. Nil on hand-written / older docs.
    public var bridgeId: String?
    /// Friendly bridge name captured at pairing (e.g. "Caseta Smart Bridge"), shown in Settings.
    public var name: String?
    /// PEM-encoded **client certificate** signed by the bridge during LAP pairing. Presented on every
    /// LEAP control connection (port 8081) as the client cert.
    public var clientCertPEM: String
    /// PEM-encoded **client private key** paired with `clientCertPEM` (generated on-device during
    /// pairing; the matching CSR was signed by the bridge).
    public var clientKeyPEM: String
    /// PEM-encoded **bridge CA / root certificate** returned alongside the signed client cert. Used to
    /// pin/anchor the bridge's server cert on the control connection.
    public var bridgeCAPEM: String
    /// Optional friendly-name overrides, keyed by the LEAP **zone href id** (e.g. `"5"` for
    /// `/zone/5`). Live area/room names come from the bridge; this map lets the family rename a shade
    /// ("Oliver's room shade") without editing the bridge. Config-as-conversation, like Hue rituals.
    public var areaNames: [String: String]?
    /// When true, `LutronClient` serves stateful fixtures instead of hitting the LAN — the bridge-less
    /// verification path (mirrors `HueBridgeConfig.mock`). Real bridges leave this nil/false.
    public var mock: Bool?

    public init(
        bridgeIP: String,
        bridgeId: String? = nil,
        name: String? = nil,
        clientCertPEM: String = "",
        clientKeyPEM: String = "",
        bridgeCAPEM: String = "",
        areaNames: [String: String]? = nil,
        mock: Bool? = nil
    ) {
        self.bridgeIP = bridgeIP
        self.bridgeId = bridgeId
        self.name = name
        self.clientCertPEM = clientCertPEM
        self.clientKeyPEM = clientKeyPEM
        self.bridgeCAPEM = bridgeCAPEM
        self.areaNames = areaNames
        self.mock = mock
    }

    private enum CodingKeys: String, CodingKey {
        case bridgeIP, bridgeId, name, clientCertPEM, clientKeyPEM, bridgeCAPEM, areaNames, mock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bridgeIP = try c.decode(String.self, forKey: .bridgeIP)
        bridgeId = try c.decodeIfPresent(String.self, forKey: .bridgeId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        clientCertPEM = try c.decodeIfPresent(String.self, forKey: .clientCertPEM) ?? ""
        clientKeyPEM = try c.decodeIfPresent(String.self, forKey: .clientKeyPEM) ?? ""
        bridgeCAPEM = try c.decodeIfPresent(String.self, forKey: .bridgeCAPEM) ?? ""
        areaNames = try c.decodeIfPresent([String: String].self, forKey: .areaNames)
        mock = try c.decodeIfPresent(Bool.self, forKey: .mock)
    }

    /// True when the client should serve fixtures rather than hit the bridge.
    public var isMock: Bool { mock == true }

    /// A user-facing bridge name: the captured name, else the bridge id, else the IP.
    public var displayName: String { name ?? bridgeId ?? bridgeIP }

    /// A friendly override for a zone, if the family renamed it.
    public func overrideName(forZone zoneId: String) -> String? {
        areaNames?[zoneId]
    }
}
