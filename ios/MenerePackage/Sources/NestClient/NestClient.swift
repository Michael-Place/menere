import Dependencies
import DependenciesMacros
import FamilyDomain
import Foundation

/// SDM client for Nest thermostats (P15-C3) — the **fourth** smart-home ecosystem and the fleet's
/// **first cloud integration**, built to the same playbook as `HueClient` (P12), `LutronClient`
/// (P15-C1), and `SonosClient` (P15-C2): a tiny, purpose-built consumer keyed off a Firestore config
/// doc, with a stateful MOCK mode for thermostat-less verification. Deliberately narrow: thermostats
/// only (list + read + setpoint + mode) plus the one-time OAuth link. No cameras, no events, no
/// Pub/Sub (a later chunk).
///
/// **Credential:** unlike the LAN ecosystems, Nest is cloud + OAuth. `authorize` runs the
/// authorization-code flow (`ASWebAuthenticationSession` → token exchange) and returns the long-lived
/// **refresh token**, which the Settings flow saves into `NestConfig` (shared, so both parents' phones
/// control the thermostat). Every read/write trades that refresh token for a short-lived access token,
/// cached in-memory and refreshed on a 401 (see `NestSession`).
///
/// **Ported concept, not code:** the SDM REST shapes are faithful to Google's Device Access docs
/// (`.../api/thermostat`); see `NestTransport` / `NestOAuth` for the wire framing this consumes.
@DependencyClient
public struct NestClient: Sendable {
    /// Run the OAuth authorization-code flow (consent web sheet + token exchange) and return the
    /// long-lived **refresh token** to persist. LIVE-only presents `ASWebAuthenticationSession` anchored
    /// to the key window; a mock config short-circuits to a canned token (no UI).
    public var authorize: @Sendable (_ config: NestConfig) async throws -> String

    /// List the household's thermostats (room, ambient °F, humidity, mode, setpoints). Auto-refreshes
    /// the access token as needed.
    public var thermostats: @Sendable (_ config: NestConfig) async throws -> [NestThermostat]

    // SEAM (P14): agent tools wrap these verbs — "set the downstairs to 70" resolves to
    // `setTemperatureF` (a mode-appropriate `NestSetpoint`), "turn the heat off" to `setMode`. The verbs
    // are reducer-independent (plain client calls keyed off a `NestConfig`) so the agent harness calls
    // them exactly as the House UI does. Callers MUST debounce stepper spam (the House reducer does —
    // see `HouseReducer`, the same ≥300ms trailing debounce this chunk uses for thermostat steppers).

    /// Drive a thermostat to a mode-appropriate setpoint (°F). `SetHeat` / `SetCool` / `SetRange`.
    public var setTemperatureF: @Sendable (_ config: NestConfig, _ deviceName: String, _ setpoint: NestSetpoint) async throws -> Void
    /// Change a thermostat's mode (`SetMode`).
    public var setMode: @Sendable (_ config: NestConfig, _ deviceName: String, _ mode: NestMode) async throws -> Void
}

// MARK: - Live

extension NestClient: DependencyKey {
    public static var liveValue: NestClient {
        NestClient(
            authorize: { config in
                if config.isMock { return "mock-refresh-token" }
                #if canImport(AuthenticationServices) && canImport(UIKit)
                let pkce = NestPKCE()
                let coordinator = await NestAuthCoordinator()
                let code = try await coordinator.authorize(config: config, pkce: pkce)
                let (data, resp) = try await NestHTTPClient.live.perform(
                    NestOAuth.tokenExchangeRequest(config: config, code: code, codeVerifier: pkce.verifier)
                )
                guard (200..<300).contains(resp.statusCode) else { throw NestError.invalidTokenResponse }
                let tokens = try NestOAuth.parseTokens(data)
                guard let refresh = tokens.refreshToken, !refresh.isEmpty else { throw NestError.noRefreshToken }
                return refresh
                #else
                throw NestError.cannotPresent
                #endif
            },
            thermostats: { config in
                // Mock reads flow through the STATEFUL store so setpoint/mode writes persist for the
                // session and a re-read reflects a just-written value.
                if config.isMock { return await NestMockStore.shared.thermostats() }
                return try await NestSession(config: config).thermostats()
            },
            setTemperatureF: { config, deviceName, setpoint in
                if config.isMock {
                    await NestMockStore.shared.setTemperature(deviceName: deviceName, setpoint: setpoint)
                    return
                }
                try await NestSession(config: config).executeCommand(
                    deviceName: deviceName, body: NestCommand.setpointBody(setpoint)
                )
            },
            setMode: { config, deviceName, mode in
                if config.isMock {
                    await NestMockStore.shared.setMode(deviceName: deviceName, mode: mode)
                    return
                }
                try await NestSession(config: config).executeCommand(
                    deviceName: deviceName, body: NestCommand.modeBody(mode)
                )
            }
        )
    }

