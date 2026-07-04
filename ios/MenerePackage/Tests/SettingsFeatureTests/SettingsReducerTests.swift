import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import HouseholdClient
import PersistenceClient
import UserDomain
import WineDomain
import XCTest

@testable import SettingsFeature

/// `TestStore` coverage for the M7.2 household invite/join flow in Settings.
///
/// `@Shared(.user)` is fileStorage-backed, so each test pins `defaultFileStorage = .inMemory`
/// to stay hermetic and avoid touching the real user.json.
@MainActor
final class SettingsReducerTests: XCTestCase {
    // Pin `createdAt` so the `Household` value compares deterministically across the stub and assertion
    // (its default is a live `Date()`).
    private let fixedDate = Date(timeIntervalSince1970: 0)

    func testLoadHousehold() async {
        let fixedDate = self.fixedDate
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.persistence.household = { hid in
                Household(id: hid, ownerUid: "u", members: ["u"], inviteCode: "ABC123", createdAt: fixedDate)
            }
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "u", displayName: "Tester", householdId: "hid-1") }

            let store = TestStore(initialState: SettingsReducer.State()) {
                SettingsReducer()
            }

            await store.send(.task) {
                $0.isLoadingHousehold = true
            }
            await store.receive(.householdLoaded(Household(id: "hid-1", ownerUid: "u", members: ["u"], inviteCode: "ABC123", createdAt: fixedDate))) {
                $0.isLoadingHousehold = false
                $0.household = Household(id: "hid-1", ownerUid: "u", members: ["u"], inviteCode: "ABC123", createdAt: fixedDate)
            }
        }
    }

    func testJoinSuccess() async {
        let fixedDate = self.fixedDate
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.household.join = { _, _ in JoinOutcome(hid: "hid-2", unclaimed: []) }
            $0.persistence.household = { hid in
                Household(id: hid, ownerUid: "owner", members: ["owner", "u"], inviteCode: "ZZTOP9", createdAt: fixedDate)
            }
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "u", displayName: "Tester", householdId: nil) }

            let store = TestStore(initialState: SettingsReducer.State()) {
                SettingsReducer()
            }

            await store.send(.joinHouseholdTapped) {
                $0.joinCode = ""
                $0.joinError = nil
                $0.showJoinSheet = true
            }
            await store.send(.binding(.set(\.joinCode, "ZZTOP9"))) {
                $0.joinCode = "ZZTOP9"
            }
            await store.send(.submitJoinTapped) {
                $0.isJoining = true
                $0.joinError = nil
            }
            await store.receive(.joinResponse(.success(JoinOutcome(hid: "hid-2", unclaimed: [])))) {
                $0.isJoining = false
                $0.showJoinSheet = false
            }
            // Reload triggered by .send(.task).
            await store.receive(.task) {
                $0.isLoadingHousehold = true
            }
            await store.receive(.householdLoaded(Household(id: "hid-2", ownerUid: "owner", members: ["owner", "u"], inviteCode: "ZZTOP9", createdAt: fixedDate))) {
                $0.isLoadingHousehold = false
                $0.household = Household(id: "hid-2", ownerUid: "owner", members: ["owner", "u"], inviteCode: "ZZTOP9", createdAt: fixedDate)
            }

            // The shared user's householdId was updated by the success handler.
            XCTAssertEqual(user?.householdId, "hid-2")
        }
    }

    /// P18 — a code that resolves to a household with managed personas presents the "Which family
    /// member are you?" picker (rather than finalizing), and tapping a persona claims it.
    func testJoinPresentsClaimPickerThenClaims() async {
        let fixedDate = self.fixedDate
        let vale = ClaimablePersona(
            id: "vale-uuid", name: "Vale", fullName: "Valentina",
            color: .terracotta, avatarSystemName: "person.circle.fill"
        )
        let claimedId = LockIsolated<String?>(nil)
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.analytics.record = { _, _ in }
            $0.household.join = { _, claimMemberId in
                if let claimMemberId {
                    claimedId.setValue(claimMemberId)
                    return JoinOutcome(hid: "hid-2", unclaimed: [])
                }
                return JoinOutcome(hid: "hid-2", unclaimed: [vale])
            }
            $0.persistence.household = { hid in
                Household(id: hid, ownerUid: "owner", members: ["owner", "u"], inviteCode: "ZZTOP9", createdAt: fixedDate)
            }
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "u", displayName: "Tester", householdId: nil) }

            let store = TestStore(initialState: SettingsReducer.State()) { SettingsReducer() }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(.joinHouseholdTapped)
            await store.send(.binding(.set(\.joinCode, "ZZTOP9")))
            await store.send(.submitJoinTapped)
            await store.receive(.joinResponse(.success(JoinOutcome(hid: "hid-2", unclaimed: [vale])))) {
                $0.isJoining = false
                $0.joinedHid = "hid-2"
                $0.claimCandidates = [vale]
            }
            // Still in the sheet on the picker step — not finalized.
            XCTAssertTrue(store.state.showJoinSheet)

            await store.send(.claimPersonaTapped(vale)) { $0.isJoining = true }
            await store.receive(.claimResponse(.success("hid-2"))) {
                $0.isJoining = false
                $0.showJoinSheet = false
                $0.claimCandidates = []
                $0.joinedHid = nil
            }
            XCTAssertEqual(claimedId.value, "vale-uuid")
            XCTAssertEqual(user?.householdId, "hid-2")
        }
    }

    func testJoinFailure() async {
        struct JoinError: Error, LocalizedError {
            var errorDescription: String? { "No household found for that code" }
        }
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.household.join = { _, _ in throw JoinError() }
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "u", displayName: "Tester", householdId: nil) }

            let store = TestStore(initialState: SettingsReducer.State()) {
                SettingsReducer()
            }

            await store.send(.joinHouseholdTapped) {
                $0.showJoinSheet = true
            }
            await store.send(.binding(.set(\.joinCode, "BADCODE"))) {
                $0.joinCode = "BADCODE"
            }
            await store.send(.submitJoinTapped) {
                $0.isJoining = true
            }
            await store.receive(.joinResponse(.failure("No household found for that code"))) {
                $0.isJoining = false
                $0.joinError = "No household found for that code"
            }
            XCTAssertTrue(store.state.showJoinSheet)
        }
    }

    // MARK: - Smart-home RESET affordances (P15-C8)
    //
    // Each integration's Remove/Clear-demo-data flow must (a) gate on a confirmation dialog and
    // (b) delete the config doc + return the row to its set-up state.

    /// Builds a store with the shared user seeded to a household (the delete effects guard on it).
    private func makeStore(_ state: SettingsReducer.State) -> TestStoreOf<SettingsReducer> {
        @Shared(.user) var user
        $user.withLock { $0 = User(id: "u", displayName: "Tester", householdId: "hid-1") }
        return TestStore(initialState: state) { SettingsReducer() }
    }

    func testRemoveLutron() async {
        let deleted = LockIsolated(false)
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.persistence.deleteLutronConfig = { hid in
                XCTAssertEqual(hid, "hid-1"); deleted.setValue(true)
            }
        } operation: {
            var state = SettingsReducer.State()
            state.lutronConfig = LutronConfig(bridgeIP: "1.2.3.4", mock: true)
            state.lutronReachable = true
            let store = makeStore(state)

            await store.send(.removeLutronTapped) { $0.confirmingLutronRemove = true }
            await store.send(.confirmRemoveLutron) {
                $0.confirmingLutronRemove = false
                $0.lutronConfig = nil
                $0.lutronReachable = nil
            }
            XCTAssertTrue(deleted.value)
        }
    }

    func testRemoveNest() async {
        let deleted = LockIsolated(false)
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.persistence.deleteNestConfig = { _ in deleted.setValue(true) }
        } operation: {
            var state = SettingsReducer.State()
            state.nestConfig = NestConfig(projectId: "p", oauthClientId: "c", mock: true)
            state.nestThermostatCount = 2
            let store = makeStore(state)

            await store.send(.removeNestTapped) { $0.confirmingNestRemove = true }
            await store.send(.confirmRemoveNest) {
                $0.confirmingNestRemove = false
                $0.nestConfig = nil
                $0.nestThermostatCount = nil
            }
            XCTAssertTrue(deleted.value)
        }
    }

    func testRemoveHubspace() async {
        let deleted = LockIsolated(false)
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.persistence.deleteHubspaceConfig = { _ in deleted.setValue(true) }
        } operation: {
            var state = SettingsReducer.State()
            state.hubspaceConfig = HubspaceConfig(mock: true)
            state.hubspaceSpigotCount = 1
            let store = makeStore(state)

            await store.send(.removeHubspaceTapped) { $0.confirmingHubspaceRemove = true }
            await store.send(.confirmRemoveHubspace) {
                $0.confirmingHubspaceRemove = false
                $0.hubspaceConfig = nil
                $0.hubspaceSpigotCount = nil
            }
            XCTAssertTrue(deleted.value)
        }
    }

    func testRemoveMeross() async {
        let deleted = LockIsolated(false)
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.persistence.deleteMerossConfig = { _ in deleted.setValue(true) }
        } operation: {
            var state = SettingsReducer.State()
            state.merossConfig = MerossConfig(name: "Garage", mock: true)
            state.merossDoorCount = 1
            let store = makeStore(state)

            await store.send(.removeMerossTapped) { $0.confirmingMerossRemove = true }
            await store.send(.confirmRemoveMeross) {
                $0.confirmingMerossRemove = false
                $0.merossConfig = nil
                $0.merossDoorCount = nil
            }
            XCTAssertTrue(deleted.value)
        }
    }

    func testRemoveHomeKitDemo() async {
        let deleted = LockIsolated(false)
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.persistence.deleteHomeKitConfig = { _ in deleted.setValue(true) }
        } operation: {
            var state = SettingsReducer.State()
            state.homekitConfig = HomeKitConfig(mock: true)
            let store = makeStore(state)

            await store.send(.removeHomeKitTapped) { $0.confirmingHomeKitRemove = true }
            await store.send(.confirmRemoveHomeKit) {
                $0.confirmingHomeKitRemove = false
                $0.homekitConfig = nil
            }
            XCTAssertTrue(deleted.value)
        }
    }

    func testRemoveAllHue() async {
        let deleted = LockIsolated(false)
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.persistence.deleteHueConfig = { _ in deleted.setValue(true) }
        } operation: {
            var state = SettingsReducer.State()
            state.hueConfig = HueConfig(bridgeId: "ab12", bridgeIP: "1.2.3.4", applicationKey: "k", mock: true)
            state.hueBridgeReachable = ["ab12": true]
            let store = makeStore(state)

            await store.send(.removeAllHueTapped) { $0.confirmingHueRemoveAll = true }
            await store.send(.confirmRemoveAllHue) {
                $0.confirmingHueRemoveAll = false
                $0.hueConfig = nil
                $0.hueBridgeReachable = [:]
            }
            XCTAssertTrue(deleted.value)
        }
    }

    /// Removing the LAST Hue bridge deletes the whole config doc (rather than persisting an empty shell).
    func testRemoveLastHueBridgeDeletesDoc() async {
        let deleted = LockIsolated(false)
        let saved = LockIsolated(false)
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.persistence.deleteHueConfig = { _ in deleted.setValue(true) }
            $0.persistence.saveHueConfig = { _, _ in saved.setValue(true) }
        } operation: {
            let bridge = HueBridgeConfig(bridgeId: "ab12", bridgeIP: "1.2.3.4", applicationKey: "k")
            var state = SettingsReducer.State()
            state.hueConfig = HueConfig(bridges: [bridge])
            state.removingBridge = bridge
            let store = makeStore(state)

            await store.send(.confirmRemoveBridge("ab12")) {
                $0.removingBridge = nil
                $0.hueConfig = nil
            }
            XCTAssertTrue(deleted.value)
            XCTAssertFalse(saved.value)
        }
    }
}
