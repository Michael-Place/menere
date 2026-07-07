import Dependencies
import DependenciesMacros
import FamilyDomain
import Foundation

#if canImport(HomeKit)
import HomeKit
#endif

/// A first-class **Apple HomeKit** bridge (P15-C7) — the fleet's **seventh** ecosystem, built to the same
/// playbook as `HueClient`/`LutronClient`/`SonosClient`/`NestClient`/`HubspaceClient`/`MerossClient`, but
/// this one wraps a **system framework** (`HMHomeManager`) instead of a network protocol. Local, keyless,
/// no cloud round-trip: the app reads and controls whatever accessories the Home app has paired.
///
/// **Why this exists (Michael's garage).** The Refoss opener turned out to be HomeKit-paired and never
/// cloud-registered (so the Meross LAN key path is locked). HomeKit reaches it directly — AND every other
/// accessory in the Home — so this chunk both powers the garage AND builds the inventory that reveals the
/// rest of the fleet ("Path B — see what superpowers we pick up").
///
/// **Snapshot, not live objects.** `inventory` returns Sendable value types (`HKInventory` → `HKAccessory`
/// → `HKService` → `HKCharacteristicSnapshot`), never the main-actor-bound `HM*` references, so the House
/// reducer holds them in TCA state safely. This chunk ships **snapshot + refresh** (the House screen's
/// `.task`/`.refresh`/settle-poll re-reads); a delegate-driven `changes()` stream is deferred (see the
/// coordinator note) — a `HMHomeManagerDelegate`/`HMAccessoryDelegate` bridge is nice-to-have, not needed.
///
/// **MOCK mode** (`households/{hid}/config/homekit { mock: true }`) serves a stateful fixture Home (a
/// garage door, a front-door lock, two temperature sensors, a smart plug) so the UI verifies without real
/// accessories — the simulator's simulated Home is empty.
@DependencyClient
public struct HomeKitClient: Sendable {
    /// The app's HomeKit authorization. **Creating `HMHomeManager` for the first time triggers the system
    /// permission prompt** — so the first call to this (from Settings "Connect to HomeKit" OR the House
    /// screen's load, whichever the user opens first) is what surfaces the prompt. Idempotent thereafter.
    public var authorizationStatus: @Sendable () async -> HKAuthStatus = { .notDetermined }

    /// A snapshot of the (primary) Home's accessories. Empty until authorized. A mock config serves the
    /// stateful fixture Home.
    public var inventory: @Sendable (_ config: HomeKitConfig?) async -> HKInventory = { _ in HKInventory() }

    // SEAM (P14): agent tools wrap `setCharacteristic` — "open the garage" → `setCharacteristic(accId,
    // .garageDoorOpener, .targetDoorState, .int(0))`; "unlock the front door" → `(.lockMechanism,
    // .targetLockState, .int(0))`; "turn on the lamp" → `(.outlet, .powerState, .bool(true))`.
    //
    // IMPORTANT — the agent harness MUST confirmation-gate the two security writes exactly as the House UI
    // does: **garage OPEN** (targetDoorState == 0) AND **lock UNLOCK** (targetLockState == 0). Closing a
    // garage and locking a door are safe and need no confirmation; opening/unlocking must never happen
    // without an affirmative human/agent confirmation step. (The reducer enforces this for the UI; the P14
    // tool wrapper must enforce it for the agent.)
    /// Write one characteristic — typed enough for garage target door state, lock target state, power, and
    /// brightness. A mock config mutates the stateful store.
    public var setCharacteristic: @Sendable (
        _ config: HomeKitConfig?, _ accessoryId: String, _ serviceType: HKServiceType,
        _ characteristicType: HKCharacteristicType, _ value: HKCharacteristicValue
    ) async throws -> Void
}

/// Errors from the live HomeKit writes. The House sections degrade silently (a failed write re-reads truth).
public enum HomeKitError: Error, Equatable, Sendable {
    case accessoryNotFound
    case serviceNotFound
    case characteristicNotFound
}

// MARK: - Live

