import ComposableArchitecture
import FamilyDomain
import LutronClient
import XCTest

@testable import SettingsFeature

/// `TestStore` walk of the Lutron pairing state machine (P15-C1): discover → single-bridge
/// auto-advance → 30s button-press poll (buttonNotPressed retries) → credential minted → config saved.
/// Mirrors `HuePairingReducerTests`; there is no binding step (shades are driven by zone id, no
/// scenes/sensors to bind).
@MainActor
final class LutronPairingReducerTests: XCTestCase {
    private let bridge = DiscoveredLutronBridge(id: "Caseta-1", ip: "192.168.1.50", name: "Caseta Smart Bridge")

    /// `pair` throws buttonNotPressed twice, then mints the credential on the third attempt.
    private actor Attempts { var n = 0; func bump() -> Int { n += 1; return n } }

    func testHappyPathPairsAndSaves() async {
        let clock = TestClock()
        let attempts = Attempts()
        let savedBox = LockIsolated<LutronConfig?>(nil)
        let bridge = self.bridge
        let result = LutronPairingResult(
            clientCertPEM: "CERT", clientKeyPEM: "KEY", bridgeCAPEM: "CA",
            bridgeId: "bridge-abc", bridgeName: "Caseta Smart Bridge"
        )

        let store = TestStore(initialState: LutronPairingReducer.State(hid: "hid-1")) {
            LutronPairingReducer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.lutron.discoverBridges = { [bridge] }
            $0.lutron.pair = { _ in
                if await attempts.bump() <= 2 { throw LutronError.buttonNotPressed }
                return result
            }
            $0.persistence.saveLutronConfig = { _, config in savedBox.setValue(config) }
        }

        await store.send(.task)
        await store.receive(\.bridgesDiscovered) { $0.bridges = [bridge] }
        await store.receive(\.bridgeSelected) {
            $0.selectedBridge = bridge
            $0.step = .linkButton
            $0.countdown = 30
        }
        // First poll → buttonNotPressed → tick (29), 1s sleep, poll again → still not pressed (28).
        await store.receive(\.pollPair)
        await store.receive(\.pollTick) { $0.countdown = 29 }
        await clock.advance(by: .seconds(1))
        await store.receive(\.pollPair)
        await store.receive(\.pollTick) { $0.countdown = 28 }
        await clock.advance(by: .seconds(1))
        // Third poll succeeds → paired → saving → saved → done.
        await store.receive(\.pollPair)
        await store.receive(\.paired) { $0.step = .saving }
        await store.receive(\.saved) { $0.step = .done }
        await clock.advance(by: .seconds(1.2))
        await store.receive(\.delegate)

        // The saved config carries the minted PEMs + bridge identity, no mock flag.
        let saved = savedBox.value
        XCTAssertEqual(saved?.bridgeIP, "192.168.1.50")
        XCTAssertEqual(saved?.bridgeId, "bridge-abc")
        XCTAssertEqual(saved?.clientCertPEM, "CERT")
        XCTAssertEqual(saved?.clientKeyPEM, "KEY")
        XCTAssertEqual(saved?.bridgeCAPEM, "CA")
        XCTAssertNil(saved?.mock)
    }

    func testCountdownExpiryFails() async {
        let clock = TestClock()
        let bridge = self.bridge

        let store = TestStore(initialState: LutronPairingReducer.State(hid: "hid-1", existingConfig: nil)) {
            LutronPairingReducer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.lutron.discoverBridges = { [bridge] }
            $0.lutron.pair = { _ in throw LutronError.buttonNotPressed }   // never pressed
        }

        await store.send(.task)
        await store.receive(\.bridgesDiscovered) { $0.bridges = [bridge] }
        await store.receive(\.bridgeSelected) {
            $0.selectedBridge = bridge
            $0.step = .linkButton
            $0.countdown = 30
        }
        // Walk the countdown to 0 (poll → tick, sleep, repeat). 30 ticks → failure at 0.
        await store.receive(\.pollPair)
        for n in stride(from: 29, through: 1, by: -1) {
            await store.receive(\.pollTick) { $0.countdown = n }
            await clock.advance(by: .seconds(1))
            await store.receive(\.pollPair)
        }
        await store.receive(\.pollTick) {
            $0.countdown = 0
            $0.step = .failed
            $0.errorMessage = "Didn't catch the button in time. Press it again and retry."
        }
    }
}
