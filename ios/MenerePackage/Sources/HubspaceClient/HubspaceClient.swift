import Dependencies
import DependenciesMacros
import FamilyDomain
import Foundation

/// Hubspace client for the household's Husky smart **water timer** / hose spigot (P15-C4) — the
/// **fifth** smart-home ecosystem and the fleet's **second cloud** integration, built to the same
/// playbook as `HueClient` (P12), `LutronClient` (P15-C1), `SonosClient` (P15-C2), and `NestClient`
/// (P15-C3): a tiny, purpose-built consumer keyed off a Firestore config doc, with a stateful MOCK mode
/// for spigot-less verification. Deliberately narrow: water timers only (a Hubspace account may also
/// hold bulbs/plugs/fans — those are OUT of scope and parsed away).
///
/// **Credential:** Hubspace has no official API. `login` runs the Keycloak email/password flow
/// (`HubspaceLogin`) and returns the long-lived **refresh token** + Afero **account id**, which the
/// Settings flow saves into `HubspaceConfig` (shared, so both parents' phones can open the spigot). The
/// **password is never persisted** — only the tokens. Every read/write trades the refresh token for a
/// short-lived access token, cached in-memory and refreshed on a 401 (see `HubspaceSession`).
@DependencyClient
public struct HubspaceClient: Sendable {
    /// Run the one-time Keycloak login (email + password) and return the long-lived refresh token +
    /// account id to persist. A mock config short-circuits to a canned credential (no network).
    public var login: @Sendable (_ email: String, _ password: String) async throws -> HubspaceTokens

    /// List the household's water-timer spigots (each with its outlets + battery). Auto-refreshes the
    /// access token as needed; single-flighted so an overlapping poll hits the API once.
    public var spigots: @Sendable (_ config: HubspaceConfig) async throws -> [HubspaceSpigot]

    // SEAM (P14): agent tools wrap `setSpigot` — "water the garden beds for 10 minutes" resolves to
    // `setSpigot(config, deviceId, "spigot-1", open: true, durationMinutes: 10)`. The verb is
    // reducer-independent (a plain client call keyed off a `HubspaceConfig`) so the agent harness calls
    // it exactly as the House UI does.
    //
    // DEFERRED (P9 yard-care tie-in): the "water the beds" care task marking done should ALSO open the
    // matching spigot. That composition lives naturally in the P14 agent phase (care-task completion →
    // agent tool → setSpigot), so it is intentionally NOT wired here — see ROADMAP P15 item 4.

    /// Open/close one outlet, optionally for a timed run (minutes). `durationMinutes == nil` = run until
    /// turned off. Timed runs write the `timer` functionClass alongside the `toggle` (see
    /// `HubspaceWrite`).
    public var setSpigot: @Sendable (_ config: HubspaceConfig, _ deviceId: String, _ instance: String, _ open: Bool, _ durationMinutes: Int?) async throws -> Void
}

// MARK: - Live

extension HubspaceClient: DependencyKey {
    public static var liveValue: HubspaceClient {
        HubspaceClient(
            login: { email, password in
                try await HubspaceLogin().login(email: email, password: password)
            },
            spigots: { config in
                // Mock reads flow through the STATEFUL store so toggle/duration writes persist for the
                // session and a re-read reflects a just-written value.
                if config.isMock { return await HubspaceMockStore.shared.spigots() }
                return try await HubspaceSession(config: config).spigots()
            },
            setSpigot: { config, deviceId, instance, open, durationMinutes in
                if config.isMock {
                    await HubspaceMockStore.shared.setSpigot(deviceId: deviceId, instance: instance, open: open, durationMinutes: durationMinutes)
                    return
                }
                try await HubspaceSession(config: config).setSpigot(
                    deviceId: deviceId, instance: instance, open: open, durationMinutes: durationMinutes
                )
            }
        )
    }

    /// A safe, no-network preview/test value: serves the fixture spigot, verbs are no-ops.
    public static let previewValue = HubspaceClient(
        login: { _, _ in HubspaceTokens(refreshToken: "preview-refresh", accountId: "preview-account") },
        spigots: { _ in [HubspaceFixtures.frontYard] },
        setSpigot: { _, _, _, _, _ in }
    )

    /// Test value degrades to "no spigots" so a reducer's discovery effect is a silent no-op unless a
    /// test injects a client explicitly.
    public static let testValue = HubspaceClient(
        login: { _, _ in HubspaceTokens(refreshToken: "", accountId: "") },
        spigots: { _ in [] },
        setSpigot: { _, _, _, _, _ in }
    )
}

public extension DependencyValues {
    var hubspace: HubspaceClient {
        get { self[HubspaceClient.self] }
        set { self[HubspaceClient.self] = newValue }
    }
}

// MARK: - Fixtures (MOCK MODE)

/// The believable "Place house" spigot fixture served when a config's `mock == true` (or in previews):
/// a single **Front yard spigot** with two outlets — **Garden beds** (closed) and **Drip line** (open,
/// 12 minutes remaining) — at 87% battery. Shared by the live client's mock branch, `previewValue`, and
/// the stateful `HubspaceMockStore` seed.
public enum HubspaceFixtures {
    public static let frontYardId = "mock-water-timer-01"

    public static let frontYard = HubspaceSpigot(
        id: frontYardId,
        name: "Front yard spigot",
        outlets: [
            SpigotOutlet(instance: "spigot-1", name: "Garden beds", isOpen: false, remainingMinutes: nil, maxOnMinutes: 20),
            SpigotOutlet(instance: "spigot-2", name: "Drip line", isOpen: true, remainingMinutes: 12, maxOnMinutes: 20),
        ],
        batteryPercent: 87
    )
}

// MARK: - Stateful mock store (MOCK MODE)

/// In-memory, per-session mutable spigot state for a mock config — the mock's single source of truth,
/// seeded lazily from `HubspaceFixtures`, mutated by `setSpigot`. Mirrors `NestMockStore` /
/// `SonosMockStore`: writes persist for the process lifetime so the House "Water" section's optimistic
/// edits agree on re-read; a fresh launch re-seeds.
actor HubspaceMockStore {
    static let shared = HubspaceMockStore()

    private var device: HubspaceSpigot?

    private func seedIfNeeded() {
        if device == nil { device = HubspaceFixtures.frontYard }
    }

    func spigots() -> [HubspaceSpigot] {
        seedIfNeeded()
        return device.map { [$0] } ?? []
    }

    func setSpigot(deviceId: String, instance: String, open: Bool, durationMinutes: Int?) {
        seedIfNeeded()
        guard let d = device, d.id == deviceId else { return }
        let outlets = d.outlets.map { outlet -> SpigotOutlet in
            guard outlet.instance == instance else { return outlet }
            return outlet.setting(open: open, remainingMinutes: durationMinutes)
        }
        device = HubspaceSpigot(id: d.id, name: d.name, outlets: outlets, batteryPercent: d.batteryPercent)
    }

    /// Re-seed from fixtures — used by tests for order-independent isolation.
    func reset() {
        device = HubspaceFixtures.frontYard
    }
}
