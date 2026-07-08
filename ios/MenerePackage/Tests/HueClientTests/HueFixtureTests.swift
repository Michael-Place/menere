import FamilyDomain
import Foundation
import HueClient
import Testing

/// P16-fixtures — locks the Bacán-side "lamp / fixture" overlay: the config round-trips `fixtures`
/// alongside bridges/rituals/sensors, the pure CRUD helpers touch ONLY the fixtures array (so a
/// fixture edit can never clobber the paired-bridge/ritual/sensor data), and `HueFixtureState` folds a
/// fixture's member bulbs into the collapsed row's readout (any-on, representative brightness, and the
/// **Mixed** detection). Uses fake keys only — never the real secret.
struct HueFixtureTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// A believable already-paired config with rituals + sensor maps — the data a fixture write must
    /// never disturb.
    private func baseConfig() -> HueConfig {
        HueConfig(
            bridges: [HueBridgeConfig(bridgeId: "A", bridgeIP: "10.0.0.1", applicationKey: "FAKE", name: "Downstairs")],
            rituals: [HueRitual(key: "dinner", label: "Dinner", sceneId: "d", groupId: "1", bridgeId: "A")],
            roomOwners: ["1": "oliver"],
            sensorLabels: ["A": ["27": "Oliver's room"]],
            sensorNames: ["A": ["27": "Nursery sensor"]]
        )
    }

    // MARK: Codable

    @Test func fixturesRoundTripAlongsideEverything() throws {
        var config = baseConfig()
        config.fixtures = [
            HueFixture(id: "fx1", name: "Living room lamp", kind: .lamp, lightIds: ["1", "2", "3"], roomId: "8"),
            HueFixture(id: "fx2", name: "Kitchen ceiling", kind: .ceiling, lightIds: ["4", "5"], roomId: "2"),
        ]
        let decoded = try decoder.decode(HueConfig.self, from: encoder.encode(config))
        #expect(decoded == config)
        #expect(decoded.fixtures.map(\.id) == ["fx1", "fx2"])
        #expect(decoded.fixtures.first?.kind == .lamp)
        #expect(decoded.fixtures.first?.lightIds == ["1", "2", "3"])
    }

    @Test func legacyDocWithoutFixturesDecodesToEmpty() throws {
        // A doc that predates fixtures (no `fixtures` key) must decode with an empty array, unchanged.
        let json = """
        {
          "bridges": [{ "bridgeId": "A", "bridgeIP": "10.0.0.1", "applicationKey": "FAKE" }],
          "rituals": [],
          "sensorLabels": {}
        }
        """.data(using: .utf8)!
        let config = try decoder.decode(HueConfig.self, from: json)
        #expect(config.fixtures.isEmpty)
    }

    @Test func unknownFixtureKindDecodesToOther() throws {
        let json = """
        { "id": "x", "name": "Weird", "kind": "chandelier", "lightIds": ["1","2"], "roomId": "1" }
        """.data(using: .utf8)!
        let fixture = try decoder.decode(HueFixture.self, from: json)
        #expect(fixture.kind == .other)
    }

    // MARK: CRUD preserves bridges / rituals / sensors (the merge-safety guarantee at the model level)

    @Test func addingFixtureLeavesBridgesRitualsSensorsUntouched() {
        let config = baseConfig()
        let after = config.addingFixture(HueFixture(id: "fx1", name: "Lamp", kind: .lamp, lightIds: ["1", "2"], roomId: "8"))
        #expect(after.bridges == config.bridges)
        #expect(after.rituals == config.rituals)
        #expect(after.roomOwners == config.roomOwners)
        #expect(after.sensorLabels == config.sensorLabels)
        #expect(after.sensorNames == config.sensorNames)
        #expect(after.fixtures.count == 1)
    }

    @Test func addingFixtureClaimsMembersFromAnyOtherFixture() {
        var config = baseConfig()
        config.fixtures = [HueFixture(id: "old", name: "Old", kind: .lamp, lightIds: ["1", "2", "3"], roomId: "8")]
        // A new fixture claiming light 2 must prune it from "old".
        let after = config.addingFixture(HueFixture(id: "new", name: "New", kind: .sconce, lightIds: ["2", "4"], roomId: "8"))
        let old = after.fixtures.first { $0.id == "old" }
        #expect(old?.lightIds == ["1", "3"])           // 2 pruned out
        #expect(after.fixtures.first { $0.id == "new" }?.lightIds == ["2", "4"])
    }

    @Test func removingFixtureAndLightPreserveTheRest() {
        var config = baseConfig()
        config.fixtures = [HueFixture(id: "fx1", name: "Lamp", kind: .lamp, lightIds: ["1", "2", "3"], roomId: "8")]
        // Remove one member → still a fixture (2 left).
        let two = config.removingLight("3", fromFixture: "fx1")
        #expect(two.fixtures.first?.lightIds == ["1", "2"])
        #expect(two.rituals == config.rituals)   // untouched
        // Remove another → falls below 2 → dissolves entirely.
        let gone = two.removingLight("2", fromFixture: "fx1")
        #expect(gone.fixtures.isEmpty)
        #expect(gone.bridges == config.bridges)   // still untouched
    }

    @Test func renamingFixtureOnlyTouchesThatFixture() {
        var config = baseConfig()
        config.fixtures = [HueFixture(id: "fx1", name: "Lamp", kind: .lamp, lightIds: ["1", "2"], roomId: "8")]
        let after = config.renamingFixture("fx1", name: "Reading lamp", kind: .floorLamp)
        #expect(after.fixtures.first?.name == "Reading lamp")
        #expect(after.fixtures.first?.kind == .floorLamp)
        #expect(after.sensorLabels == config.sensorLabels)
    }

    @Test func fixturesInRoomFiltersByRoom() {
        var config = baseConfig()
        config.fixtures = [
            HueFixture(id: "a", name: "A", kind: .lamp, lightIds: ["1"], roomId: "8"),
            HueFixture(id: "b", name: "B", kind: .ceiling, lightIds: ["2"], roomId: "2"),
        ]
        #expect(config.fixtures(inRoom: "8").map(\.id) == ["a"])
        #expect(config.fixture(owningLight: "2")?.id == "b")
    }

    // MARK: HueFixtureState aggregation

    private func color(_ id: String, on: Bool, bri: Int, hue: Int?, sat: Int?, reachable: Bool = true) -> HueLight {
        HueLight(id: id, name: id, isOn: on, brightness: bri, reachable: reachable,
                 colorMode: hue == nil ? .none : .hs, hue: hue, saturation: sat,
                 supportsColor: true, supportsColorTemp: true)
    }

    @Test func onIsAnyMemberOn() {
        let members = [
            color("1", on: false, bri: 100, hue: 0, sat: 254),
            color("2", on: true, bri: 200, hue: 0, sat: 254),
        ]
        #expect(HueFixtureState(members: members).isOn == true)
        let allOff = members.map { var l = $0; l.isOn = false; return l }
        #expect(HueFixtureState(members: allOff).isOn == false)
    }

    @Test func representativeBrightnessIsMeanOfReachableMembers() {
        let members = [
            color("1", on: true, bri: 100, hue: 0, sat: 254),
            color("2", on: true, bri: 200, hue: 0, sat: 254),
            color("3", on: true, bri: 240, hue: 0, sat: 254, reachable: false), // excluded (unreachable)
        ]
        #expect(HueFixtureState(members: members).brightness == 150) // mean of 100 & 200
        #expect(HueFixtureState(members: members).memberCount == 3)
    }

    @Test func sharedColorIsNotMixed() {
        let members = [
            color("1", on: true, bri: 100, hue: 46920, sat: 254),
            color("2", on: true, bri: 200, hue: 46920, sat: 254),
        ]
        let fx = HueFixtureState(members: members)
        #expect(fx.isMixedColor == false)
        #expect(fx.supportsColor == true)
    }

    @Test func disagreeingColorsAreMixed() {
        let members = [
            color("1", on: true, bri: 100, hue: 8000, sat: 200),   // amber
            color("2", on: true, bri: 200, hue: 46920, sat: 254),  // blue
        ]
        #expect(HueFixtureState(members: members).isMixedColor == true)
    }

    @Test func offMembersDoNotCountAsDisagreement() {
        // An OFF bulb carries stale color we shouldn't read as a conflict.
        let members = [
            color("1", on: true, bri: 100, hue: 8000, sat: 200),
            color("2", on: false, bri: 200, hue: 46920, sat: 254),
        ]
        #expect(HueFixtureState(members: members).isMixedColor == false)
    }

    @Test func mixedColorTempWithinToleranceAgrees() {
        let a = HueLight(id: "1", name: "1", isOn: true, brightness: 100, colorMode: .ct, colorTemp: 300, supportsColorTemp: true)
        let b = HueLight(id: "2", name: "2", isOn: true, brightness: 100, colorMode: .ct, colorTemp: 310, supportsColorTemp: true)
        #expect(HueFixtureState(members: [a, b]).isMixedColor == false)   // 10 mireds apart, within tol
        let c = HueLight(id: "3", name: "3", isOn: true, brightness: 100, colorMode: .ct, colorTemp: 450, supportsColorTemp: true)
        #expect(HueFixtureState(members: [a, c]).isMixedColor == true)     // 150 apart → mixed
    }
}
