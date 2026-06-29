import ComposableArchitecture
import PersistenceClient
import WineDomain
import XCTest

@testable import JournalFeature

/// `TestStore` coverage for the M5 Phase 1 "Add to cellar" form. Stubs `\.persistence` so the tests
/// stay offline, and pins `\.uuid` to `.incrementing` so the generated `Bottle.id` is deterministic.
@MainActor
final class BottleFormReducerTests: XCTestCase {
    private struct StubError: Error, LocalizedError {
        var errorDescription: String? { "save failed" }
    }

    /// Happy path: fields entered via bindings, persistence captures the exact `uid`/`Bottle`, and the
    /// reducer reports `.delegate(.saved)`.
    func testSaveHappyPath() async {
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)

        let captured = LockIsolated<(hid: String, bottle: Bottle)?>(nil)

        let store = TestStore(initialState: BottleFormReducer.State(wine: wine, hid: "test-hid")) {
            BottleFormReducer()
        } withDependencies: {
            $0.persistence.saveBottle = { hid, bottle in
                captured.setValue((hid, bottle))
            }
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }

        await store.send(.binding(.set(\.priceText, "42.50"))) {
            $0.priceText = "42.50"
        }
        await store.send(.binding(.set(\.quantity, 3))) {
            $0.quantity = 3
        }
        await store.send(.binding(.set(\.store, "K&L"))) {
            $0.store = "K&L"
        }
        await store.send(.binding(.set(\.status, .wishlist))) {
            $0.status = .wishlist
        }
        await store.send(.binding(.set(\.includePurchaseDate, false))) {
            $0.includePurchaseDate = false
        }

        let expectedBottle = Bottle(
            id: "00000000-0000-0000-0000-000000000000",
            wineId: wine.id,
            purchaseDate: nil,
            price: 42.5,
            currency: "USD",
            quantity: 3,
            store: "K&L",
            storageLocation: nil,
            drinkFrom: nil,
            drinkBy: nil,
            status: .wishlist,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        await store.send(.saveTapped) {
            $0.isSaving = true
            $0.errorMessage = nil
        }
        await store.receive(.saveResponse(.success(expectedBottle))) {
            $0.isSaving = false
        }
        await store.receive(.delegate(.saved(expectedBottle)))

        XCTAssertEqual(captured.value?.hid, "test-hid")
        XCTAssertEqual(captured.value?.bottle.wineId, wine.id)
        XCTAssertEqual(captured.value?.bottle.price, 42.5)
        XCTAssertEqual(captured.value?.bottle.quantity, 3)
        XCTAssertEqual(captured.value?.bottle.status, .wishlist)
        XCTAssertEqual(captured.value?.bottle.id, "00000000-0000-0000-0000-000000000000")
    }

    /// Failure path: persistence throws, the reducer surfaces `errorMessage`, clears `isSaving`, and
    /// emits no `.delegate(.saved)`.
    func testSaveFailureSurfacesErrorAndEmitsNoSavedDelegate() async {
        let wine = Wine(producer: "Ridge Vineyards", name: "Monte Bello", vintage: 2018)

        let store = TestStore(initialState: BottleFormReducer.State(wine: wine, hid: "test-hid")) {
            BottleFormReducer()
        } withDependencies: {
            $0.persistence.saveBottle = { _, _ in throw StubError() }
            $0.uuid = .incrementing
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }

        await store.send(.saveTapped) {
            $0.isSaving = true
            $0.errorMessage = nil
        }
        await store.receive(.saveResponse(.failure("save failed"))) {
            $0.isSaving = false
            $0.errorMessage = "save failed"
        }
        // Exhaustive TestStore: any unasserted `.delegate(.saved)` effect would fail the test.
    }

    /// Cancel: emits `.delegate(.cancelled)` with no persistence side effects.
    func testCancelEmitsCancelledDelegate() async {
        let wine = Wine(producer: "Anything", vintage: 2020)

        let store = TestStore(initialState: BottleFormReducer.State(wine: wine, hid: "test-hid")) {
            BottleFormReducer()
        }

        await store.send(.cancelTapped)
        await store.receive(.delegate(.cancelled))
    }
}
