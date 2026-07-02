import ComposableArchitecture
import FamilyDomain
import HueClient
import LutronClient
import Testing

@testable import TodayFeature

/// Locks the P15-C1 shade verbs on `HouseReducer`: shades load on `.task`, the slider debounces its
/// `GoToLevel` writes (≥150ms, same floor as the Hue brightness sliders — bridges dislike write spam),
/// and raise/lower are optimistic to the extremes.
@MainActor
struct HouseReducerShadeTests {
    private actor SetCounter {
        private(set) var sets: [(String, Int)] = []
        func record(_ zone: String, _ level: Int) { sets.append((zone, level)) }
        var count: Int { sets.count }
    }

    private let bridge = HueBridgeConfig(bridgeId: "B", bridgeIP: "10.0.0.1", applicationKey: "k")
    private let lutronConfig = LutronConfig(bridgeIP: "10.0.0.2", mock: true)

    private func makeState() -> HouseReducer.State {
        HouseReducer.State(
            config: HueConfig(bridges: [bridge]),
            bridges: [],
            lutronConfig: lutronConfig,
            shades: [LutronShade(zoneId: "5", name: "Oliver's room shade", areaName: "Oliver's room", level: 100)]
        )
    }

    /// Five rapid shade-slider events → zero writes while dragging, exactly one after 150ms of quiet.
    @Test func shadeSliderSpamCollapsesToOneWrite() async {
        let clock = TestClock()
        let counter = SetCounter()
        var client = LutronClient.previewValue
        client.setShadeLevel = { _, zone, level in await counter.record(zone, level) }

        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.continuousClock = clock
            $0.lutron = client
        }
        store.exhaustivity = .off

        for level in [10, 25, 40, 60, 80] {
            await store.send(.shadeLevelChanged(zoneId: "5", level: level))
        }
        #expect(await counter.count == 0)   // still dragging

        await clock.advance(by: .milliseconds(150))
        await store.receive(\.commitShadeLevel)
        await store.finish()
        #expect(await counter.count == 1)   // one GoToLevel despite five deltas
    }

    /// Raise/lower optimistically snap the local level to open/closed.
    @Test func raiseLowerAreOptimistic() async {
        let clock = TestClock()
        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.continuousClock = clock
            $0.lutron = .previewValue
        }
        store.exhaustivity = .off

        await store.send(.lowerShade(zoneId: "5")) {
            $0.shades[0].level = 0
        }
        await store.send(.raiseShade(zoneId: "5")) {
            $0.shades[0].level = 100
        }
    }
}
