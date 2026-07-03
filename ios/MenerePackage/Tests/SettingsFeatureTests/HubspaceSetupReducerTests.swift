import ComposableArchitecture
import FamilyDomain
import HubspaceClient
import XCTest

@testable import SettingsFeature

/// `TestStore` walk of the Hubspace water-timer setup state machine (P15-C4): sign in with email +
/// password → capture the refresh token + account id → save the config → connected.
///
/// The centerpiece is `testLoginSucceedsButProbeFailsStaysConnectedWithSoftNote` — the regression for
/// the **"failed-but-connected"** bug Michael hit: his real login + config save succeeded, but the
/// post-login device probe threw (Little Snitch was still blocking the sim's Hubspace cloud calls) and
/// the old flow conflated that with a bad-password failure, showing the failure screen even though the
/// account was saved and connected. The fix: login+save is the source of truth for "connected"; a
/// post-login probe failure degrades to a soft note, never the failure screen.
@MainActor
final class HubspaceSetupReducerTests: XCTestCase {
    private let tokens = HubspaceTokens(refreshToken: "refresh-xyz", accountId: "acct-42")

    private func filledStore(
        clock: TestClock<Duration>,
        savedBox: LockIsolated<HubspaceConfig?>,
        configure: (inout DependencyValues) -> Void
    ) -> TestStoreOf<HubspaceSetupReducer> {
        let store = TestStore(initialState: HubspaceSetupReducer.State(hid: "hid-1")) {
            HubspaceSetupReducer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.persistence.saveHubspaceConfig = { _, config in savedBox.setValue(config) }
            configure(&$0)
        }
        return store
    }

    /// Happy path: login + save + a clean device probe → connected, no soft note, config persisted.
    func testHappyPathConnectsWithoutNote() async {
        let clock = TestClock()
        let savedBox = LockIsolated<HubspaceConfig?>(nil)
        let store = filledStore(clock: clock, savedBox: savedBox) {
            $0.hubspace.login = { _, _ in self.tokens }
            $0.hubspace.spigots = { _ in [HubspaceFixtures.frontYard] }   // probe reaches the spigot
        }

        await store.send(.binding(.set(\.email, "me@example.com"))) { $0.email = "me@example.com" }
        await store.send(.binding(.set(\.password, "secret"))) { $0.password = "secret" }

        await store.send(.connectTapped) { $0.step = .connecting }

        let expected = HubspaceConfig(refreshToken: "refresh-xyz", accountId: "acct-42", email: "me@example.com", mock: nil)
        await store.receive(\.connected) {
            $0.step = .done
            $0.softNote = nil
            $0.password = ""
        }
        XCTAssertEqual(savedBox.value, expected)   // config persisted (never the password)

        await clock.advance(by: .seconds(1.2))
        await store.receive(.delegate(.finished(expected)))
    }

    /// THE REGRESSION: login succeeds, config is saved, but the post-login spigot probe throws. The old
    /// flow showed the failure screen; the fix keeps us on the success screen with a soft note, and still
    /// dismisses via `delegate.finished`. Config is persisted; step is `.done`, never `.failed`.
    func testLoginSucceedsButProbeFailsStaysConnectedWithSoftNote() async {
        let clock = TestClock()
        let savedBox = LockIsolated<HubspaceConfig?>(nil)
        let store = filledStore(clock: clock, savedBox: savedBox) {
            $0.hubspace.login = { _, _ in self.tokens }
            $0.hubspace.spigots = { _ in throw HubspaceError.requestFailed }   // firewall still settling
        }

        await store.send(.binding(.set(\.email, "me@example.com"))) { $0.email = "me@example.com" }
        await store.send(.binding(.set(\.password, "secret"))) { $0.password = "secret" }

        await store.send(.connectTapped) { $0.step = .connecting }

        await store.receive(\.connected) {
            $0.step = .done            // connected, NOT .failed
            $0.password = ""
            $0.softNote = "Signed in — but Bacán couldn't reach your spigot just now. It'll show up on Today once it's back online."
        }
        // Connected means the config was saved — the token is real and persisted.
        XCTAssertEqual(savedBox.value?.refreshToken, "refresh-xyz")
        XCTAssertEqual(savedBox.value?.accountId, "acct-42")
        XCTAssertNil(savedBox.value?.mock)

        // Still dismisses (a longer linger so the note can be read).
        let expected = HubspaceConfig(refreshToken: "refresh-xyz", accountId: "acct-42", email: "me@example.com", mock: nil)
        await clock.advance(by: .seconds(2.4))
        await store.receive(.delegate(.finished(expected)))
    }

    /// A rejected password (`.invalidCredentials`) → the failure screen with the "check your
    /// email/password" copy, and NOTHING is persisted. This is the case that SHOULD show a credential
    /// failure — the contrast with the probe case above.
    func testInvalidCredentialsShowsFailedAndPersistsNothing() async {
        let clock = TestClock()
        let savedBox = LockIsolated<HubspaceConfig?>(nil)
        let store = filledStore(clock: clock, savedBox: savedBox) {
            $0.hubspace.login = { _, _ in throw HubspaceError.invalidCredentials }
        }

        await store.send(.binding(.set(\.email, "me@example.com"))) { $0.email = "me@example.com" }
        await store.send(.binding(.set(\.password, "wrong"))) { $0.password = "wrong" }

        await store.send(.connectTapped) { $0.step = .connecting }

        await store.receive(\.connectFailed) {
            $0.step = .failed
            $0.password = ""
            $0.errorMessage = "Couldn't sign in to Hubspace. Double-check your email and password and try again."
        }
        XCTAssertNil(savedBox.value)   // never persisted a thing
    }

    /// A flow break (`.loginFailed` — couldn't reach/parse Keycloak) must NOT masquerade as a wrong
    /// password: it surfaces the connectivity copy instead, and still persists nothing.
    func testLoginFlowBreakShowsConnectivityMessage() async {
        let clock = TestClock()
        let savedBox = LockIsolated<HubspaceConfig?>(nil)
        let store = filledStore(clock: clock, savedBox: savedBox) {
            $0.hubspace.login = { _, _ in throw HubspaceError.loginFailed }
        }

        await store.send(.binding(.set(\.email, "me@example.com"))) { $0.email = "me@example.com" }
        await store.send(.binding(.set(\.password, "pw"))) { $0.password = "pw" }

        await store.send(.connectTapped) { $0.step = .connecting }

        await store.receive(\.connectFailed) {
            $0.step = .failed
            $0.password = ""
            $0.errorMessage = "Couldn't reach Hubspace to sign in. Check your connection and try again."
        }
        XCTAssertNil(savedBox.value)
    }
}
