import ComposableArchitecture
import FamilyDomain
import LutronClient
import XCTest

@testable import SettingsFeature

/// `TestStore` walk of the Lutron pairing state machine (P15-C1, corrected): discover → single-bridge
/// auto-advance → ONE long-lived LAP button-press handshake → credential minted → config saved. The
/// old poll-loop (reconnect-per-second) was replaced: the transport now holds one socket open for the
/// whole window (a reconnect drops the button-press status push), and the reducer distinguishes
/// "button not pressed in time" from "couldn't reach the bridge" for failure surfacing.
@MainActor
final class LutronPairingReducerTests: XCTestCase {
    private let bridge = DiscoveredLutronBridge(id: "Caseta-1", ip: "192.168.1.50", name: "Caseta Smart Bridge")

    /// Single pairing call succeeds → paired → saving → saved → done, and the config carries the minted
    /// PEMs + bridge identity with no mock flag.
    func testHappyPathPairsAndSaves() async {
        let clock = TestClock()
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
            $0.lutron.pair = { _ in result }
            $0.persistence.saveLutronConfig = { _, config in savedBox.setValue(config) }
        }

        await store.send(.task)
        await store.receive(\.bridgesDiscovered) { $0.bridges = [bridge] }
        await store.receive(\.bridgeSelected) {
            $0.selectedBridge = bridge
            $0.step = .linkButton
            $0.countdown = 30
        }
        await store.receive(\.startPairing)
        await store.receive(\.paired) { $0.step = .saving }
        await store.receive(\.saved) { $0.step = .done }
        await clock.advance(by: .seconds(1.2))
        await store.receive(\.delegate)

        let saved = savedBox.value
        XCTAssertEqual(saved?.bridgeIP, "192.168.1.50")
        XCTAssertEqual(saved?.bridgeId, "bridge-abc")
        XCTAssertEqual(saved?.clientCertPEM, "CERT")
        XCTAssertEqual(saved?.clientKeyPEM, "KEY")
        XCTAssertEqual(saved?.bridgeCAPEM, "CA")
        XCTAssertNil(saved?.mock)
    }

    /// The socket connected but the button was never pressed (transport throws `buttonNotPressed`) →
    /// the flow fails with the "we reached your bridge but didn't see the press" guidance.
    func testButtonWindowExpiresSurfacesButtonMessage() async {
        let clock = TestClock()
        let bridge = self.bridge

        let store = TestStore(initialState: LutronPairingReducer.State(hid: "hid-1")) {
            LutronPairingReducer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.lutron.discoverBridges = { [bridge] }
            $0.lutron.pair = { _ in throw LutronError.buttonNotPressed }
        }

        await store.send(.task)
        await store.receive(\.bridgesDiscovered) { $0.bridges = [bridge] }
        await store.receive(\.bridgeSelected) {
            $0.selectedBridge = bridge
            $0.step = .linkButton
            $0.countdown = 30
        }
        await store.receive(\.startPairing)
        await store.receive(\.pairWindowExpired) {
            $0.step = .failed
            $0.errorMessage = "We reached your bridge, but didn't see the button press in time. Press the small black button on the back of the bridge, then tap Try again."
        }
    }

    /// A connect/TLS failure (any non-`buttonNotPressed` error) surfaces the distinct "couldn't reach
    /// your bridge" message — so Michael can tell a socket problem apart from a missed button.
    func testConnectFailureSurfacesSocketMessage() async {
        let clock = TestClock()
        let bridge = self.bridge

        let store = TestStore(initialState: LutronPairingReducer.State(hid: "hid-1")) {
            LutronPairingReducer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.lutron.discoverBridges = { [bridge] }
            $0.lutron.pair = { _ in throw LutronError.networkError("tls handshake failed") }
        }

        await store.send(.task)
        await store.receive(\.bridgesDiscovered) { $0.bridges = [bridge] }
        await store.receive(\.bridgeSelected) {
            $0.selectedBridge = bridge
            $0.step = .linkButton
            $0.countdown = 30
        }
        await store.receive(\.startPairing)
        await store.receive(\.pairingFailed) {
            $0.step = .failed
            $0.errorMessage = "Couldn't reach your Lutron bridge to pair. Make sure your phone is on your home Wi-Fi (not cellular or guest), then tap Try again."
        }
    }

    /// The visual countdown decrements once per second and clamps at 0.
    func testCountdownTickDecrementsAndClamps() async {
        let store = TestStore(initialState: {
            var s = LutronPairingReducer.State(hid: "hid-1")
            s.step = .linkButton
            s.countdown = 2
            return s
        }()) {
            LutronPairingReducer()
        } withDependencies: {
            $0.continuousClock = TestClock()
        }

        await store.send(.countdownTick) { $0.countdown = 1 }
        await store.send(.countdownTick) { $0.countdown = 0 }
        await store.send(.countdownTick)   // clamped at 0 — no state change
    }
}
