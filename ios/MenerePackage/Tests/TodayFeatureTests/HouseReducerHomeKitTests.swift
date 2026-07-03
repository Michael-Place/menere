import ComposableArchitecture
import FamilyDomain
import HomeKitClient
import HueClient
import MerossClient
import Testing

@testable import TodayFeature

/// Locks the P15-C7 HomeKit verbs on `HouseReducer`: the **garage source precedence** (a HomeKit garage
/// takes over the section from the Meross fallback; absent → Meross stays), the **lock UNLOCK confirmation
/// gate** (unlock routes through `confirmingHomeKitUnlock`, lock commits directly — mirroring garage
/// open/close), the optimistic plug toggle, and mock statefulness end-to-end through the reducer.
@MainActor
struct HouseReducerHomeKitTests {
    private actor CharRecorder {
        private(set) var calls: [(String, HKServiceType, HKCharacteristicType, HKCharacteristicValue)] = []
        func record(_ a: String, _ s: HKServiceType, _ c: HKCharacteristicType, _ v: HKCharacteristicValue) {
            calls.append((a, s, c, v))
        }
        var count: Int { calls.count }
        var last: (String, HKServiceType, HKCharacteristicType, HKCharacteristicValue)? { calls.last }
    }

    private let bridge = HueBridgeConfig(bridgeId: "B", bridgeIP: "10.0.0.1", applicationKey: "k")

    private func baseState() -> HouseReducer.State {
        HouseReducer.State(config: HueConfig(bridges: [bridge]), bridges: [])
    }

    private func hkGarage(open: Bool) -> HKAccessory {
        HKAccessory(id: "hk-garage", name: "Garage Door", room: "Garage",
                    category: HKAccessoryCategory("garageDoorOpener"),
                    services: [HKService(id: "s", type: .garageDoorOpener, name: "Garage Door", characteristics: [
                        HKCharacteristicSnapshot(id: "cur", type: .currentDoorState, value: .int(open ? 0 : 1), isWritable: false),
                        HKCharacteristicSnapshot(id: "tgt", type: .targetDoorState, value: .int(open ? 0 : 1), isWritable: true),
                    ])], isReachable: true)
    }

    private func hkLock(locked: Bool) -> HKAccessory {
        HKAccessory(id: "hk-lock", name: "Front Door", room: "Entry",
                    category: HKAccessoryCategory("doorLock"),
                    services: [HKService(id: "s", type: .lockMechanism, name: "Front Door", characteristics: [
                        HKCharacteristicSnapshot(id: "cur", type: .currentLockState, value: .int(locked ? 1 : 0), isWritable: false),
                        HKCharacteristicSnapshot(id: "tgt", type: .targetLockState, value: .int(locked ? 1 : 0), isWritable: true),
                    ])], isReachable: true)
    }

    private func hkPlug(on: Bool) -> HKAccessory {
        HKAccessory(id: "hk-plug", name: "Lamp", room: "Den",
                    category: HKAccessoryCategory("outlet"),
                    services: [HKService(id: "s", type: .outlet, name: "Lamp", characteristics: [
                        HKCharacteristicSnapshot(id: "p", type: .powerState, value: .bool(on), isWritable: true),
                    ])], isReachable: true)
    }

    // MARK: garage source precedence

