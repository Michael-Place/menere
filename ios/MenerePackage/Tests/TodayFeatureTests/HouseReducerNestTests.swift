import ComposableArchitecture
import FamilyDomain
import HueClient
import NestClient
import Testing

@testable import TodayFeature

/// Locks the P15-C3 Nest verbs on `HouseReducer`: setpoint stepping is optimistic and the −/+ taps
/// collapse to a SINGLE SDM command after ≥300ms of quiet (a coarser debounce than the LAN sliders,
/// since SDM is a cloud call); mode changes are optimistic.
@MainActor
struct HouseReducerNestTests {
    private actor SetpointRecorder {
        private(set) var commits: [(String, NestSetpoint)] = []
        func record(_ id: String, _ s: NestSetpoint) { commits.append((id, s)) }
        var count: Int { commits.count }
        var last: NestSetpoint? { commits.last?.1 }
    }
    private actor ModeRecorder {
        private(set) var modes: [NestMode] = []
        func record(_ m: NestMode) { modes.append(m) }
        var count: Int { modes.count }
        var last: NestMode? { modes.last }
    }

    private let bridge = HueBridgeConfig(bridgeId: "B", bridgeIP: "10.0.0.1", applicationKey: "k")
    private var deviceName: String { NestFixtures.downstairsName }

    private func makeState() -> HouseReducer.State {
        HouseReducer.State(
            config: HueConfig(bridges: [bridge]), bridges: [],
            nestConfig: NestConfig(projectId: "P", oauthClientId: "C", mock: true),
            thermostats: [NestFixtures.downstairs]   // heat mode, 70°F setpoint
        )
    }

    /// A single +1 step nudges the setpoint locally before the write lands.
    @Test func setpointStepIsOptimistic() async {
        let clock = TestClock()
        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.continuousClock = clock
            $0.nest = .previewValue
        }
        store.exhaustivity = .off

        await store.send(.nestSetpointStepped(deviceName: deviceName, kind: .heat, deltaF: 1)) {
            $0.thermostats[0] = $0.thermostats[0].settingSetpointF(.heat, to: 71)
        }
        #expect(store.state.thermostats[0].heatSetpointF == 71)   // optimistic, before the commit

        // Drain the debounced commit so no effect dangles at deinit.
        await clock.advance(by: .milliseconds(300))
        await store.finish()
    }

    /// Three rapid +1 taps → zero writes while tapping, exactly ONE SetHeat (to 73) after 300ms of quiet.
    @Test func stepperSpamCollapsesToOneCommit() async {
        let clock = TestClock()
        let recorder = SetpointRecorder()
        var client = NestClient.previewValue
        client.setTemperatureF = { _, name, setpoint in await recorder.record(name, setpoint) }

        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.continuousClock = clock
            $0.nest = client
        }
        store.exhaustivity = .off

        for _ in 0..<3 {
            await store.send(.nestSetpointStepped(deviceName: deviceName, kind: .heat, deltaF: 1))
        }
        #expect(await recorder.count == 0)   // still tapping — nothing committed

        await clock.advance(by: .milliseconds(300))
        await store.receive(\.commitNestSetpoint)
        await store.finish()

        #expect(await recorder.count == 1)   // one SetHeat despite three taps
        #expect(await recorder.last == .heat(73))   // 70 → 73
    }

    /// A mode change flips state immediately and fires one SetMode.
    @Test func modeChangeIsOptimistic() async {
        let recorder = ModeRecorder()
        var client = NestClient.previewValue
        client.setMode = { _, _, mode in await recorder.record(mode) }

        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.nest = client
        }
        store.exhaustivity = .off

        await store.send(.setNestMode(deviceName: deviceName, mode: .off)) {
            $0.thermostats[0] = $0.thermostats[0].settingMode(.off)
        }
        await store.finish()
        #expect(store.state.thermostats[0].mode == .off)
        #expect(await recorder.count == 1)
        #expect(await recorder.last == .off)
    }
}
