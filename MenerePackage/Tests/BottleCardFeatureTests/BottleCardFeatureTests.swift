import ComposableArchitecture
import JournalFeature
import UserDomain
import WineDomain
import XCTest

@testable import BottleCardFeature

/// `TestStore` coverage for the M5 journaling wiring on the bottle card: tapping the action buttons
/// reads the signed-in uid from `@Shared(.user)` and presents the matching form; the form's
/// `delegate` (saved or cancelled) dismisses the presented destination.
///
/// `@Shared(.user)` is fileStorage-backed, so each test pins `defaultFileStorage = .inMemory` to stay
/// hermetic and avoid touching the real user.json.
@MainActor
final class BottleCardFeatureTests: XCTestCase {
    private let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)

    func testAddToCellarTappedPresentsFormWithHid() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Tester", householdId: "hid-1") }

            let store = TestStore(initialState: BottleCardFeature.State(wine: wine)) {
                BottleCardFeature()
            }
            // `BottleFormReducer.State.purchaseDate` defaults to a live `Date()`, so deep equality is
            // non-deterministic; assert the presented case + hid/wine instead.
            store.exhaustivity = .off
            await store.send(.addToCellarTapped)
            guard case let .addToCellar(formState) = store.state.destination else {
                return XCTFail("expected addToCellar destination")
            }
            XCTAssertEqual(formState.hid, "hid-1")
            XCTAssertEqual(formState.wine, wine)
        }
    }

    func testLogTastingTappedPresentsFormWithHidAndUid() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-2", displayName: "Taster", householdId: "hid-2") }

            let store = TestStore(initialState: BottleCardFeature.State(wine: wine)) {
                BottleCardFeature()
            }
            // Tapping only SETS destination — the form's `.task` fires when the view appears, not here,
            // so no child effects arrive at the parent store.
            await store.send(.logTastingTapped) {
                $0.destination = .logTasting(TastingFormReducer.State(wine: self.wine, hid: "hid-2", uid: "uid-2"))
            }
        }
    }

    func testNoHouseholdIdDoesNotPresent() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            // User present but householdId nil → neither action presents a form.
            $user.withLock { $0 = User(id: "uid-1", displayName: "Tester", householdId: nil) }

            let store = TestStore(initialState: BottleCardFeature.State(wine: wine)) {
                BottleCardFeature()
            }
            await store.send(.addToCellarTapped)
            await store.send(.logTastingTapped)
        }
    }

    func testAddToCellarSavedDismisses() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let initial = BottleCardFeature.State(
                wine: wine,
                destination: .addToCellar(BottleFormReducer.State(wine: wine, hid: "hid-1"))
            )
            let store = TestStore(initialState: initial) {
                BottleCardFeature()
            }
            let bottle = Bottle(id: "b-1", wineId: wine.id)
            await store.send(.destination(.presented(.addToCellar(.delegate(.saved(bottle)))))) {
                $0.destination = nil
            }
        }
    }

    func testLogTastingCancelledDismisses() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            let initial = BottleCardFeature.State(
                wine: wine,
                destination: .logTasting(TastingFormReducer.State(wine: wine, hid: "hid-2", uid: "uid-2"))
            )
            let store = TestStore(initialState: initial) {
                BottleCardFeature()
            }
            await store.send(.destination(.presented(.logTasting(.delegate(.cancelled))))) {
                $0.destination = nil
            }
        }
    }

    // MARK: Owned mode

    /// Scan path: constructing from a bare `Wine` leaves `ownedBottle` nil (Add-to-cellar present).
    func testScanPathLeavesOwnedBottleNil() {
        let state = BottleCardFeature.State(wine: wine)
        XCTAssertNil(state.ownedBottle)
    }

    /// Owned path: constructing with an `ownedBottle` carries it; Log-a-tasting still presents its form
    /// (only Add-to-cellar is suppressed, and that's view-side).
    func testOwnedStateCarriesBottleAndLogTastingStillPresents() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-3", displayName: "Owner", householdId: "hid-3") }

            let bottle = Bottle(id: "b-owned", wineId: wine.id, quantity: 3)
            let state = BottleCardFeature.State(wine: wine, ownedBottle: bottle)
            XCTAssertEqual(state.ownedBottle, bottle)

            let store = TestStore(initialState: state) {
                BottleCardFeature()
            }
            await store.send(.logTastingTapped) {
                $0.destination = .logTasting(TastingFormReducer.State(wine: self.wine, hid: "hid-3", uid: "uid-3"))
            }
        }
    }
}
