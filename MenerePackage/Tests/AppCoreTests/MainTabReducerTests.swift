import CellarFeature
import ComposableArchitecture
import HomeFeature
import WineDomain
import XCTest

@testable import AppCore

/// `TestStore` coverage for `MainTabReducer`'s cross-tab routing: child `.delegate` actions
/// bubble up to switch the selected tab, and Home stat-tile deep-links additionally drive a
/// `.cellar(.applyPreset)` to preset the Cellar tab's segment + status filter.
///
/// Child Scopes run first (delegate handlers return `.none`, no `.task`), so the only effect to
/// drain is the parent-emitted `.cellar(.applyPreset)` on the openCellar path.
@MainActor
final class MainTabReducerTests: XCTestCase {
    func testHomeRequestScanSwitchesToScanTab() async {
        let store = TestStore(initialState: MainTabReducer.State()) {
            MainTabReducer()
        }

        await store.send(.home(.delegate(.requestScan))) {
            $0.selectedTab = .scan
        }
    }

    func testCellarRequestScanSwitchesToScanTab() async {
        let store = TestStore(initialState: MainTabReducer.State()) {
            MainTabReducer()
        }

        await store.send(.cellar(.delegate(.requestScan))) {
            $0.selectedTab = .scan
        }
    }

    func testHomeOpenCellarWishlistSwitchesTabAndPresets() async {
        let store = TestStore(initialState: MainTabReducer.State()) {
            MainTabReducer()
        }

        await store.send(.home(.delegate(.openCellar(.wishlist)))) {
            $0.selectedTab = .cellar
        }

        await store.receive(.cellar(.applyPreset(segment: .cellar, statusFilter: .wishlist))) {
            $0.cellar.segment = .cellar
            $0.cellar.statusFilter = .wishlist
            $0.cellar.searchText = ""
        }
    }

    func testHomeOpenCellarTastingsSwitchesToHistory() async {
        let store = TestStore(initialState: MainTabReducer.State()) {
            MainTabReducer()
        }

        await store.send(.home(.delegate(.openCellar(.tastings)))) {
            $0.selectedTab = .cellar
        }

        await store.receive(.cellar(.applyPreset(segment: .history, statusFilter: nil))) {
            $0.cellar.segment = .history
        }
    }
}