extension HomeKitClient: DependencyKey {
    public static var liveValue: HomeKitClient {
        HomeKitClient(
            authorizationStatus: {
                #if canImport(HomeKit)
                return await HomeKitCoordinator.shared.authorizationStatus()
                #else
                return .restricted
                #endif
            },
            inventory: { config in
                if config?.isMock == true { return await HomeKitMockStore.shared.inventory() }
                #if canImport(HomeKit)
                return await HomeKitCoordinator.shared.inventory()
                #else
                return HKInventory()
                #endif
            },
            setCharacteristic: { config, accessoryId, serviceType, characteristicType, value in
                if config?.isMock == true {
                    await HomeKitMockStore.shared.set(
                        accessoryId: accessoryId, serviceType: serviceType,
                        characteristicType: characteristicType, value: value
                    )
                    return
                }
                #if canImport(HomeKit)
                try await HomeKitCoordinator.shared.setCharacteristic(
                    accessoryId: accessoryId, serviceType: serviceType,
                    characteristicType: characteristicType, value: value
                )
                #endif
            }
        )
    }

    /// A safe, no-network preview value: serves the stateful mock Home, `setCharacteristic` mutates it.
    public static let previewValue = HomeKitClient(
        authorizationStatus: { .authorized },
        inventory: { _ in await HomeKitMockStore.shared.inventory() },
        setCharacteristic: { _, accessoryId, serviceType, characteristicType, value in
            await HomeKitMockStore.shared.set(
                accessoryId: accessoryId, serviceType: serviceType,
                characteristicType: characteristicType, value: value
            )
        }
    )

    /// Test value degrades to "not determined / empty Home" so a reducer's load is a silent no-op unless a
    /// test injects a client explicitly.
    public static let testValue = HomeKitClient(
        authorizationStatus: { .notDetermined },
        inventory: { _ in HKInventory() },
        setCharacteristic: { _, _, _, _, _ in }
    )
}

public extension DependencyValues {
    var homekit: HomeKitClient {
        get { self[HomeKitClient.self] }
        set { self[HomeKitClient.self] = newValue }
    }
}

// MARK: - Fixtures (MOCK MODE)

/// The believable "Place House" fixture Home served when a config's `mock == true` (or in previews):
/// a garage door (closed), a front-door lock (locked), two temperature sensors, and a smart plug (off).
/// Shared by the mock store and previews. Stable accessory ids so reducer/tests can target them.
public enum HomeKitFixtures {
    public static let homeName = "Place House"

    public static let garageId = "mock-garage"
    public static let lockId = "mock-frontdoor-lock"
    public static let plugId = "mock-plug-lamp"
    public static let tempLivingId = "mock-temp-living"
    public static let tempBedroomId = "mock-temp-bedroom"

    /// Build the fixture Home from the mutable bits (garage open?, door locked?, plug on?). The sensors are
    /// fixed readings.
    static func inventory(garageOpen: Bool, locked: Bool, plugOn: Bool) -> HKInventory {
        HKInventory(homeName: homeName, accessories: [
            garageAccessory(open: garageOpen),
            lockAccessory(locked: locked),
            plugAccessory(on: plugOn),
            tempAccessory(id: tempLivingId, name: "Living Room", room: "Living Room", celsius: 21.5),
            tempAccessory(id: tempBedroomId, name: "Bedroom", room: "Bedroom", celsius: 20.0),
        ])
    }

    private static func garageAccessory(open: Bool) -> HKAccessory {
        HKAccessory(
            id: garageId, name: "Garage Door", room: "Garage",
            category: HKAccessoryCategory("garageDoorOpener"),
            services: [HKService(
                id: "\(garageId)-svc", type: .garageDoorOpener, name: "Garage Door",
                characteristics: [
                    HKCharacteristicSnapshot(id: "\(garageId)-cur", type: .currentDoorState, value: .int(open ? 0 : 1), isWritable: false),
                    HKCharacteristicSnapshot(id: "\(garageId)-tgt", type: .targetDoorState, value: .int(open ? 0 : 1), isWritable: true),
                ]
            )],
            isReachable: true
        )
    }

    private static func lockAccessory(locked: Bool) -> HKAccessory {
        HKAccessory(
            id: lockId, name: "Front Door", room: "Entry",
            category: HKAccessoryCategory("doorLock"),
            services: [HKService(
                id: "\(lockId)-svc", type: .lockMechanism, name: "Front Door",
                characteristics: [
                    HKCharacteristicSnapshot(id: "\(lockId)-cur", type: .currentLockState, value: .int(locked ? 1 : 0), isWritable: false),
                    HKCharacteristicSnapshot(id: "\(lockId)-tgt", type: .targetLockState, value: .int(locked ? 1 : 0), isWritable: true),
                ]
            )],
            isReachable: true
        )
    }

