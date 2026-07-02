import ComposableArchitecture
import FamilyDomain
import HueClient
import XCTest

@testable import SettingsFeature

/// `TestStore` walk of the pairing state machine: discover → single-bridge auto-advance → 30s
/// link-button poll (101 retries) → key minted → binding auto-match → save. P12-C3 adds the
/// multi-bridge **append** path (a second bridge joins an existing config, its bindings scoped to
/// its own id, the first bridge untouched).
@MainActor
final class HuePairingReducerTests: XCTestCase {
    private let bridge = DiscoveredBridge(id: "001788FFFEABCDEF", ip: "192.168.1.5")
    private let cozyBedtime = HueScene(id: "scene-bed", name: "Cozy Bedtime", groupId: "3")
    private let dinnerTime = HueScene(id: "scene-din", name: "Dinner time", groupId: "1")
    private let relax = HueScene(id: "scene-relax", name: "Relax", groupId: "2")
    private let sensor = HueSensorInfo(id: "s1", name: "Nursery sensor")

    /// authenticate throws 101 twice, then mints the key on the third attempt.
    private actor Attempts { var n = 0; func bump() -> Int { n += 1; return n } }

    func testHappyPathAutoBindsBothRitualsAndSaves() async {
        let clock = TestClock()
        let attempts = Attempts()
        let savedBox = LockIsolated<HueConfig?>(nil)

        let bridge = self.bridge
        let scenes = [cozyBedtime, dinnerTime]
        let sensors = [sensor]

        let store = TestStore(initialState: HuePairingReducer.State(hid: "hid-1")) {
            HuePairingReducer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.hue.discoverBridges = { [bridge] }
            $0.hue.authenticate = { _ in
                if await attempts.bump() <= 2 { throw HueError.linkButtonNotPressed }
                return "app-key"
            }
            $0.hue.bridgeInfo = { _, _ in HueBridgeInfo(id: bridge.id, name: "Downstairs Hub") }
            $0.hue.scenes = { _ in scenes }
            $0.hue.sensors = { _ in sensors }
            $0.persistence.saveHueConfig = { _, config in savedBox.setValue(config) }
        }

        await store.send(.task)
        await store.receive(\.bridgesDiscovered) { $0.bridges = [bridge] }
        await store.receive(\.bridgeSelected) {
            $0.selectedBridge = bridge
            $0.step = .linkButton
            $0.countdown = 30
        }
        // First poll → 101 → tick (countdown 29), then a 1s sleep before the next poll.
        await store.receive(\.pollAuthenticate)
        await store.receive(\.pollTick) { $0.countdown = 29 }
        await clock.advance(by: .seconds(1))
        await store.receive(\.pollAuthenticate)
        await store.receive(\.pollTick) { $0.countdown = 28 }
        await clock.advance(by: .seconds(1))
        // Third poll → key minted.
        await store.receive(\.pollAuthenticate)
        await store.receive(\.keyMinted) {
            $0.applicationKey = "app-key"
            $0.step = .connecting
        }
        await store.receive(\.bindingDataLoaded) {
            $0.bridgeId = self.bridge.id
            $0.bridgeName = "Downstairs Hub"
            $0.scenes = scenes
            $0.step = .binding
            $0.ritualBindings = [
                .init(key: "bedtime", label: "Bedtime", sceneId: "scene-bed", groupId: "3", autoMatched: true),
                .init(key: "dinner", label: "Dinner's ready", sceneId: "scene-din", groupId: "1", autoMatched: true),
            ]
            $0.sensorDrafts = [.init(id: "s1", bridgeName: "Nursery sensor", label: "")]
        }

        let expected = HueConfig(
            bridges: [HueBridgeConfig(bridgeId: bridge.id, bridgeIP: bridge.ip, applicationKey: "app-key", name: "Downstairs Hub")],
            rituals: [
                HueRitual(key: "bedtime", label: "Bedtime", sceneId: "scene-bed", groupId: "3", bridgeId: bridge.id),
                HueRitual(key: "dinner", label: "Dinner's ready", sceneId: "scene-din", groupId: "1", bridgeId: bridge.id),
            ],
            roomOwners: nil,
            sensorLabels: [:],
            sensorNames: [bridge.id: ["s1": "Nursery sensor"]]
        )

        await store.send(.saveTapped) { $0.step = .saving }
        await store.receive(\.saved) { $0.step = .done }
        await clock.advance(by: .seconds(1.2))
        await store.receive(\.delegate)

        XCTAssertEqual(savedBox.value, expected)
        XCTAssertNil(savedBox.value?.bridges.first?.mock)   // real bridge — no mock flag.
    }

