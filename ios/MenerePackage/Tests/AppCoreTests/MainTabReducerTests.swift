import ComposableArchitecture
import XCTest

@testable import AppCore

/// `TestStore` coverage for `MainTabReducer`'s shell routing: tab selection and the Family
/// (settings) sheet toggle. The wine/scan flow now lives in `ListsReducer`, not here.
@MainActor
final class MainTabReducerTests: XCTestCase {
    func testTabSelectionUpdatesSelectedTab() async {
        let store = TestStore(initialState: MainTabReducer.State()) {
            MainTabReducer()
        }

        await store.send(.tabSelected(.recipes)) {
            $0.selectedTab = .recipes
        }
    }

    func testFamilySheetTogglesViaBinding() async {
        let store = TestStore(initialState: MainTabReducer.State()) {
            MainTabReducer()
        }

        await store.send(.binding(.set(\.showSettings, true))) {
            $0.showSettings = true
        }
    }
}