    private static func plugAccessory(on: Bool) -> HKAccessory {
        HKAccessory(
            id: plugId, name: "Lamp Plug", room: "Living Room",
            category: HKAccessoryCategory("outlet"),
            services: [HKService(
                id: "\(plugId)-svc", type: .outlet, name: "Lamp Plug",
                characteristics: [
                    HKCharacteristicSnapshot(id: "\(plugId)-pwr", type: .powerState, value: .bool(on), isWritable: true),
                ]
            )],
            isReachable: true
        )
    }

    private static func tempAccessory(id: String, name: String, room: String, celsius: Double) -> HKAccessory {
        HKAccessory(
            id: id, name: name, room: room,
            category: HKAccessoryCategory("sensor"),
            services: [HKService(
                id: "\(id)-svc", type: .temperatureSensor, name: name,
                characteristics: [
                    HKCharacteristicSnapshot(id: "\(id)-temp", type: .currentTemperature, value: .double(celsius), isWritable: false),
                ]
            )],
            isReachable: true
        )
    }
}

// MARK: - Stateful mock store (MOCK MODE)

/// In-memory, per-session mutable Home state for a mock config — mirrors `MerossMockStore` /
/// `HubspaceMockStore`: writes persist for the process lifetime so the House sections' optimistic edits
/// agree on the settle/refresh re-read; a fresh launch re-seeds (garage closed, door locked, plug off).
actor HomeKitMockStore {
    static let shared = HomeKitMockStore()

    private var garageOpen = false
    private var locked = true
    private var plugOn = false

    func inventory() -> HKInventory {
        HomeKitFixtures.inventory(garageOpen: garageOpen, locked: locked, plugOn: plugOn)
    }

    func set(accessoryId: String, serviceType: HKServiceType, characteristicType: HKCharacteristicType, value: HKCharacteristicValue) {
        switch characteristicType {
        case .targetDoorState:
            if let i = value.intValue { garageOpen = (i == 0) }   // 0 open · 1 closed
        case .targetLockState:
            if let i = value.intValue { locked = (i == 1) }        // 1 secured · 0 unsecured
        case .powerState:
            if let b = value.boolValue { plugOn = b }
        default:
            break
        }
    }

    /// Re-seed to the launch defaults — used by tests for order-independent isolation.
    func reset() {
        garageOpen = false
        locked = true
        plugOn = false
    }
}

// MARK: - Live coordinator (HMHomeManager, main-actor)

#if canImport(HomeKit)

/// The main-actor coordinator around a single shared `HMHomeManager`. HomeKit is main-thread-ish and its
/// objects aren't Sendable, so all HM access happens here on the main actor and only Sendable value-type
/// snapshots escape. The `@Sendable` dependency closures hop in via `await`.
///
/// **Live-changes decision:** this chunk ships snapshot + refresh (the House screen re-reads on task /
/// refresh / the garage settle-poll). A `HMHomeManagerDelegate` (homes/authorization updates) and
/// `HMAccessoryDelegate` (per-characteristic pushes) could feed a `changes()` `AsyncStream`, but that's a
/// nice-to-have; the delegate here is used only to unblock the authorization/homes-loaded waits.
@MainActor
final class HomeKitCoordinator: NSObject {
    static let shared = HomeKitCoordinator()

    private var manager: HMHomeManager?
    private var homesLoaded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func ensureManager() -> HMHomeManager {
        if let manager { return manager }
        // First creation triggers the system permission prompt.
        let m = HMHomeManager()
        m.delegate = self
        manager = m
        return m
    }

    func authorizationStatus() async -> HKAuthStatus {
        let m = ensureManager()
        if !m.authorizationStatus.contains(.determined) {
            await waitForUpdate(timeout: .seconds(12))
        }
        return Self.map(m.authorizationStatus)
    }

    func inventory() async -> HKInventory {
        let m = ensureManager()
        if !homesLoaded { await waitForUpdate(timeout: .seconds(8)) }
        guard m.authorizationStatus.contains(.authorized) else { return HKInventory() }
        let home = m.primaryHome ?? m.homes.first
        let accessories = (home?.accessories ?? []).map { HMAccessoryAdapter(accessory: $0) as any HKAccessorySource }
        return HomeKitSnapshot.inventory(homeName: home?.name, accessories: accessories)
    }

