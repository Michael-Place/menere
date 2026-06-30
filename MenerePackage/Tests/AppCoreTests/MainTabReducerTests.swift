import CellarFeature
import ComposableArchitecture
import WineDomain
import XCTest

@testable import AppCore

/// `TestStore` coverage for `MainTabReducer`'s cross-tab routing: child `.delegate` actions
/// bubble up to switch the selected tab.
///
/// Child Scopes run first (delegate handlers return `.none`, no `.task`), so there are no
/// additional effects to drain on the request-scan path.
@MainActor
final class MainTabReducerTests: XCTestCase {
    func testCellarRequestScanSwitchesToScanTab() async {
        let store = TestStore(initialState: MainTabReducer.State()) {
            MainTabReducer()
        }

        await store.send(.cellar(.delegate(.requestScan))) {
            $0.selectedTab = .scan
        }
    }
}