    func testUnmatchedRitualLeftUnboundAndOmittedFromSave() async {
        let clock = TestClock()
        let savedBox = LockIsolated<HueConfig?>(nil)
        let bridge = self.bridge
        // Only a dinner scene + an unrelated one → Bedtime has nothing to match.
        let scenes = [dinnerTime, relax]

        let store = TestStore(initialState: HuePairingReducer.State(hid: "hid-1")) {
            HuePairingReducer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.hue.discoverBridges = { [bridge] }
            $0.hue.authenticate = { _ in "app-key" }   // button already pressed → immediate key
            $0.hue.bridgeInfo = { _, _ in HueBridgeInfo(id: bridge.id, name: "Bridge") }
            $0.hue.scenes = { _ in scenes }
            $0.hue.sensors = { _ in [] }
            $0.persistence.saveHueConfig = { _, config in savedBox.setValue(config) }
        }

        await store.send(.task)
        await store.receive(\.bridgesDiscovered) { $0.bridges = [bridge] }
        await store.receive(\.bridgeSelected) {
            $0.selectedBridge = bridge
            $0.step = .linkButton
            $0.countdown = 30
        }
        await store.receive(\.pollAuthenticate)
        await store.receive(\.keyMinted) {
            $0.applicationKey = "app-key"
            $0.step = .connecting
        }
        await store.receive(\.bindingDataLoaded) {
            $0.bridgeId = self.bridge.id
            $0.bridgeName = "Bridge"
            $0.scenes = scenes
            $0.step = .binding
            $0.ritualBindings = [
                .init(key: "bedtime", label: "Bedtime", sceneId: nil, groupId: nil, autoMatched: false),
                .init(key: "dinner", label: "Dinner's ready", sceneId: "scene-din", groupId: "1", autoMatched: true),
            ]
            $0.sensorDrafts = []
        }

        await store.send(.saveTapped) { $0.step = .saving }
        await store.receive(\.saved) { $0.step = .done }
        await clock.advance(by: .seconds(1.2))
        await store.receive(\.delegate)

        // Only the bound ritual (dinner) is persisted; Bedtime is simply absent.
        XCTAssertEqual(savedBox.value?.rituals.map(\.key), ["dinner"])
    }

    /// P12-C3: adding a SECOND bridge appends to the existing config and scopes the new bridge's
    /// binding to its own id — the first bridge's ritual is preserved, only the still-unbound
    /// standard (Bedtime) is offered against the new bridge's scenes. (Michael's exact flow.)
    func testAddSecondBridgeAppendsAndScopesBindings() async {
        let clock = TestClock()
        let savedBox = LockIsolated<HueConfig?>(nil)

        // Existing config: a "Downstairs" bridge with Dinner bound to one of its scenes.
        let existing = HueConfig(
            bridges: [HueBridgeConfig(bridgeId: "DOWN", bridgeIP: "192.168.1.10", applicationKey: "down-key", name: "Downstairs")],
            rituals: [HueRitual(key: "dinner", label: "Dinner's ready", sceneId: "d-scene", groupId: "1", bridgeId: "DOWN")]
        )
        let down = DiscoveredBridge(id: "DOWN", ip: "192.168.1.10")   // already paired → excluded
        let up = DiscoveredBridge(id: "UP", ip: "192.168.1.20")       // the new one
        let upBedtime = HueScene(id: "up-bed", name: "Bedtime", groupId: "7")

        let store = TestStore(
            initialState: HuePairingReducer.State(hid: "hid-1", existingConfig: existing, repairingBridgeId: nil)
        ) {
            HuePairingReducer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.hue.discoverBridges = { [down, up] }
            $0.hue.authenticate = { _ in "up-key" }
            $0.hue.bridgeInfo = { _, _ in HueBridgeInfo(id: "UP", name: "Upstairs") }
            $0.hue.scenes = { _ in [upBedtime] }
            $0.hue.sensors = { _ in [] }
            $0.persistence.saveHueConfig = { _, config in savedBox.setValue(config) }
        }

        await store.send(.task)
        // DOWN is filtered out (already paired) → only UP remains → auto-advance.
        await store.receive(\.bridgesDiscovered) { $0.bridges = [up] }
        await store.receive(\.bridgeSelected) {
            $0.selectedBridge = up
            $0.step = .linkButton
            $0.countdown = 30
        }
        await store.receive(\.pollAuthenticate)
        await store.receive(\.keyMinted) {
            $0.applicationKey = "up-key"
            $0.step = .connecting
        }
        await store.receive(\.bindingDataLoaded) {
            $0.bridgeId = "UP"
            $0.bridgeName = "Upstairs"
            $0.scenes = [upBedtime]
            $0.step = .binding
            // Dinner is owned by DOWN → not re-offered; only unbound Bedtime, matched on UP.
            $0.ritualBindings = [
                .init(key: "bedtime", label: "Bedtime", sceneId: "up-bed", groupId: "7", autoMatched: true),
            ]
            $0.sensorDrafts = []
        }

        await store.send(.saveTapped) { $0.step = .saving }
        await store.receive(\.saved) { $0.step = .done }
        await clock.advance(by: .seconds(1.2))
        await store.receive(\.delegate)

        let saved = savedBox.value
        XCTAssertEqual(saved?.bridges.map(\.bridgeId), ["DOWN", "UP"])          // appended, not replaced
        XCTAssertEqual(saved?.bridges.first(where: { $0.bridgeId == "UP" })?.name, "Upstairs")
        // Dinner stays on DOWN; Bedtime lands on UP.
        XCTAssertEqual(saved?.rituals.first(where: { $0.key == "dinner" })?.bridgeId, "DOWN")
        XCTAssertEqual(saved?.rituals.first(where: { $0.key == "bedtime" })?.bridgeId, "UP")
        XCTAssertEqual(saved?.rituals.first(where: { $0.key == "bedtime" })?.sceneId, "up-bed")
    }
}
