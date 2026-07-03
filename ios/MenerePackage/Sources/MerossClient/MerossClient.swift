import Dependencies
import DependenciesMacros
import FamilyDomain
import Foundation

/// Meross-LAN client for the household's **Refoss garage opener** (P15-C5) — the **sixth** smart-home
/// ecosystem and the final chunk of the P15 fleet, built to the same playbook as `HueClient` (P12),
/// `LutronClient` (P15-C1), `SonosClient` (P15-C2), `NestClient` (P15-C3), and `HubspaceClient` (P15-C4):
/// a tiny, purpose-built consumer keyed off a Firestore config doc, with a stateful MOCK mode for
/// door-less verification. Deliberately narrow: **garage doors only** (Meross also makes plugs, bulbs,
/// hubs — those are OUT of scope).
///
/// **Local, no cloud.** A Refoss opener is a rebadged Meross device; control is a signed JSON envelope
/// POSTed to `http://<device-ip>/config` on the home LAN (see `MerossTransport`). No account round-trip.
/// The credential is the device IP + the Meross/Refoss **device key** (signs every message); both live in
/// `MerossConfig`, shared so both parents' phones can open the garage.
///
/// **Ported concept, not code:** the envelope + `MD5(messageId + key + timestamp)` signing + the
/// GarageDoor.State GET/SET shapes are faithful to krahabb/meross_lan (and MerossIot's garage mixin) —
/// see `MerossTransport` / `MerossModels`.
@DependencyClient
public struct MerossClient: Sendable {
    /// Validate an IP + key by fetching `Appliance.System.All` → device identity + channels. Used by the
    /// Settings "Connect" step; a mock config isn't routed here (setup writes the mock doc directly).
    public var deviceInfo: @Sendable (_ ip: String, _ key: String) async throws -> MerossDeviceInfo

    /// Read the current door state(s) for the configured opener (`Appliance.GarageDoor.State` GET). A mock
    /// config serves the stateful fixture.
    public var garageState: @Sendable (_ config: MerossConfig) async throws -> [GarageDoor]

    // SEAM (P14): agent tools wrap `setGarage` — "open the garage" resolves to
    // `setGarage(config, channel: 0, open: true)`. The verb is reducer-independent (a plain client call
    // keyed off a `MerossConfig`) so the agent harness calls it exactly as the House UI does.
    //
    // IMPORTANT — the agent harness MUST gate OPEN behind an explicit confirmation, exactly as the House
    // UI does (the confirmation dialog). The garage is a security surface; closing is safe and needs no
    // confirmation, but opening it must never happen without an affirmative human/agent confirmation step.
    // (The reducer enforces this for the UI; the P14 tool wrapper must enforce it for the agent.)

    /// Open/close one channel (`Appliance.GarageDoor.State` SET). A mock config mutates the stateful store.
    public var setGarage: @Sendable (_ config: MerossConfig, _ channel: Int, _ open: Bool) async throws -> Void
}

// MARK: - Live

extension MerossClient: DependencyKey {
    public static var liveValue: MerossClient {
        MerossClient(
            deviceInfo: { ip, key in
                try await MerossSession().deviceInfo(ip: ip, key: key)
            },
            garageState: { config in
                // Mock reads flow through the STATEFUL store so a just-written open/close persists for the
                // session and the settling re-read reflects it.
                if config.isMock { return await MerossMockStore.shared.doors() }
                return try await MerossSession().garageState(config: config)
            },
            setGarage: { config, channel, open in
                if config.isMock {
                    await MerossMockStore.shared.setGarage(channel: channel, open: open)
                    return
                }
                try await MerossSession().setGarage(config: config, channel: channel, open: open)
            }
        )
    }

    /// A safe, no-network preview/test value: serves the fixture door, `setGarage` is a no-op.
    public static let previewValue = MerossClient(
        deviceInfo: { _, _ in MerossFixtures.deviceInfo },
        garageState: { _ in [MerossFixtures.garage] },
        setGarage: { _, _, _ in }
    )

    /// Test value degrades to "no doors" so a reducer's read effect is a silent no-op unless a test
    /// injects a client explicitly.
    public static let testValue = MerossClient(
        deviceInfo: { _, _ in MerossFixtures.deviceInfo },
        garageState: { _ in [] },
        setGarage: { _, _, _ in }
    )
}

public extension DependencyValues {
    var meross: MerossClient {
        get { self[MerossClient.self] }
        set { self[MerossClient.self] = newValue }
    }
}

// MARK: - Fixtures (MOCK MODE)

/// The believable "Place house" garage fixture served when a config's `mock == true` (or in previews): a
/// single-channel opener with one door — **"Garage"**, closed. Shared by the live client's mock branch,
/// `previewValue`, and the stateful `MerossMockStore` seed.
public enum MerossFixtures {
    public static let uuid = "mock-refoss-garage-uuid"

    public static let garage = GarageDoor(channel: 0, name: "Garage", isOpen: false)

    public static let deviceInfo = MerossDeviceInfo(
        uuid: uuid, type: "msg100", name: "Garage", channels: [garage]
    )

    /// The mock config that verification writes to `households/{hid}/config/meross`.
    public static let mockConfig = MerossConfig(
        deviceIP: "192.168.1.42", deviceKey: "mock-device-key", uuid: uuid, name: "Garage", mock: true
    )
}

// MARK: - Stateful mock store (MOCK MODE)

/// In-memory, per-session mutable door state for a mock config — the mock's single source of truth,
/// seeded lazily from `MerossFixtures`, mutated by `setGarage`. Mirrors `HubspaceMockStore` /
/// `SonosMockStore`: writes persist for the process lifetime so the House "Garage" section's optimistic
/// edit agrees on the settling re-read; a fresh launch re-seeds ("Garage" closed).
actor MerossMockStore {
    static let shared = MerossMockStore()

    private var doorsByChannel: [Int: GarageDoor]?

    private func seedIfNeeded() {
        if doorsByChannel == nil { doorsByChannel = [MerossFixtures.garage.channel: MerossFixtures.garage] }
    }

    func doors() -> [GarageDoor] {
        seedIfNeeded()
        return (doorsByChannel ?? [:]).values.sorted { $0.channel < $1.channel }
    }

    func setGarage(channel: Int, open: Bool) {
        seedIfNeeded()
        let existing = doorsByChannel?[channel] ?? GarageDoor(channel: channel, name: "Garage", isOpen: !open)
        doorsByChannel?[channel] = existing.setting(open: open)
    }

    /// Re-seed from fixtures — used by tests for order-independent isolation.
    func reset() {
        doorsByChannel = [MerossFixtures.garage.channel: MerossFixtures.garage]
    }
}
