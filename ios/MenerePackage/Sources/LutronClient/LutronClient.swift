import Dependencies
import DependenciesMacros
import FamilyDomain
import Foundation
import Network

/// LEAP client for Lutron shades (P15-C1) — the second smart-home ecosystem, built to the same
/// playbook as `HueClient` (P12): a tiny, purpose-built consumer keyed off a Firestore config doc,
/// with a stateful MOCK mode for bridge-less verification. Deliberately narrow: shades only (list +
/// level + raise/lower/stop), plus the LAP pairing handshake. No generic device browser.
///
/// **Credential:** unlike Hue's app-key string, Lutron authenticates every control connection with a
/// TLS **client certificate** minted during pairing. The PEMs live in `LutronConfig` (shared, so both
/// parents' phones control the shades) and wire into `Network.framework`'s TLS via
/// `LutronCrypto.makeIdentity`. See `pair` / `LutronLeapSession`.
///
/// **Ported concept, not code:** the protocol details are faithful to pylutron-caseta
/// (`leap.py` / `smartbridge.py` / `pairing.py`) and lutron-leap-js (`LeapClient.ts` / `Messages.ts`);
/// see `LEAPMessage.swift` for the message framing this consumes.
@DependencyClient
public struct LutronClient: Sendable {
    /// mDNS-discover Lutron bridges on the LAN (`_lutron._tcp`). May return several. LIVE-only.
    public var discoverBridges: @Sendable () async throws -> [DiscoveredLutronBridge]
    /// Run the LAP pairing handshake against the bridge at `bridgeIP` during the physical-button
    /// window. Generates an EC keypair + CSR, submits it over the 8083 TLS socket, and returns the
    /// bridge-signed client cert, our private key, and the bridge CA (all PEM). Throws
    /// `LutronError.buttonNotPressed` until the button is pressed. LIVE-only (a mock config never pairs).
    public var pair: @Sendable (_ bridgeIP: String) async throws -> LutronPairingResult

    /// Short reachability probe (opens the LEAP control socket, reads `/server/1/status/ping`). Never
    /// throws for a reachable bridge.
    public var testConnection: @Sendable (_ config: LutronConfig) async throws -> Bool
    /// List the household's shades (zone id, name, room/area, current level 0–100).
    public var shades: @Sendable (_ config: LutronConfig) async throws -> [LutronShade]

    // SEAM (P14): agent tools wrap these verbs — "close Oliver's shade" resolves to `setShadeLevel`
    // (level 0), "open the living room shades" to level 100. The verbs are reducer-independent (plain
    // client calls keyed off a `LutronConfig`) so the agent harness calls them exactly as the House UI
    // does. Callers MUST debounce slider spam (the House reducer does — see `HouseReducer`).

    /// Drive a shade zone to an absolute level 0–100 (0 = closed, 100 = open). LEAP `GoToLevel`.
    public var setShadeLevel: @Sendable (_ config: LutronConfig, _ zoneId: String, _ level: Int) async throws -> Void
    /// Begin raising a shade (LEAP `Raise`); pair with `stop`.
    public var raise: @Sendable (_ config: LutronConfig, _ zoneId: String) async throws -> Void
    /// Begin lowering a shade (LEAP `Lower`); pair with `stop`.
    public var lower: @Sendable (_ config: LutronConfig, _ zoneId: String) async throws -> Void
    /// Stop an in-progress raise/lower (LEAP `Stop`).
    public var stop: @Sendable (_ config: LutronConfig, _ zoneId: String) async throws -> Void
}

// MARK: - Live