    /// A HomeKit garage takes over the Garage section: `garageSource` flips to `.homeKit`, the door rows
    /// derive from HomeKit, and the channel→accessory map is populated (so writes target it).
    @Test func homekitGaragePowersTheSectionWhenPresent() async {
        let inventory = HKInventory(homeName: "Place House", accessories: [hkGarage(open: false)])
        var client = HomeKitClient.testValue
        client.inventory = { _ in inventory }

        var state = baseState()
        state.homekitConfig = HomeKitConfig(mock: true)   // mock → auth treated authorized, no live prompt

        let store = TestStore(initialState: state) { HouseReducer() } withDependencies: {
            $0.homekit = client
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off

        await store.send(.homekitLoad)
        await store.receive(\.homekitAuthLoaded)
        await store.receive(\.homekitInventoryLoaded)

        #expect(store.state.garageSource == .homeKit)
        #expect(store.state.garageDoors.count == 1)
        #expect(store.state.garageDoors[0].isOpen == false)
        #expect(store.state.garageHomeKitAccessoryIds[0] == "hk-garage")
        await store.finish()
    }

    /// With NO HomeKit garage, the source stays `.meross` and a Meross re-read still drives the section.
    @Test func merossRemainsTheFallbackWhenNoHomekitGarage() async {
        let inventory = HKInventory(homeName: "Place House", accessories: [hkPlug(on: false)])
        var client = HomeKitClient.testValue
        client.inventory = { _ in inventory }

        var state = baseState()
        state.homekitConfig = HomeKitConfig(mock: true)
        state.merossConfig = MerossConfig(deviceIP: "10.0.0.9", deviceKey: "K", uuid: "U", name: "Garage", mock: true)

        let store = TestStore(initialState: state) { HouseReducer() } withDependencies: {
            $0.homekit = client
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off

        await store.send(.homekitLoad)
        await store.receive(\.homekitInventoryLoaded)
        #expect(store.state.garageSource == .meross)   // unchanged — HomeKit had no garage

        // A Meross re-read still lands (source is Meross).
        await store.send(.garageReloaded([GarageDoor(channel: 0, name: "Garage", isOpen: false)]))
        #expect(store.state.garageDoors.count == 1)
        await store.finish()
    }

    /// Once HomeKit owns the section, a stray Meross re-read is IGNORED (the two sources never fight).
    @Test func merossReloadIsIgnoredWhenHomekitOwnsGarage() async {
        var state = baseState()
        state.garageSource = .homeKit
        state.garageDoors = [GarageDoor(channel: 0, name: "Garage Door", isOpen: true)]

        let store = TestStore(initialState: state) { HouseReducer() } withDependencies: {
            $0.homekit = .testValue
            $0.continuousClock = TestClock()
        }
        await store.send(.garageReloaded([GarageDoor(channel: 0, name: "Garage", isOpen: false)]))
        #expect(store.state.garageDoors[0].isOpen == true)   // untouched by the Meross reload
        await store.finish()
    }

    // MARK: lock UNLOCK confirmation gate

    @Test func unlockRequiresConfirmationThenCommits() async {
        let recorder = CharRecorder()
        var client = HomeKitClient.testValue
        client.setCharacteristic = { _, a, s, c, v in await recorder.record(a, s, c, v) }

        var state = baseState()
        state.homekitConfig = HomeKitConfig(mock: true)
        state.homekitInventory = HKInventory(accessories: [hkLock(locked: true)])

        let store = TestStore(initialState: state) { HouseReducer() } withDependencies: {
            $0.homekit = client
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off

        // Tap "Unlock" → only arms the dialog; NO write yet.
        await store.send(.homekitUnlockRequested(accessoryId: "hk-lock"))
        #expect(store.state.confirmingHomeKitUnlock == "hk-lock")
        #expect(await recorder.count == 0)

        // Confirm → commits, targeting lock state 0 (unsecured).
        await store.send(.confirmHomeKitUnlock)
        #expect(store.state.confirmingHomeKitUnlock == nil)
        await store.receive(\.commitHomeKitLock)
        await store.finish()
        #expect(await recorder.count == 1)
        let last = await recorder.last!
        #expect(last.0 == "hk-lock")
        #expect(last.1 == .lockMechanism)
        #expect(last.2 == .targetLockState)
        #expect(last.3 == .int(0))
    }

    @Test func cancelUnlockDoesNothing() async {
        let recorder = CharRecorder()
        var client = HomeKitClient.testValue
        client.setCharacteristic = { _, a, s, c, v in await recorder.record(a, s, c, v) }

        var state = baseState()
        state.homekitInventory = HKInventory(accessories: [hkLock(locked: true)])

        let store = TestStore(initialState: state) { HouseReducer() } withDependencies: {
            $0.homekit = client
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off

        await store.send(.homekitUnlockRequested(accessoryId: "hk-lock"))
        await store.send(.cancelHomeKitUnlock)
        #expect(store.state.confirmingHomeKitUnlock == nil)
        await store.finish()
        #expect(await recorder.count == 0)
    }

    /// LOCKING (securing) is safe — it commits directly, no confirmation ever armed.
    @Test func lockCommitsDirectlyWithoutConfirmation() async {
        let recorder = CharRecorder()
        var client = HomeKitClient.testValue
        client.setCharacteristic = { _, a, s, c, v in await recorder.record(a, s, c, v) }

        var state = baseState()
        state.homekitInventory = HKInventory(accessories: [hkLock(locked: false)])

        let store = TestStore(initialState: state) { HouseReducer() } withDependencies: {
            $0.homekit = client
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off

        await store.send(.homekitLockRequested(accessoryId: "hk-lock"))
        #expect(store.state.confirmingHomeKitUnlock == nil)   // NEVER armed for a lock
        await store.receive(\.commitHomeKitLock)
        await store.finish()
        #expect(await recorder.last?.3 == .int(1))   // secured
    }

    // MARK: plug toggle (optimistic)

    @Test func plugToggleFlipsOptimisticallyAndWritesOnce() async {
        let recorder = CharRecorder()
        var client = HomeKitClient.testValue
        client.setCharacteristic = { _, a, s, c, v in await recorder.record(a, s, c, v) }

        var state = baseState()
        state.homekitInventory = HKInventory(accessories: [hkPlug(on: false)])

        let store = TestStore(initialState: state) { HouseReducer() } withDependencies: {
            $0.homekit = client
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off

        await store.send(.homekitToggleOutlet(accessoryId: "hk-plug"))
        // Optimistic: the plug reads "on" immediately.
        #expect(store.state.homekitInventory?.accessories.first?.powerIsOn == true)
        await store.finish()
        #expect(await recorder.count == 1)
        #expect(await recorder.last?.2 == .powerState)
        #expect(await recorder.last?.3 == .bool(true))
    }

    // MARK: statefulness end-to-end through the reducer (HomeKit-sourced garage open + settle re-read)

    /// A tiny stateful client (local actor) proves the full HomeKit garage loop: the write mutates
    /// backing state, and the settle poll re-reads the whole inventory so the door reflects OPEN — the
    /// same statefulness the shipped mock store gives, exercised through the reducer.
    private actor GarageStore {
        private var open = false
        func set(open: Bool) { self.open = open }
        func isOpen() -> Bool { open }
    }

    @Test func homekitGarageOpensAndSettleReReadReflectsIt() async {
        let backing = GarageStore()
        let clock = TestClock()
        var client = HomeKitClient.testValue
        client.inventory = { _ in HKInventory(homeName: "Place House", accessories: [
            HKAccessory(id: "hk-garage", name: "Garage Door", room: "Garage",
                        category: HKAccessoryCategory("garageDoorOpener"),
                        services: [HKService(id: "s", type: .garageDoorOpener, name: "Garage Door", characteristics: [
                            HKCharacteristicSnapshot(id: "cur", type: .currentDoorState, value: .int(await backing.isOpen() ? 0 : 1), isWritable: false),
                            HKCharacteristicSnapshot(id: "tgt", type: .targetDoorState, value: .int(await backing.isOpen() ? 0 : 1), isWritable: true),
                        ])], isReachable: true),
        ]) }
        client.setCharacteristic = { _, _, _, ctype, value in
            if ctype == .targetDoorState, let i = value.intValue { await backing.set(open: i == 0) }
        }

        var state = baseState()
        state.homekitConfig = HomeKitConfig(mock: true)

        let store = TestStore(initialState: state) { HouseReducer() } withDependencies: {
            $0.homekit = client
            $0.continuousClock = clock
        }
        store.exhaustivity = .off

        // Load → HomeKit garage (closed) powers the section.
        await store.send(.homekitLoad)
        await store.receive(\.homekitInventoryLoaded)
        #expect(store.state.garageSource == .homeKit)
        #expect(store.state.garageDoors.first?.isOpen == false)

        // Confirm-gated open → HomeKit write mutates backing state; settle re-read reflects OPEN.
        await store.send(.garageOpenRequested(channel: 0))
        await store.send(.confirmGarageOpen)
        await store.receive(\.commitGarage)
        #expect(store.state.garageSettling[0] == .opening)

        await clock.advance(by: .seconds(20))
        await store.receive(\.garageSettleElapsed)
        await store.receive(\.garagePoll)
        await store.receive(\.homekitLoad)
        await store.receive(\.homekitInventoryLoaded)
        #expect(store.state.garageDoors.first?.isOpen == true)   // persisted the open
        #expect(store.state.garageSettling[0] == nil)

        await store.finish()
    }
}
