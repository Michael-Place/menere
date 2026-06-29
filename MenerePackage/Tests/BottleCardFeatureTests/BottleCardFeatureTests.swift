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

    func testAddToCellarTappedPresentsFormWithUid() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Tester") }

            let store = TestStore(initialState: BottleCardFeature.State(wine: wine)) {
                BottleCardFeature()
            }
            // `BottleFormReducer.State.purchaseDate` defaults to a live `Date()`, so deep equality is
            // non-deterministic; assert the presented case + uid/wine instead.
            store.exhaustivity = .off
            await store.send(.addToCellarTapped)
            guard case let .addToCellar(formState) = store.state.destination else {
                return XCTFail("expected addToCellar destination")
            }
            XCTAssertEqual(formState.uid, "uid-1")
            XCTAssertEqual(formState.wine, wine)
        }
    }

    func testLogTastingTappedPresentsFormWithUid() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-2", displayName: "Taster") }

            let store = TestStore(initialState: BottleCardFeature.State(wine: wine)) {
                BottleCardFeature()
            }
            // Tapping only SETS destination — the form's `.task` fires when the view appears, not here,
            // so no child effects arrive at the parent store.
            await store.send(.logTastingTapped) {
                $0.destination = .logTasting(TastingFormReducer.State(wine: self.wine, uid: "uid-2"))
            }
        }
    }

    func testNoUidDoesNotPresent() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = nil }

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
                destination: .addToCellar(BottleFormReducer.State(wine: wine, uid: "uid-1"))
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
                destination: .logTasting(TastingFormReducer.State(wine: wine, uid: "uid-2"))
            )
            let store = TestStore(initialState: initial) {
                BottleCardFeature()
            }
            await store.send(.destination(.presented(.logTasting(.delegate(.cancelled))))) {
                $0.destination = nil
            }
        }
    }
}
