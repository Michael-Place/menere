import FamilyDomain
import Foundation

// Client-surface value types for the Lutron shades integration (P15-C1). These describe *live* bridge
// state (shades + their levels); the identity/credential half lives in `FamilyDomain.LutronConfig`.
// All are Foundation-clean, Sendable, and Equatable so they flow through TCA state.

/// One controllable shade (a LEAP *zone* whose device is a shade/blind), as surfaced by
/// `LutronClient.shades`. Level is Lutron's native 0–100 (0 = closed, 100 = open) — no rescaling.
public struct LutronShade: Equatable, Sendable, Identifiable {
    /// The LEAP zone id (the trailing path component of `/zone/{id}`) — the control target for
    /// `GoToLevel` / `Raise` / `Lower` / `Stop`.
    public let zoneId: String
    /// The shade's friendly name (device Name, or a family override from `LutronConfig.areaNames`).
    public let name: String
    /// The room/area the shade lives in (from the device's `AssociatedArea`), for section grouping.
    public let areaName: String
    /// Current level 0–100. `var` so the House surface can flip it optimistically before the write
    /// lands (mirrors `HueLight.brightness`).
    public var level: Int

    public var id: String { zoneId }

    public init(zoneId: String, name: String, areaName: String, level: Int) {
        self.zoneId = zoneId
        self.name = name
        self.areaName = areaName
        self.level = level
    }
}

/// A Lutron bridge found via mDNS (`_lutron._tcp`) during pairing. Just an address + best-effort
/// name/id — the pairing flow runs the LAP handshake against `ip`.
public struct DiscoveredLutronBridge: Equatable, Sendable, Identifiable {
    /// mDNS service name / instance (best identity available before pairing), used as the row id.
    public let id: String
    /// The bridge's resolved LAN IP.
    public let ip: String
    /// The advertised friendly name (mDNS instance name), when resolvable.
    public let name: String?

    public init(id: String, ip: String, name: String? = nil) {
        self.id = id
        self.ip = ip
        self.name = name
    }
}

/// The credential minted by a successful LAP pairing (P15-C1): the bridge-signed client certificate,
/// the on-device private key that answers its CSR, and the bridge's CA/root. These PEM strings become
/// `LutronConfig.clientCertPEM` / `clientKeyPEM` / `bridgeCAPEM`. `bridgeId`/`bridgeName` come from the
/// post-pair `/device` read (the bridge device itself), when available.
public struct LutronPairingResult: Equatable, Sendable {
    public let clientCertPEM: String
    public let clientKeyPEM: String
    public let bridgeCAPEM: String
    public let bridgeId: String?
    public let bridgeName: String?

    public init(
        clientCertPEM: String, clientKeyPEM: String, bridgeCAPEM: String,
        bridgeId: String? = nil, bridgeName: String? = nil
    ) {
        self.clientCertPEM = clientCertPEM
        self.clientKeyPEM = clientKeyPEM
        self.bridgeCAPEM = bridgeCAPEM
        self.bridgeId = bridgeId
        self.bridgeName = bridgeName
    }
}
