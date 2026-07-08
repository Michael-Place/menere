import ComposableArchitecture
import FamilyDomain
import Foundation
import HueClient
import PersistenceClient
import Testing
import UserDomain

@testable import HouseFeature

/// P16-fixtures — locks the Bacán-side "lamp / fixture" behavior on `HouseReducer`: a fixture's toggle /
/// brightness / color **fan out** to every member bulb; the collapsed row reports a **Mixed** color when
/// members disagree; and combine / un-combine persist through the field-level MERGE
/// (`persistence.updateHueFixtures`) — never the full-doc `saveHueConfig` — so the paired bridges,
/// rituals, and sensor maps in the real `config/hue` doc are never clobbered.
@MainActor
struct HouseReducerFixtureTests {
    private actor Recorder {
        private(set) var lightWrites: [(String, Bool?, Int?)] = []
        func recordLight(_ id: String, _ on: Bool?, _ bri: Int?) { lightWrites.append((id, on, bri)) }
        var lightCount: Int { lightWrites.count }
        var onValues: [Bool?] { lightWrites.map(\.1) }
        var ids: [String] { lightWrites.map(\.0).sorted() }
    }

    private let bridge = HueBridgeConfig(bridgeId: "mock", bridgeIP: "127.0.0.1", applicationKey: "FAKE", mock: true)

    /// A config carrying one "Living room lamp" fixture over bulbs 1+2+3 (in the Downstairs zone "8"),
    /// atop a ritual + sensor label so a persist can be checked against them.
    private func config() -> HueConfig {
        var c = HueConfig(
            bridges: [bridge],
            rituals: [HueRitual(key: "dinner", label: "Dinner", sceneId: "d", groupId: "1", bridgeId: "mock")],
            sensorLabels: ["mock": ["27": "Oliver"]]
        )
        c.fixtures = [HueFixture(id: "fx1", name: "Living room lamp", kind: .lamp, lightIds: ["1", "2", "3"], roomId: "8")]
        return c
    }

    private func snapshot() -> BridgeSnapshot {
        BridgeSnapshot(
            bridge: bridge,
            rooms: HueFixtures.rooms(for: "mock"),
            lights: HueFixtures.lights(for: "mock"),
            scenes: HueFixtures.scenes(for: "mock"),
            temperatures: []
        )
    }

    // MARK: Fan-out

    @Test func toggleFixtureFansOutToAllMembers() async {
        let recorder = Recorder()
        var hue = HueClient.previewValue
        hue.setLightState = { _, id, on, bri, _ in await recorder.recordLight(id, on, bri) }

        let store = TestStore(initialState: HouseReducer.State(config: config(), bridges: [snapshot()])) {
            HouseReducer()
        } withDependencies: {
            $0.hue = hue
        }
        store.exhaustivity = .off

        // Bulbs 1,2,3 are all ON in the fixture → toggling turns the whole lamp OFF.
        await store.send(.toggleFixture(bridgeId: "mock", fixtureId: "fx1"))
        await store.finish()

        #expect(await recorder.lightCount == 3)                      // one write per member
        #expect(await recorder.ids == ["1", "2", "3"])               // exactly the members
        #expect(await recorder.onValues.allSatisfy { $0 == false })  // all driven OFF together
    }

    @Test func fixtureBrightnessDebouncesThenFansOut() async {
        let clock = TestClock()
        let recorder = Recorder()
        var hue = HueClient.previewValue
        hue.setLightState = { _, id, on, bri, _ in await recorder.recordLight(id, on, bri) }

        let store = TestStore(initialState: HouseReducer.State(config: config(), bridges: [snapshot()])) {
            HouseReducer()
        } withDependencies: {
            $0.hue = hue
            $0.continuousClock = clock
        }
        store.exhaustivity = .off

        for pct in [20.0, 40.0, 60.0] {
            await store.send(.fixtureBrightnessChanged(bridgeId: "mock", fixtureId: "fx1", percent: pct))
        }
        #expect(await recorder.lightCount == 0)   // still dragging — nothing written

        await clock.advance(by: .milliseconds(150))
        await store.receive(\.commitFixtureBrightness)
        await store.finish()

        #expect(await recorder.lightCount == 3)   // ONE brightness write per member after quiescence
        #expect(await recorder.ids == ["1", "2", "3"])
    }

