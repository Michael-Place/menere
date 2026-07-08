import ComposableArchitecture
import FamilyDomain
import HueClient
import Testing

@testable import HouseFeature

/// Locks the P12-C4 slider-debounce contract: Hue bridges dislike >10 req/s, so brightness sliders
/// MUST NOT fire a PUT per drag delta. `HouseReducer` schedules each write behind a `continuousClock`
/// sleep guarded by a per-target `cancellable(cancelInFlight:)`, so a burst of slider events collapses
/// to a single write once the slider quiesces for ≥150ms. These tests drive that with a `TestClock`
/// and a call-counting `HueClient`.
@MainActor
struct HouseReducerDebounceTests {
    private actor CallCounter {
        private(set) var groupWrites = 0
        private(set) var lightWrites: [String: Int] = [:]
        private(set) var lastColor: HueColorCommand?
        func bumpGroup() { groupWrites += 1 }
        func bumpLight(_ id: String, color: HueColorCommand?) {
            lightWrites[id, default: 0] += 1
            if let color { lastColor = color }
        }
    }

    private let bridge = HueBridgeConfig(bridgeId: "B", bridgeIP: "10.0.0.1", applicationKey: "k")

    private func makeState() -> HouseReducer.State {
        let room = HueRoom(id: "1", name: "Living room", type: "Room", lightIds: ["1", "2"], anyOn: false, brightness: 100)
        // Light 1 is a full-color bulb so the color path applies.
        let l1 = HueLight(id: "1", name: "Lamp", isOn: false, brightness: 100,
                          colorMode: .hs, hue: 100, saturation: 100, supportsColor: true, supportsColorTemp: true)
        let l2 = HueLight(id: "2", name: "Ceiling", isOn: false, brightness: 100)
        let snap = BridgeSnapshot(bridge: bridge, rooms: [room], lights: [l1, l2])
        return HouseReducer.State(config: HueConfig(bridges: [bridge]), bridges: [snap])
    }

    private func countingClient(_ counter: CallCounter) -> HueClient {
        var client = HueClient.previewValue
        client.setGroupState = { _, _, _, _ in await counter.bumpGroup() }
        client.setLightState = { _, lightId, _, _, color in await counter.bumpLight(lightId, color: color) }
        return client
    }

    /// Five rapid room-slider events → zero writes while dragging, exactly one after 150ms of quiet.
    @Test func roomSliderSpamCollapsesToOneWrite() async {
        let clock = TestClock()
        let counter = CallCounter()
        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.continuousClock = clock
            $0.hue = countingClient(counter)
        }
        store.exhaustivity = .off

        for pct in [10.0, 25.0, 40.0, 60.0, 80.0] {
            await store.send(.roomBrightnessChanged(bridgeId: "B", roomId: "1", percent: pct))
        }
        // Still dragging — nothing has been written to the bridge yet.
        #expect(await counter.groupWrites == 0)

        await clock.advance(by: .milliseconds(150))
        await store.receive(\.commitRoomBrightness)
        await store.finish()

        // Exactly one PUT despite five slider deltas.
        #expect(await counter.groupWrites == 1)
    }

    /// A partial-advance proves the ≥150ms floor: at 149ms nothing has fired.
    @Test func roomSliderHoldsBelowDebounceFloor() async {
        let clock = TestClock()
        let counter = CallCounter()
        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.continuousClock = clock
            $0.hue = countingClient(counter)
        }
        store.exhaustivity = .off

        await store.send(.roomBrightnessChanged(bridgeId: "B", roomId: "1", percent: 50))
        await clock.advance(by: .milliseconds(149))
        #expect(await counter.groupWrites == 0)   // below the floor → no write

        await clock.advance(by: .milliseconds(1))  // now at 150ms
        await store.receive(\.commitRoomBrightness)
        await store.finish()
        #expect(await counter.groupWrites == 1)
    }

    /// Two different lights spammed concurrently keep independent debounce timers (per-light CancelID),
    /// so each still lands exactly one write — one slider never cancels another's.
    @Test func perLightDebounceIsIndependent() async {
        let clock = TestClock()
        let counter = CallCounter()
        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.continuousClock = clock
            $0.hue = countingClient(counter)
        }
        store.exhaustivity = .off

        for pct in [10.0, 30.0, 50.0] {
            await store.send(.lightBrightnessChanged(bridgeId: "B", lightId: "1", percent: pct))
            await store.send(.lightBrightnessChanged(bridgeId: "B", lightId: "2", percent: pct))
        }
        #expect(await counter.lightWrites.isEmpty)

        await clock.advance(by: .milliseconds(150))
        await store.receive(\.commitLightBrightness)
        await store.receive(\.commitLightBrightness)
        await store.finish()

        #expect(await counter.lightWrites["1"] == 1)
        #expect(await counter.lightWrites["2"] == 1)
    }

    /// Color/ct writes debounce on the same ≥150ms floor: a flurry of palette taps collapses to one PUT,
    /// carrying the LAST chosen color; and the light updates optimistically (colorMode + power-on).
    @Test func colorSpamCollapsesToOneWriteCarryingLastColor() async {
        let clock = TestClock()
        let counter = CallCounter()
        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.continuousClock = clock
            $0.hue = countingClient(counter)
        }
        store.exhaustivity = .off

        let colors: [HueColorCommand] = [
            .hueSat(hue: 0, saturation: 254),
            .hueSat(hue: 25500, saturation: 240),
            .colorTemp(mireds: 300),
        ]
        for c in colors {
            await store.send(.lightColorChanged(bridgeId: "B", lightId: "1", command: c))
        }
        #expect(await counter.lightWrites["1"] == nil)   // nothing written while tapping

        await clock.advance(by: .milliseconds(150))
        await store.receive(\.commitLightColor)
        await store.finish()

        #expect(await counter.lightWrites["1"] == 1)     // one PUT despite three taps
        #expect(await counter.lastColor == .colorTemp(mireds: 300))
    }
}
