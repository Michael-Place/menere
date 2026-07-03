import ComposableArchitecture
import FamilyDomain
import HubspaceClient
import HueClient
import Testing

@testable import TodayFeature

/// Locks the P15-C4 Hubspace verbs on `HouseReducer`: opening an outlet with a timed run flips state
/// optimistically and fires exactly one `setSpigot`; closing does likewise; a failed write silently
/// re-reads (`waterPoll`) to restore truth. Mirrors the degrade-silently contract of the other
/// ecosystems.
@MainActor
struct HouseReducerHubspaceTests {
    private actor SetRecorder {
        private(set) var calls: [(String, Bool, Int?)] = []
        func record(_ instance: String, _ open: Bool, _ minutes: Int?) { calls.append((instance, open, minutes)) }
        var count: Int { calls.count }
        var last: (String, Bool, Int?)? { calls.last }
    }

    private let bridge = HueBridgeConfig(bridgeId: "B", bridgeIP: "10.0.0.1", applicationKey: "k")
    private var deviceId: String { HubspaceFixtures.frontYardId }

    private func makeState() -> HouseReducer.State {
        HouseReducer.State(
            config: HueConfig(bridges: [bridge]), bridges: [],
            hubspaceConfig: HubspaceConfig(refreshToken: "R", accountId: "A", email: "me@x.com", mock: true),
            spigots: [HubspaceFixtures.frontYard]   // spigot-1 closed, spigot-2 open 12m
        )
    }

    /// Opening "Garden beds" (spigot-1) for 10 minutes flips it open locally before the write lands, and
    /// fires exactly one setSpigot(open, 10).
    @Test func openOutletWithDurationIsOptimisticAndCommitsOnce() async {
        let recorder = SetRecorder()
        var client = HubspaceClient.previewValue
        client.setSpigot = { _, _, instance, open, minutes in await recorder.record(instance, open, minutes) }

        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.hubspace = client
        }
        store.exhaustivity = .off

        await store.send(.toggleSpigot(deviceId: deviceId, instance: "spigot-1", open: true, durationMinutes: 10))
        // Optimistic: spigot-1 now open with 10 min remaining.
        let one = store.state.spigots[0].outlets.first { $0.instance == "spigot-1" }!
        #expect(one.isOpen == true)
        #expect(one.remainingMinutes == 10)

        await store.finish()
        #expect(await recorder.count == 1)
        let last = await recorder.last!
        #expect(last.0 == "spigot-1")
        #expect(last.1 == true)
        #expect(last.2 == 10)
    }

    /// Closing "Drip line" (spigot-2) flips it closed locally and clears its remaining time.
    @Test func closeOutletIsOptimistic() async {
        let recorder = SetRecorder()
        var client = HubspaceClient.previewValue
        client.setSpigot = { _, _, instance, open, minutes in await recorder.record(instance, open, minutes) }

        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.hubspace = client
        }
        store.exhaustivity = .off

        await store.send(.toggleSpigot(deviceId: deviceId, instance: "spigot-2", open: false, durationMinutes: nil))
        let two = store.state.spigots[0].outlets.first { $0.instance == "spigot-2" }!
        #expect(two.isOpen == false)
        #expect(two.remainingMinutes == nil)

        await store.finish()
        #expect(await recorder.count == 1)
        #expect(await recorder.last?.1 == false)
    }

    /// A failed write silently re-reads (`waterPoll`) to restore truth — no error is surfaced.
    @Test func failedWriteReReadsSilently() async {
        var client = HubspaceClient.previewValue
        client.setSpigot = { _, _, _, _, _ in throw HubspaceError.requestFailed }
        client.spigots = { _ in [HubspaceFixtures.frontYard] }   // truth on re-read

        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.hubspace = client
        }
        store.exhaustivity = .off

        await store.send(.toggleSpigot(deviceId: deviceId, instance: "spigot-1", open: true, durationMinutes: 15))
        await store.receive(\.waterPoll)          // silent truth-restore
        await store.receive(\.spigotsReloaded)
        await store.finish()
        // Re-read restored spigot-1 to its true (closed) state.
        #expect(store.state.spigots[0].outlets.first { $0.instance == "spigot-1" }?.isOpen == false)
    }
}
