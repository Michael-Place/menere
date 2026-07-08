import FamilyDomain
import HomeKitClient
import HubspaceClient
import HueClient
import LutronClient
import NestClient
import Testing

@testable import HouseFeature

/// Locks the Rooms/Devices view-mode grouping (Michael's House layout toggle): room derivation per
/// client, case-insensitive merge across subsystems, the "Whole house" bucket for room-less devices, and
/// the busiest-room-first ordering. All pure reads off `HouseReducer.State`.
struct HouseReducerRoomGroupingTests {

    // MARK: Fixtures

    private func hueRoom(_ id: String, _ name: String, type: String = "Room") -> HueRoom {
        HueRoom(id: id, name: name, type: type, lightIds: ["l-\(id)"], anyOn: true, brightness: 200)
    }

    /// A State whose Hue section is `.ok` (loaded, non-empty) for the given bridge rooms/lights.
    private func stateWithHue(_ rooms: [HueRoom]) -> HouseReducer.State {
        let config = HueConfig(bridgeId: "b1", bridgeIP: "127.0.0.1", applicationKey: "k", mock: true)
        let lights = rooms.flatMap { $0.lightIds }.map { HueLight(id: $0, name: $0, isOn: true, brightness: 200, reachable: true) }
        var s = HouseReducer.State(config: config)
        s.bridges = [BridgeSnapshot(bridge: config.bridges[0], rooms: rooms, lights: lights, scenes: [], temperatures: [])]
        s.hueLoaded = true
        return s
    }

    private func shade(_ zone: String, area: String) -> LutronShade {
        LutronShade(zoneId: zone, name: "Shade \(zone)", areaName: area, level: 50)
    }

    private func lock(_ id: String, room: String?) -> HKAccessory {
        HKAccessory(id: id, name: "Lock \(id)", room: room, category: HKAccessoryCategory("doorLock"),
                    services: [HKService(id: "s-\(id)", type: .lockMechanism, name: "Lock \(id)", characteristics: [
                        HKCharacteristicSnapshot(id: "c-\(id)", type: .currentLockState, value: .int(1), isWritable: false),
                    ])], isReachable: true)
    }

    // MARK: Merge across subsystems (case-insensitive)

    @Test func mergesSameRoomNameAcrossProductsIntoOneCard() {
        var s = stateWithHue([hueRoom("1", "Living Room")])
        s.lutronConfig = LutronConfig(bridgeIP: "127.0.0.1", mock: true)
        s.shades = [shade("z1", area: "living room")]   // different casing
        s.lutronLoaded = true

        let groups = s.roomGroups
        #expect(groups.count == 1)
        let living = groups[0]
        #expect(living.hueRooms.count == 1)
        #expect(living.shades.count == 1)
        // Display name = first-seen original (the Hue spelling), key = normalized.
        #expect(living.displayName == "Living Room")
        #expect(living.key == "living room")
        #expect(living.deviceCount == 2)
    }

    @Test func trimsWhitespaceWhenMerging() {
        var s = stateWithHue([hueRoom("1", "Kitchen")])
        s.lutronConfig = LutronConfig(bridgeIP: "127.0.0.1", mock: true)
        s.shades = [shade("z1", area: "  Kitchen  ")]
        s.lutronLoaded = true
        #expect(s.roomGroups.count == 1)
        #expect(s.roomGroups[0].deviceCount == 2)
    }

    // MARK: Ordering (busiest room first, then name)

    @Test func ordersByDeviceCountThenName() {
        var s = stateWithHue([hueRoom("1", "Bedroom"), hueRoom("2", "Office")])
        s.lutronConfig = LutronConfig(bridgeIP: "127.0.0.1", mock: true)
        // Bedroom gets a 2nd device → it should sort ahead of Office (1 device).
        s.shades = [shade("z1", area: "Bedroom")]
        s.lutronLoaded = true
        let names = s.roomGroups.map(\.displayName)
        #expect(names == ["Bedroom", "Office"])
    }

    // MARK: Zones excluded from room grouping

    @Test func hueZonesAreNotTheirOwnRoom() {
        let s = stateWithHue([hueRoom("1", "Den"), hueRoom("z", "Downstairs", type: "Zone")])
        let names = s.roomGroups.map(\.displayName)
        #expect(names == ["Den"])   // the Zone does not create a room card
    }

    // MARK: Whole-house bucket (room-less devices)

    @Test func roomlessHomeKitFallsToWholeHouse() {
        var s = stateWithHue([hueRoom("1", "Entry")])
        let inv = HKInventory(homeName: "Place", accessories: [
            lock("roomed", room: "Entry"),
            lock("roomless", room: nil),
        ])
        s.homekitConfig = HomeKitConfig(mock: true)
        s.homekitAuth = .authorized
        s.homekitInventory = inv
        s.homekitLoaded = true

        // The roomed lock merges into the Entry card; the room-less one is excluded from room groups.
        let entry = s.roomGroups.first { $0.key == "entry" }
        #expect(entry?.locks.count == 1)
        #expect(s.roomGroups.allSatisfy { $0.locks.allSatisfy { $0.id != "roomless" } })
        // …and surfaces in the Whole house bucket instead.
        #expect(s.wholeHouseLocks.map(\.id) == ["roomless"])
        #expect(s.hasWholeHouseContent)
    }

    @Test func offlineSectionDoesNotContributeRooms() {
        // Lutron configured but never loaded (still loading) → its shades don't leak into rooms.
        var s = stateWithHue([hueRoom("1", "Loft")])
        s.lutronConfig = LutronConfig(bridgeIP: "127.0.0.1", mock: true)
        s.shades = []               // nothing loaded yet
        // lutronLoaded stays false → lutronStatus == .loading, not .ok
        #expect(s.lutronStatus == .loading)
        #expect(s.roomGroups.count == 1)
        #expect(s.roomGroups[0].shades.isEmpty)
    }

    // MARK: View-mode default

    @Test func viewModeRoundTrips() {
        #expect(HouseViewMode(rawValue: "rooms") == .rooms)
        #expect(HouseViewMode(rawValue: "devices") == .devices)
        #expect(HouseViewMode(rawValue: "garbage") == nil)
    }
}
