import FamilyDomain
import Foundation
import Testing

@testable import HomeKitClient

/// Locks the pure HomeKit snapshot layer (P15-C7): the `HK*Source` → value-type mapping, the curated
/// filtering (lightbulb exclusion, lock/plug/sensor buckets), category naming, characteristic writability,
/// the `Any?` → Sendable value bridge, and the stateful mock. HomeKit classes aren't constructible, so the
/// mapping is exercised via protocol-seam fakes; Michael's real Home is the live test on his phone.
struct HomeKitClientTests {

    // MARK: fakes (protocol seams)

    struct FakeChar: HKCharacteristicSource {
        var idRaw: String
        var type: HKCharacteristicType
        var value: HKCharacteristicValue?
        var isWritable: Bool
    }
    struct FakeService: HKServiceSource {
        var idRaw: String
        var type: HKServiceType
        var nameRaw: String?
        var chars: [FakeChar]
        var characteristicSources: [any HKCharacteristicSource] { chars }
    }
    struct FakeAccessory: HKAccessorySource {
        var idRaw: String
        var nameRaw: String
        var roomRaw: String?
        var categoryRaw: String
        var services: [FakeService]
        var isReachableRaw: Bool
        var serviceSources: [any HKServiceSource] { services }
    }

    private func lightbulb(id: String, name: String) -> FakeAccessory {
        FakeAccessory(
            idRaw: id, nameRaw: name, roomRaw: "Kitchen", categoryRaw: "lightbulb",
            services: [FakeService(idRaw: "\(id)-s", type: .lightbulb, nameRaw: name,
                                   chars: [FakeChar(idRaw: "\(id)-p", type: .powerState, value: .bool(true), isWritable: true)])],
            isReachableRaw: true
        )
    }

    private func lock(id: String, name: String, locked: Bool) -> FakeAccessory {
        FakeAccessory(
            idRaw: id, nameRaw: name, roomRaw: "Entry", categoryRaw: "doorLock",
            services: [FakeService(idRaw: "\(id)-s", type: .lockMechanism, nameRaw: name, chars: [
                FakeChar(idRaw: "\(id)-cur", type: .currentLockState, value: .int(locked ? 1 : 0), isWritable: false),
                FakeChar(idRaw: "\(id)-tgt", type: .targetLockState, value: .int(locked ? 1 : 0), isWritable: true),
            ])],
            isReachableRaw: true
        )
    }

    private func plug(id: String, name: String, on: Bool) -> FakeAccessory {
        FakeAccessory(
            idRaw: id, nameRaw: name, roomRaw: "Den", categoryRaw: "outlet",
            services: [FakeService(idRaw: "\(id)-s", type: .outlet, nameRaw: name,
                                   chars: [FakeChar(idRaw: "\(id)-p", type: .powerState, value: .bool(on), isWritable: true)])],
            isReachableRaw: true
        )
    }

    private func tempSensor(id: String, name: String, celsius: Double) -> FakeAccessory {
        FakeAccessory(
            idRaw: id, nameRaw: name, roomRaw: "Living Room", categoryRaw: "sensor",
            services: [FakeService(idRaw: "\(id)-s", type: .temperatureSensor, nameRaw: name,
                                   chars: [FakeChar(idRaw: "\(id)-t", type: .currentTemperature, value: .double(celsius), isWritable: false)])],
            isReachableRaw: false
        )
    }

    private func garage(id: String, name: String, open: Bool) -> FakeAccessory {
        FakeAccessory(
            idRaw: id, nameRaw: name, roomRaw: "Garage", categoryRaw: "garageDoorOpener",
            services: [FakeService(idRaw: "\(id)-s", type: .garageDoorOpener, nameRaw: name, chars: [
                FakeChar(idRaw: "\(id)-cur", type: .currentDoorState, value: .int(open ? 0 : 1), isWritable: false),
                FakeChar(idRaw: "\(id)-tgt", type: .targetDoorState, value: .int(open ? 0 : 1), isWritable: true),
            ])],
            isReachableRaw: true
        )
    }

    // MARK: mapping

    @Test func mapsSourcesIntoValueTypesFaithfully() {
        let inv = HomeKitSnapshot.inventory(homeName: "Place House", accessories: [
            lock(id: "L1", name: "Front Door", locked: true),
        ])
        #expect(inv.homeName == "Place House")
        #expect(inv.accessories.count == 1)
        let acc = inv.accessories[0]
        #expect(acc.id == "L1")
        #expect(acc.name == "Front Door")
        #expect(acc.room == "Entry")
        #expect(acc.category.displayName == "Door Lock")
        #expect(acc.isReachable == true)
        #expect(acc.services.count == 1)
        let svc = acc.services[0]
        #expect(svc.type == .lockMechanism)
        #expect(svc.characteristics.count == 2)
        // Writability flows through: current is read-only, target is writable.
        #expect(svc.characteristic(.currentLockState)?.isWritable == false)
        #expect(svc.characteristic(.targetLockState)?.isWritable == true)
    }

    // MARK: filtering / curation — lightbulb exclusion

