import ComposableArchitecture
import FamilyDomain
import MerossClient
import XCTest

@testable import SettingsFeature

/// `TestStore` walk of the Meross/Refoss garage setup state machine (P15-C5): enter the opener's IP +
/// device key → validate via `Appliance.System.All` → capture uuid + name → save the config → connected.
/// An unreachable IP / wrong key → the failure screen, nothing persisted.
@MainActor
final class MerossSetupReducerTests: XCTestCase {
    private let info = MerossDeviceInfo(
        uuid: "UUID-1", type: "msg100", name: nil,
        channels: [GarageDoor(channel: 0, name: nil, isOpen: false)]
    )

    /// Happy path: reachable IP + accepted key → device info fetched → config saved → connected. The
    /// name falls back to the channel's default ("Garage") when the device reports none.
    func testConnectSavesConfigAndFinishes() async {
        let clock = TestClock()
        let savedBox = LockIsolated<MerossConfig?>(nil)
        let store = TestStore(initialState: MerossSetupReducer.State(hid: "hid-1")) {
            MerossSetupReducer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.meross.deviceInfo = { _, _ in self.info }
            $0.persistence.saveMerossConfig = { _, config in savedBox.setValue(config) }
        }

        await store.send(.binding(.set(\.deviceIP, "192.168.1.42"))) { $0.deviceIP = "192.168.1.42" }
        await store.send(.binding(.set(\.deviceKey, "secret"))) { $0.deviceKey = "secret" }

        await store.send(.connectTapped) { $0.step = .connecting }

        let expected = MerossConfig(deviceIP: "192.168.1.42", deviceKey: "secret", uuid: "UUID-1", name: "Garage", mock: nil)
        await store.receive(\.connected) { $0.step = .done }
        XCTAssertEqual(savedBox.value, expected)

        await clock.advance(by: .seconds(1.2))
        await store.receive(.delegate(.finished(expected)))
    }

    /// A keyless device: an empty key still connects (some Meross/Refoss units accept it). The IP alone
    /// enables Connect.
    func testEmptyKeyStillConnects() async {
        let clock = TestClock()
        let savedBox = LockIsolated<MerossConfig?>(nil)
        let store = TestStore(initialState: MerossSetupReducer.State(hid: "hid-1")) {
            MerossSetupReducer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.meross.deviceInfo = { _, _ in self.info }
            $0.persistence.saveMerossConfig = { _, config in savedBox.setValue(config) }
        }

        await store.send(.binding(.set(\.deviceIP, "10.0.0.9"))) { $0.deviceIP = "10.0.0.9" }
        XCTAssertTrue(store.state.canConnect)   // IP alone enables Connect

        await store.send(.connectTapped) { $0.step = .connecting }
        await store.receive(\.connected) { $0.step = .done }
        XCTAssertEqual(savedBox.value?.deviceKey, "")

        await clock.advance(by: .seconds(1.2))
        await store.receive(\.delegate)
    }

    /// An unreachable opener / wrong key → deviceInfo throws → failure screen, nothing persisted.
    func testUnreachableShowsFailedAndPersistsNothing() async {
        let savedBox = LockIsolated<MerossConfig?>(nil)
        let store = TestStore(initialState: MerossSetupReducer.State(hid: "hid-1")) {
            MerossSetupReducer()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.meross.deviceInfo = { _, _ in throw MerossError.requestFailed }
            $0.persistence.saveMerossConfig = { _, config in savedBox.setValue(config) }
        }

        await store.send(.binding(.set(\.deviceIP, "10.0.0.99"))) { $0.deviceIP = "10.0.0.99" }
        await store.send(.binding(.set(\.deviceKey, "bad"))) { $0.deviceKey = "bad" }

        await store.send(.connectTapped) { $0.step = .connecting }
        await store.receive(\.connectFailed) {
            $0.step = .failed
            $0.errorMessage = "Couldn't reach the opener. Check the IP address and device key, and that your phone is on the home Wi-Fi."
        }
        XCTAssertNil(savedBox.value)
    }
}