    // MARK: Mixed-state detection through the reducer

    @Test func fixtureStateReportsMixedWhenMembersDisagree() {
        // Bulbs 1 (amber hs) and 2 (blue hs) differ → the fixture reads Mixed; bulb 3 is ct (ambiance).
        let state = HouseReducer.State(config: config(), bridges: [snapshot()])
        let fx = state.fixtureState(bridgeId: "mock", fixtureId: "fx1")
        #expect(fx?.isMixedColor == true)
        #expect(fx?.memberCount == 3)
        #expect(fx?.supportsColor == true)

        // Grouping: the fixture collapses 1+2+3 into one entry; bulb 4 (Kitchen sink) stays loose.
        let grouping = state.roomFixtureGrouping(bridgeId: "mock", roomId: "8")
        #expect(grouping.fixtures.map(\.fixture.id) == ["fx1"])
        #expect(grouping.fixtures.first?.lights.map(\.id) == ["1", "2", "3"])
        #expect(grouping.ungrouped.map(\.id) == ["4"])
    }

    // MARK: Combine / un-combine persist via MERGE only

    @Test func combineFlowPersistsViaMergeNeverFullDoc() async {
        try? await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Michael", householdId: "hid-1") }

            let merged = LockIsolated<[[HueFixture]]>([])
            let fullSaved = LockIsolated(false)

            // Start with NO fixtures so the loose bulbs 1..4 are all selectable.
            var startConfig = config()
            startConfig.fixtures = []

            let store = TestStore(initialState: HouseReducer.State(config: startConfig, bridges: [snapshot()])) {
                HouseReducer()
            } withDependencies: {
                $0.uuid = .incrementing
                $0.persistence.updateHueFixtures = { _, fixtures in merged.withValue { $0.append(fixtures) } }
                $0.persistence.saveHueConfig = { _, _ in fullSaved.setValue(true) }
            }
            store.exhaustivity = .off

            await store.send(.beginFixtureSelection(bridgeId: "mock", roomId: "8"))
            await store.send(.toggleLightSelection(lightId: "1"))
            await store.send(.toggleLightSelection(lightId: "2"))
            await store.send(.startCombine)
            #expect(store.state.combineDraft?.lightIds == ["1", "2"])

            await store.send(.confirmCombine)
            await store.finish()

            // Config gained exactly one fixture over bulbs 1+2, and the ritual + sensor label survive.
            #expect(store.state.config.fixtures.count == 1)
            #expect(store.state.config.fixtures.first?.lightIds == ["1", "2"])
            #expect(store.state.config.rituals.count == 1)
            #expect(store.state.config.sensorLabels == ["mock": ["27": "Oliver"]])
            #expect(store.state.combineDraft == nil)
            #expect(store.state.fixtureSelection == nil)

            // Persisted via the MERGE endpoint (fixtures only) — the full-doc write is NEVER used.
            #expect(merged.value.count == 1)
            #expect(merged.value.first?.first?.lightIds == ["1", "2"])
            #expect(fullSaved.value == false)
        }
    }

    @Test func uncombineDissolvesAndMergePersists() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Michael", householdId: "hid-1") }

            let merged = LockIsolated<[[HueFixture]]>([])
            let fullSaved = LockIsolated(false)

            let store = TestStore(initialState: HouseReducer.State(config: config(), bridges: [snapshot()])) {
                HouseReducer()
            } withDependencies: {
                $0.persistence.updateHueFixtures = { _, fixtures in merged.withValue { $0.append(fixtures) } }
                $0.persistence.saveHueConfig = { _, _ in fullSaved.setValue(true) }
            }
            store.exhaustivity = .off

            await store.send(.uncombineFixture(fixtureId: "fx1"))
            await store.finish()

            #expect(store.state.config.fixtures.isEmpty)
            #expect(store.state.config.rituals.count == 1)   // ritual untouched
            #expect(merged.value == [[]])                    // merge-wrote the now-empty fixtures array
            #expect(fullSaved.value == false)                // never full-doc wrote
        }
    }
}
