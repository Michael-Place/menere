import ComposableArchitecture
import FamilyDomain
import HueClient
import MerossClient
import Testing

@testable import TodayFeature

/// Locks the P15-C5 Meross/Refoss garage verbs on `HouseReducer`, centered on the security contract:
/// **opening REQUIRES a confirmation** (routes through `confirmingGarageOpen` → `confirmGarageOpen`),
/// while **closing commits directly**. Also covers the ~20s settling state ("Opening…") and its re-read,
/// and the silent degrade on a failed write.
@MainActor
struct HouseReducerMerossTests {
    private actor SetRecorder {
        private(set) var calls: [(Int, Bool)] = []
        func record(_ channel: Int, _ open: Bool) { calls.append((channel, open)) }
        var count: Int { calls.count }
        var last: (Int, Bool)? { calls.last }
    }

    private let bridge = HueBridgeConfig(bridgeId: "B", bridgeIP: "10.0.0.1", applicationKey: "k")

    private func makeState() -> HouseReducer.State {
        HouseReducer.State(
            config: HueConfig(bridges: [bridge]), bridges: [],
            merossConfig: MerossConfig(deviceIP: "10.0.0.9", deviceKey: "K", uuid: "U", name: "Garage", mock: true),
            garageDoors: [GarageDoor(channel: 0, name: "Garage", isOpen: false)]   // closed
        )
    }

    /// OPENING is gated: the tap only arms the confirmation — it does NOT actuate. Confirming then flips
    /// the door optimistically, shows "Opening…", and fires exactly one setGarage(open: true).
    @Test func openRequiresConfirmationThenCommits() async {
        let recorder = SetRecorder()
        let clock = TestClock()
        var client = MerossClient.previewValue
        client.setGarage = { _, channel, open in await recorder.record(channel, open) }
        client.garageState = { _ in [GarageDoor(channel: 0, name: "Garage", isOpen: true)] }

        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.meross = client
            $0.continuousClock = clock
        }
        store.exhaustivity = .off

        // Tap "Open" → only arms the dialog; NO setGarage yet.
        await store.send(.garageOpenRequested(channel: 0))
        #expect(store.state.confirmingGarageOpen == 0)
        #expect(await recorder.count == 0)   // NOT actuated on the tap

        // Confirm → routes to the shared commit (optimistic open + settling + one write).
        await store.send(.confirmGarageOpen)
        #expect(store.state.confirmingGarageOpen == nil)
        await store.receive(\.commitGarage)
        #expect(store.state.garageDoors[0].isOpen == true)                 // optimistic
        #expect(store.state.garageSettling[0] == .opening)                 // "Opening…"

        // The ~20s settle → clears settling, re-reads truth.
        await clock.advance(by: .seconds(20))
        await store.receive(\.garageSettleElapsed)
        await store.receive(\.garagePoll)
        await store.receive(\.garageReloaded)
        #expect(store.state.garageSettling[0] == nil)

        await store.finish()
        #expect(await recorder.count == 1)
        let last = await recorder.last!
        #expect(last.0 == 0)
        #expect(last.1 == true)
    }

    /// Cancelling the confirmation actuates nothing.
    @Test func cancelOpenDoesNothing() async {
        let recorder = SetRecorder()
        var client = MerossClient.previewValue
        client.setGarage = { _, channel, open in await recorder.record(channel, open) }

        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.meross = client
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off

        await store.send(.garageOpenRequested(channel: 0))
        await store.send(.cancelGarageOpen)
        #expect(store.state.confirmingGarageOpen == nil)
        #expect(store.state.garageDoors[0].isOpen == false)   // untouched
        await store.finish()
        #expect(await recorder.count == 0)
    }

    /// CLOSING is NOT gated: the tap commits directly (closing is safe), flips optimistically, shows
    /// "Closing…", and fires one setGarage(open: false). No confirmation state is ever set.
    @Test func closeCommitsDirectlyWithoutConfirmation() async {
        let recorder = SetRecorder()
        let clock = TestClock()
        var client = MerossClient.previewValue
        client.setGarage = { _, channel, open in await recorder.record(channel, open) }
        client.garageState = { _ in [GarageDoor(channel: 0, name: "Garage", isOpen: false)] }

        // Start from an OPEN door so "Close" is the action.
        var state = makeState()
        state.garageDoors = [GarageDoor(channel: 0, name: "Garage", isOpen: true)]

        let store = TestStore(initialState: state) { HouseReducer() } withDependencies: {
            $0.meross = client
            $0.continuousClock = clock
        }
        store.exhaustivity = .off

        await store.send(.garageCloseRequested(channel: 0))
        #expect(store.state.confirmingGarageOpen == nil)   // NEVER armed for a close
        await store.receive(\.commitGarage)                // commits directly (no confirmation)
        #expect(store.state.garageDoors[0].isOpen == false)  // optimistic close
        #expect(store.state.garageSettling[0] == .closing)   // "Closing…"

        await clock.advance(by: .seconds(20))
        await store.receive(\.garageSettleElapsed)
        await store.receive(\.garagePoll)
        await store.receive(\.garageReloaded)
        #expect(store.state.garageSettling[0] == nil)

        await store.finish()
        #expect(await recorder.count == 1)
        #expect(await recorder.last?.1 == false)
    }

    /// A failed write restores truth immediately (settle-elapsed → poll → reload), never surfacing an
    /// error. The optimistic open is corrected back to closed.
    @Test func failedWriteRestoresTruthSilently() async {
        var client = MerossClient.previewValue
        client.setGarage = { _, _, _ in throw MerossError.requestFailed }
        client.garageState = { _ in [GarageDoor(channel: 0, name: "Garage", isOpen: false)] }   // true = closed

        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.meross = client
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off

        await store.send(.garageOpenRequested(channel: 0))
        await store.send(.confirmGarageOpen)
        await store.receive(\.commitGarage)
        #expect(store.state.garageDoors[0].isOpen == true)   // optimistic

        // Write throws → immediate settle-elapsed → poll → reload restores closed.
        await store.receive(\.garageSettleElapsed)
        await store.receive(\.garagePoll)
        await store.receive(\.garageReloaded)
        #expect(store.state.garageDoors[0].isOpen == false)   // corrected
        #expect(store.state.garageSettling[0] == nil)
        await store.finish()
    }
}
