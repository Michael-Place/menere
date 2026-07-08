import HomeKitClient
import HubspaceClient
import Testing

@testable import HouseFeature

/// Locks the W2a latent-capability surfacing that lives in pure HouseFeature reads: the HomeKit
/// jam/stopped display states (which `lockIsLocked` / the Bool `isOpen` used to collapse away) and the
/// Hubspace duration ceiling bounded by the device's `max-on-time`.
struct HouseReducerW2aTests {
    // MARK: HomeKit lock display state (currentLockState)

    private func lock(_ raw: Int) -> HKAccessory {
        HKAccessory(id: "lock", name: "Front Door", room: "Entry",
                    category: HKAccessoryCategory("doorLock"),
                    services: [HKService(id: "s", type: .lockMechanism, name: "Front Door", characteristics: [
                        HKCharacteristicSnapshot(id: "c", type: .currentLockState, value: .int(raw), isWritable: false),
                    ])], isReachable: true)
    }

    @Test func lockStateSecuredIsLocked() { #expect(lock(1).lockDisplayState == .locked) }
    @Test func lockStateUnsecuredIsUnlocked() { #expect(lock(0).lockDisplayState == .unlocked) }
    @Test func lockStateJammedIsJammed() { #expect(lock(2).lockDisplayState == .jammed) }
    @Test func lockStateUnknownIsJammed() { #expect(lock(3).lockDisplayState == .jammed) }

    @Test func lockWithNoServiceIsNil() {
        let bare = HKAccessory(id: "x", name: "X", room: nil, category: HKAccessoryCategory("outlet"),
                               services: [], isReachable: true)
        #expect(bare.lockDisplayState == nil)
    }

    // MARK: HomeKit garage display state (currentDoorState)

    private func garage(_ raw: Int) -> HKAccessory {
        HKAccessory(id: "g", name: "Garage Door", room: "Garage",
                    category: HKAccessoryCategory("garageDoorOpener"),
                    services: [HKService(id: "s", type: .garageDoorOpener, name: "Garage Door", characteristics: [
                        HKCharacteristicSnapshot(id: "c", type: .currentDoorState, value: .int(raw), isWritable: false),
                    ])], isReachable: true)
    }

    @Test func garageStatesMapAcrossTheFullRange() {
        #expect(garage(0).garageDoorDisplayState == .open)
        #expect(garage(1).garageDoorDisplayState == .closed)
        #expect(garage(2).garageDoorDisplayState == .opening)
        #expect(garage(3).garageDoorDisplayState == .closing)
        #expect(garage(4).garageDoorDisplayState == .stopped)
    }

    // MARK: Hubspace duration ceiling (max-on-time)

    @Test func durationOptionsDefaultWhenNoCap() {
        #expect(SpigotDuration.options(maxMinutes: nil) == [5, 10, 15, 30])
    }

    @Test func durationOptionsBoundedByCapAddTheCap() {
        // A 20-minute cap drops 30 and adds 20 as the reachable ceiling.
        #expect(SpigotDuration.options(maxMinutes: 20) == [5, 10, 15, 20])
    }

    @Test func durationOptionsCapBelowSmallestKeepsTheCap() {
        #expect(SpigotDuration.options(maxMinutes: 3) == [3])
    }

    @Test func durationOptionsCapExactlyOnAnOptionDoesNotDuplicate() {
        #expect(SpigotDuration.options(maxMinutes: 15) == [5, 10, 15])
    }

    // MARK: SpigotOutlet.setting preserves the cap

    @Test func settingPreservesMaxOnMinutes() {
        let outlet = SpigotOutlet(instance: "spigot-1", name: "Beds", isOpen: false, remainingMinutes: nil, maxOnMinutes: 20)
        let opened = outlet.setting(open: true, remainingMinutes: 10)
        #expect(opened.maxOnMinutes == 20)
        #expect(opened.remainingMinutes == 10)
    }
}