    @Test func lightbulbsAreExcludedFromControlBucketsButAppearInInventory() {
        let inv = HomeKitSnapshot.inventory(homeName: "H", accessories: [
            lightbulb(id: "B1", name: "Hue Bulb"),
            lock(id: "L1", name: "Front Door", locked: true),
            plug(id: "P1", name: "Lamp", on: false),
            tempSensor(id: "T1", name: "Living", celsius: 21),
            garage(id: "G1", name: "Garage", open: false),
        ])
        // Lightbulb NEVER appears in any control bucket (Hue owns lights natively).
        #expect(!inv.powerAccessories.contains { $0.id == "B1" })
        #expect(!inv.lockAccessories.contains { $0.id == "B1" })
        #expect(!inv.sensorAccessories.contains { $0.id == "B1" })
        // But it IS in the full inventory (the discovery surface shows everything).
        #expect(inv.accessories.contains { $0.id == "B1" })
        // The curated buckets pick up exactly the right accessories.
        #expect(inv.lockAccessories.map(\.id) == ["L1"])
        #expect(inv.powerAccessories.map(\.id) == ["P1"])
        #expect(inv.sensorAccessories.map(\.id) == ["T1"])
        #expect(inv.garageAccessories.map(\.id) == ["G1"])
        #expect(inv.hasControllableAccessories)
    }

    @Test func lightsOnlyHomeHasNoControllableAccessories() {
        let inv = HomeKitSnapshot.inventory(homeName: "H", accessories: [
            lightbulb(id: "B1", name: "Bulb 1"),
            lightbulb(id: "B2", name: "Bulb 2"),
        ])
        #expect(!inv.hasControllableAccessories)
        #expect(inv.garageAccessories.isEmpty)
    }

    // MARK: category naming

    @Test func categoryNaming() {
        #expect(HKAccessoryCategory("garageDoorOpener").displayName == "Garage Door Opener")
        #expect(HKAccessoryCategory("doorLock").displayName == "Door Lock")
        #expect(HKAccessoryCategory("outlet").displayName == "Outlet")
        #expect(HKAccessoryCategory("lightbulb").displayName == "Light")
        #expect(HKAccessoryCategory("sensor").displayName == "Sensor")
        // Unknown camelCase is de-camelCased + Title-Cased.
        #expect(HKAccessoryCategory("windowCovering").displayName == "Window Covering")
        #expect(HKAccessoryCategory("").displayName == "Accessory")
    }

    // MARK: readings

    @Test func accessoryReadingsDeriveFromCharacteristics() {
        let g = HomeKitSnapshot.accessory(from: garage(id: "G", name: "Garage", open: true))
        #expect(g.garageIsOpen == true)
        let l = HomeKitSnapshot.accessory(from: lock(id: "L", name: "Front", locked: true))
        #expect(l.lockIsLocked == true)
        let p = HomeKitSnapshot.accessory(from: plug(id: "P", name: "Lamp", on: true))
        #expect(p.powerIsOn == true)
        // 21°C → 69.8°F.
        let t = HomeKitSnapshot.accessory(from: tempSensor(id: "T", name: "Living", celsius: 21))
        #expect((t.temperatureF ?? 0) > 69.7 && (t.temperatureF ?? 0) < 69.9)
    }

    // MARK: value bridge (Any? → Sendable)

    @Test func valueBridgeHandlesBoolIntDouble() {
        #expect(HKCharacteristicValue(homeKit: true) == .bool(true))
        #expect(HKCharacteristicValue(homeKit: 5) == .int(5))
        #expect(HKCharacteristicValue(homeKit: 72.5) == .double(72.5))
        #expect(HKCharacteristicValue(homeKit: "x") == .string("x"))
        #expect(HKCharacteristicValue(homeKit: nil) == nil)
        // Cross-kind accessors.
        #expect(HKCharacteristicValue.int(0).boolValue == false)
        #expect(HKCharacteristicValue.bool(true).intValue == 1)
        #expect(HKCharacteristicValue.int(70).doubleValue == 70)
    }

    // MARK: stateful mock store

    @Test func mockStorePersistsWrites() async {
        let store = HomeKitMockStore()
        await store.reset()

        // Seed: garage closed, door locked, plug off.
        var inv = await store.inventory()
        #expect(inv.garageAccessories.first?.garageIsOpen == false)
        #expect(inv.lockAccessories.first?.lockIsLocked == true)
        #expect(inv.powerAccessories.first?.powerIsOn == false)
        // Two temp sensors in the fixture.
        #expect(inv.sensorAccessories.count == 2)

        // Open the garage (target door state 0 == open) — persists.
        await store.set(accessoryId: HomeKitFixtures.garageId, serviceType: .garageDoorOpener, characteristicType: .targetDoorState, value: .int(0))
        // Unlock the door (target lock state 0 == unsecured) — persists.
        await store.set(accessoryId: HomeKitFixtures.lockId, serviceType: .lockMechanism, characteristicType: .targetLockState, value: .int(0))
        // Turn the plug on — persists.
        await store.set(accessoryId: HomeKitFixtures.plugId, serviceType: .outlet, characteristicType: .powerState, value: .bool(true))

        inv = await store.inventory()
        #expect(inv.garageAccessories.first?.garageIsOpen == true)
        #expect(inv.lockAccessories.first?.lockIsLocked == false)
        #expect(inv.powerAccessories.first?.powerIsOn == true)
    }

    @Test func previewClientServesMockAndMutates() async {
        await HomeKitMockStore.shared.reset()
        let client = HomeKitClient.previewValue
        #expect(await client.authorizationStatus() == .authorized)
        var inv = await client.inventory(HomeKitConfig(mock: true))
        #expect(inv.garageAccessories.first?.garageIsOpen == false)
        try? await client.setCharacteristic(HomeKitConfig(mock: true), HomeKitFixtures.garageId, .garageDoorOpener, .targetDoorState, .int(0))
        inv = await client.inventory(HomeKitConfig(mock: true))
        #expect(inv.garageAccessories.first?.garageIsOpen == true)
        await HomeKitMockStore.shared.reset()
    }
}
