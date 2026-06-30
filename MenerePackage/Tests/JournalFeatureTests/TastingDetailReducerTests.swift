import ComposableArchitecture
import UserDomain
import WineDomain
import XCTest

@testable import JournalFeature

/// `TestStore` coverage for the tasting detail. The `.task` action stays inert; UX2a adds owned Edit
/// (presents a prefilled `TastingFormReducer`) and Delete (confirm → `.delegate(.tastingDeleted)`).
///
/// The edit tests read `@Shared(.user)` (fileStorage-backed) so they pin `defaultFileStorage =
/// .inMemory` and seed the user to stay hermetic.
@MainActor
final class TastingDetailReducerTests: XCTestCase {
    func testStateExposesTastingAndWine() async {
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)
        let url = URL(string: "https://example.com/p.jpg")!
        let tasting = Tasting(
            id: "t1",
            wineId: wine.id,
            date: Date(timeIntervalSince1970: 1000),
            ratingStars: 4.5,
            rating100: 95,
            note: "Lovely",
            sat: SATNote(appearance: "Deep ruby", nose: "Cassis", palate: "Long", conclusions: "Hold"),
            photoURLs: [url]
        )

        let store = TestStore(
            initialState: TastingDetailReducer.State(tasting: tasting, wine: wine)
        ) {
            TastingDetailReducer()
        }

        XCTAssertEqual(store.state.tasting, tasting)
        XCTAssertEqual(store.state.wine, wine)
        XCTAssertEqual(store.state.tasting.sat?.nose, "Cassis")
        XCTAssertEqual(store.state.tasting.photoURLs, [url])

        // .task remains inert.
        await store.send(.task)
    }

    /// Edit: presents a `TastingFormReducer` prefilled from the tasting (exhaustivity off because the
    /// form's `.task` fires only when its view appears, not here).
    func testEditTappedPresentsPrefilledForm() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)
            let tasting = Tasting(
                id: "t1", wineId: wine.id, date: Date(timeIntervalSince1970: 1000),
                ratingStars: 4.5, note: "Lovely"
            )

            let store = TestStore(
                initialState: TastingDetailReducer.State(tasting: tasting, wine: wine)
            ) {
                TastingDetailReducer()
            }
            store.exhaustivity = .off

            await store.send(.editTapped)
            guard case let .editTasting(formState) = store.state.destination else {
                return XCTFail("expected editTasting destination")
            }
            XCTAssertEqual(formState.editingID, "t1")
            XCTAssertEqual(formState.note, "Lovely")
            XCTAssertEqual(formState.ratingStars, 4.5)
            XCTAssertEqual(formState.hid, "hid-1")
            XCTAssertEqual(formState.uid, "uid-1")
        }
    }

    /// Delete: tapping arms the confirmation dialog; confirming reports `.delegate(.tastingDeleted)`.
    func testDeleteFlowEmitsTastingDeleted() async {
        let wine = Wine(producer: "Estate", vintage: 2018)
        let tasting = Tasting(id: "t1", wineId: wine.id)

        let store = TestStore(
            initialState: TastingDetailReducer.State(tasting: tasting, wine: wine)
        ) {
            TastingDetailReducer()
        }
        store.exhaustivity = .off

        await store.send(.deleteTapped)
        XCTAssertNotNil(store.state.confirmDelete)

        await store.send(.confirmDelete(.presented(.confirm)))
        await store.receive(.delegate(.tastingDeleted("t1")))
    }

    /// Edit saved: dismisses the form and reports `.delegate(.tastingUpdated)`.
    func testEditSavedEmitsUpdatedAndDismisses() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let wine = Wine(producer: "Estate", vintage: 2018)
            let tasting = Tasting(id: "t1", wineId: wine.id)

            var initial = TastingDetailReducer.State(tasting: tasting, wine: wine)
            initial.destination = .editTasting(
                TastingFormReducer.State(editing: tasting, wine: wine, hid: "hid-1", uid: "uid-1")
            )

            let store = TestStore(initialState: initial) {
                TastingDetailReducer()
            }
            store.exhaustivity = .off

            let updated = Tasting(id: "t1", wineId: wine.id, note: "Updated")
            await store.send(.destination(.presented(.editTasting(.delegate(.saved(updated))))))
            await store.receive(.delegate(.tastingUpdated(updated)))
            XCTAssertNil(store.state.destination)
        }
    }
}