extension LutronClient: DependencyKey {
    public static var liveValue: LutronClient {
        LutronClient(
            discoverBridges: { try await LutronDiscovery.discover() },
            pair: { bridgeIP in try await LutronPairingSession.pair(bridgeIP: bridgeIP) },
            testConnection: { config in
                if config.isMock { return true }
                return try await LutronLeapSession.ping(config)
            },
            shades: { config in
                // Mock reads flow through the STATEFUL store so raise/lower/slider writes persist for
                // the session and a re-read reflects a just-written level.
                config.isMock ? await LutronMockStore.shared.shades() : try await LutronLeapSession.shades(config)
            },
            setShadeLevel: { config, zoneId, level in
                if config.isMock {
                    await LutronMockStore.shared.setLevel(zoneId: zoneId, level: level)
                    return
                }
                try await LutronLeapSession.setLevel(config, zoneId: zoneId, level: level)
            },
            raise: { config, zoneId in
                if config.isMock { await LutronMockStore.shared.setLevel(zoneId: zoneId, level: LutronLevel.max); return }
                try await LutronLeapSession.command(config, .raise(zoneId: zoneId, tag: "raise"))
            },
            lower: { config, zoneId in
                if config.isMock { await LutronMockStore.shared.setLevel(zoneId: zoneId, level: LutronLevel.min); return }
                try await LutronLeapSession.command(config, .lower(zoneId: zoneId, tag: "lower"))
            },
            stop: { config, zoneId in
                if config.isMock { return }   // a mock stop is a no-op — the level already settled.
                try await LutronLeapSession.command(config, .stop(zoneId: zoneId, tag: "stop"))
            }
        )
    }

    public static let previewValue = LutronClient(
        discoverBridges: { [DiscoveredLutronBridge(id: "Caseta-000", ip: "192.168.1.50", name: "Caseta Smart Bridge")] },
        pair: { _ in LutronPairingResult(clientCertPEM: "preview-cert", clientKeyPEM: "preview-key", bridgeCAPEM: "preview-ca", bridgeId: "preview-bridge", bridgeName: "Caseta Smart Bridge") },
        testConnection: { _ in true },
        shades: { _ in LutronFixtures.shades },
        setShadeLevel: { _, _, _ in },
        raise: { _, _ in },
        lower: { _, _ in },
        stop: { _, _ in }
    )
}

public extension DependencyValues {
    var lutron: LutronClient {
        get { self[LutronClient.self] }
        set { self[LutronClient.self] = newValue }
    }
}

// MARK: - Fixtures (MOCK MODE)

/// The believable "Place house" shade fixtures served when a config's `mock == true`. Shared by the
/// live client's mock branch and `previewValue`.
public enum LutronFixtures {
    public static let shades: [LutronShade] = [
        LutronShade(zoneId: "5", name: "Oliver's room shade", areaName: "Oliver's room", level: 100),
        LutronShade(zoneId: "6", name: "Famfis's room shade", areaName: "Famfis's room", level: 100),
        LutronShade(zoneId: "8", name: "Living room shades", areaName: "Living room", level: 45),
    ]
}

// MARK: - Stateful mock store (MOCK MODE)

/// In-memory, per-session mutable shade levels for a mock config — the mock's single source of truth,
/// seeded lazily from `LutronFixtures`, mutated by `setLevel`. Mirrors `HueMockStore`: writes persist
/// for the process lifetime so the House surface's optimistic edits agree on re-read; a fresh launch
/// re-seeds.
actor LutronMockStore {
    static let shared = LutronMockStore()

    private var levels: [String: LutronShade] = [:]
    private var seeded = false

    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        for shade in LutronFixtures.shades { levels[shade.zoneId] = shade }
    }

    func shades() -> [LutronShade] {
        seedIfNeeded()
        return LutronFixtures.shades.compactMap { levels[$0.zoneId] }
    }

    func setLevel(zoneId: String, level: Int) {
        seedIfNeeded()
        guard var shade = levels[zoneId] else { return }
        shade.level = LutronLevel.clamp(level)
        levels[zoneId] = shade
    }

    /// Re-seed from fixtures — used by tests for order-independent isolation.
    func reset() {
        seeded = false
        levels.removeAll()
        seedIfNeeded()
    }
}