    func setCharacteristic(accessoryId: String, serviceType: HKServiceType, characteristicType: HKCharacteristicType, value: HKCharacteristicValue) async throws {
        let m = ensureManager()
        let home = m.primaryHome ?? m.homes.first
        guard let accessory = home?.accessories.first(where: { $0.uniqueIdentifier.uuidString == accessoryId })
        else { throw HomeKitError.accessoryNotFound }
        guard let service = accessory.services.first(where: { hkServiceType($0.serviceType) == serviceType })
        else { throw HomeKitError.serviceNotFound }
        guard let characteristic = service.characteristics.first(where: { hkCharacteristicType($0.characteristicType) == characteristicType })
        else { throw HomeKitError.characteristicNotFound }
        try await characteristic.writeValue(homeKitValue(value))
    }

    // MARK: waits

    private func waitForUpdate(timeout: Duration) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeWaiters()
            }
        }
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        for c in pending { c.resume() }
    }

    static func map(_ s: HMHomeManagerAuthorizationStatus) -> HKAuthStatus {
        guard s.contains(.determined) else { return .notDetermined }
        if s.contains(.authorized) { return .authorized }
        if s.contains(.restricted) { return .restricted }
        return .denied
    }
}

extension HomeKitCoordinator: @preconcurrency HMHomeManagerDelegate {
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        homesLoaded = true
        resumeWaiters()
    }

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        resumeWaiters()
    }
}

// MARK: - HM → HK classification + adapters

func hkServiceType(_ raw: String) -> HKServiceType {
    switch raw {
    case HMServiceTypeGarageDoorOpener: return .garageDoorOpener
    case HMServiceTypeLockMechanism: return .lockMechanism
    case HMServiceTypeOutlet: return .outlet
    case HMServiceTypeSwitch: return .switch
    case HMServiceTypeLightbulb: return .lightbulb
    case HMServiceTypeThermostat: return .thermostat
    case HMServiceTypeTemperatureSensor: return .temperatureSensor
    case HMServiceTypeHumiditySensor: return .humiditySensor
    case HMServiceTypeContactSensor: return .contactSensor
    default: return .other(raw)
    }
}

func hkCharacteristicType(_ raw: String) -> HKCharacteristicType {
    switch raw {
    case HMCharacteristicTypeCurrentDoorState: return .currentDoorState
    case HMCharacteristicTypeTargetDoorState: return .targetDoorState
    case HMCharacteristicTypeCurrentLockMechanismState: return .currentLockState
    case HMCharacteristicTypeTargetLockMechanismState: return .targetLockState
    case HMCharacteristicTypePowerState: return .powerState
    case HMCharacteristicTypeBrightness: return .brightness
    case HMCharacteristicTypeCurrentTemperature: return .currentTemperature
    case HMCharacteristicTypeContactState: return .contactState
    case HMCharacteristicTypeCurrentRelativeHumidity: return .currentHumidity
    default: return .other(raw)
    }
}

/// Convert a Sendable value into the `Any` HomeKit expects for a write.
private func homeKitValue(_ value: HKCharacteristicValue) -> Any {
    switch value {
    case let .bool(b): return b
    case let .int(i): return i
    case let .double(d): return d
    case let .string(s): return s
    }
}

private struct HMCharacteristicAdapter: HKCharacteristicSource {
    let characteristic: HMCharacteristic
    var idRaw: String { characteristic.uniqueIdentifier.uuidString }
    var type: HKCharacteristicType { hkCharacteristicType(characteristic.characteristicType) }
    var value: HKCharacteristicValue? { HKCharacteristicValue(homeKit: characteristic.value) }
    var isWritable: Bool { characteristic.properties.contains(HMCharacteristicPropertyWritable) }
}

private struct HMServiceAdapter: HKServiceSource {
    let service: HMService
    var idRaw: String { service.uniqueIdentifier.uuidString }
    var type: HKServiceType { hkServiceType(service.serviceType) }
    var nameRaw: String? { service.name }
    var characteristicSources: [any HKCharacteristicSource] {
        service.characteristics.map { HMCharacteristicAdapter(characteristic: $0) }
    }
}

private struct HMAccessoryAdapter: HKAccessorySource {
    let accessory: HMAccessory
    var idRaw: String { accessory.uniqueIdentifier.uuidString }
    var nameRaw: String { accessory.name }
    var roomRaw: String? { accessory.room?.name }
    var categoryRaw: String { accessory.category.categoryType }
    var serviceSources: [any HKServiceSource] { accessory.services.map { HMServiceAdapter(service: $0) } }
    var isReachableRaw: Bool { accessory.isReachable }
}

#endif
