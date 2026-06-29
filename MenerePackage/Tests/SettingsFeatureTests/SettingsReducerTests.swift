import ComposableArchitecture
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
            $0.household.join = { _ in "hid-2" }
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
            await store.receive(.joinResponse(.success("hid-2"))) {
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

    func testJoinFailure() async {
        struct JoinError: Error, LocalizedError {
            var errorDescription: String? { "No household found for that code" }
        }
        await withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.household.join = { _ in throw JoinError() }
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
}