    /// A safe, no-network preview/test value: serves the fixture thermostat, verbs are no-ops.
    public static let previewValue = NestClient(
        authorize: { _ in "preview-refresh-token" },
        thermostats: { _ in [NestFixtures.downstairs] },
        setTemperatureF: { _, _, _ in },
        setMode: { _, _, _ in }
    )

    /// Test value degrades to "no thermostats" so a reducer's discovery effect is a silent no-op unless
    /// a test injects a Nest client explicitly.
    public static let testValue = NestClient(
        authorize: { _ in "" },
        thermostats: { _ in [] },
        setTemperatureF: { _, _, _ in },
        setMode: { _, _, _ in }
    )
}

public extension DependencyValues {
    var nest: NestClient {
        get { self[NestClient.self] }
        set { self[NestClient.self] = newValue }
    }
}

// MARK: - Fixtures (MOCK MODE)

/// The believable "Place house" thermostat fixture served when a config's `mock == true` (or in
/// previews): a single **Downstairs** thermostat — 22.0 °C (71.6 °F) ambient, 45 % humidity, **heat**
/// mode, 70 °F setpoint (21.11 °C). Shared by the live client's mock branch, `previewValue`, and the
/// stateful `NestMockStore` seed.
public enum NestFixtures {
    /// The full SDM resource name shape (`enterprises/{projectId}/devices/{id}`).
    public static let downstairsName = "enterprises/mock-project/devices/DOWNSTAIRS01"

    public static let downstairs = NestThermostat(
        id: downstairsName,
        roomName: "Downstairs",
        ambientCelsius: 22.0,                 // 71.6 °F
        humidityPercent: 45,
        mode: .heat,
        availableModes: [.heat, .cool, .heatCool, .off],
        heatCelsius: NestTemp.fToC(70),       // 70 °F
        coolCelsius: NestTemp.fToC(75),       // 75 °F (for a mode switch to cool/auto)
        hvacStatus: "HEATING"
    )
}

// MARK: - Stateful mock store (MOCK MODE)

/// In-memory, per-session mutable thermostat state for a mock config — the mock's single source of
/// truth, seeded lazily from `NestFixtures`, mutated by `setTemperature` / `setMode`. Mirrors
/// `LutronMockStore` / `SonosMockStore`: writes persist for the process lifetime so the House "Climate"
/// section's optimistic edits agree on re-read; a fresh launch re-seeds. Setpoints are stored in Celsius
/// (as SDM does), so a °F stepper edit round-trips through the same conversion the live path uses.
actor NestMockStore {
    static let shared = NestMockStore()

    private var device: NestThermostat?

    private func seedIfNeeded() {
        if device == nil { device = NestFixtures.downstairs }
    }

    func thermostats() -> [NestThermostat] {
        seedIfNeeded()
        return device.map { [$0] } ?? []
    }

    func setTemperature(deviceName: String, setpoint: NestSetpoint) {
        seedIfNeeded()
        guard let d = device, d.id == deviceName else { return }
        switch setpoint {
        case let .heat(f):
            device = d.with(heatCelsius: NestTemp.fToC(Double(f)))
        case let .cool(f):
            device = d.with(coolCelsius: NestTemp.fToC(Double(f)))
        case let .range(heat, cool):
            device = d.with(heatCelsius: NestTemp.fToC(Double(heat)), coolCelsius: NestTemp.fToC(Double(cool)))
        }
    }

    func setMode(deviceName: String, mode: NestMode) {
        seedIfNeeded()
        guard let d = device, d.id == deviceName else { return }
        device = d.with(mode: mode)
    }

    /// Re-seed from fixtures — used by tests for order-independent isolation.
    func reset() {
        device = NestFixtures.downstairs
    }
}
