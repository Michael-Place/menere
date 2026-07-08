import BottleCardFeature
import ComposableArchitecture
import JournalFeature
import PersistenceClient
import UserDomain
import WineDomain
import XCTest

@testable import CellarFeature

/// `TestStore` coverage for the reframed **Wine** root (journal-first + an "On hand" strip): the
/// bottle→wine and tasting→wine joins at load time, the pure `onHand` / `visibleTastingRows`
/// derivations, and the tile/journal navigation + delete flows.
///
/// `@Shared(.user)` is fileStorage-backed, so each test that loads pins `defaultFileStorage =
/// .inMemory` and seeds the user to stay hermetic (mirrors `BottleCardFeatureTests`).
@MainActor
final class CellarReducerTests: XCTestCase {
    private struct StubError: Error, LocalizedError {
        var errorDescription: String? { "load failed" }
    }

    private var year2026: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    }

    // MARK: 1. Load joins bottles + tastings; orphans dropped

    func testLoadJoinsBottlesAndTastings() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let w1 = Wine(producer: "Estate A", vintage: 2018)
            let w2 = Wine(producer: "Estate B", vintage: 2015)

            let b1 = Bottle(id: "b1", wineId: w1.id, status: .cellared, createdAt: Date(timeIntervalSince1970: 100))
            let b2 = Bottle(id: "b2", wineId: w2.id, status: .cellared, createdAt: Date(timeIntervalSince1970: 200))
            // No matching wine → dropped from the join.
            let b3 = Bottle(id: "b3", wineId: "missing", status: .cellared, createdAt: Date(timeIntervalSince1970: 300))

            let t1 = Tasting(id: "t1", wineId: w1.id, date: Date(timeIntervalSince1970: 500), ratingStars: 4.5)
            let t2 = Tasting(id: "t2", wineId: "missing", date: Date(timeIntervalSince1970: 600))

            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [b1, b2, b3] }
                $0.persistence.tastings = { _ in [t1, t2] }
                $0.persistence.wines = { _ in [w1, w2] }
                $0.date = .constant(self.year2026)
            }

            let expectedRows = [
                CellarRow(bottle: b1, wine: w1),
                CellarRow(bottle: b2, wine: w2),
            ]
            let expectedTastings = [TastingRow(tasting: t1, wine: w1)]

            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            await store.receive(.loaded(expectedRows)) {
                $0.isLoading = false
                $0.rows = expectedRows
            }
            await store.receive(.tastingsLoaded(expectedTastings)) {
                $0.tastingRows = expectedTastings
            }

            XCTAssertEqual(store.state.rows.map(\.id), ["b1", "b2"])
            XCTAssertEqual(store.state.tastingRows.map(\.id), ["t1"])
            XCTAssertEqual(store.state.journaledCount, 1)
        }
    }

    // MARK: 2. No uid → empty load

    func testNoUidLoadsEmpty() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = nil }

            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.date = .constant(self.year2026)
            }

            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            await store.receive(.loaded([])) {
                $0.isLoading = false
            }
            await store.receive(.tastingsLoaded([]))
        }
    }

    // MARK: 3. On-hand strip is the cellared subset, newest first

    func testOnHandRowsFilterCellaredNewestFirst() async {
        let w = Wine(producer: "Estate", vintage: 2018)
        let cellaredOld = CellarRow(
            bottle: Bottle(id: "old", wineId: w.id, status: .cellared, createdAt: Date(timeIntervalSince1970: 100)),
            wine: w
        )
        let cellaredNew = CellarRow(
            bottle: Bottle(id: "new", wineId: w.id, quantity: 2, status: .cellared, createdAt: Date(timeIntervalSince1970: 300)),
            wine: w
        )
        let consumed = CellarRow(
            bottle: Bottle(id: "gone", wineId: w.id, status: .consumed, createdAt: Date(timeIntervalSince1970: 200)),
            wine: w
        )

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        await store.send(.loaded([cellaredOld, cellaredNew, consumed])) {
            $0.rows = [cellaredOld, cellaredNew, consumed]
        }

        XCTAssertEqual(store.state.onHandRows.map(\.id), ["new", "old"])   // consumed excluded, newest first
        XCTAssertEqual(store.state.onHandCount, 3)                          // new(×2) + old(×1)
    }

    // MARK: 4. Journal feed search + newest-first

    func testJournalSearchAndOrder() async {
        let w1 = Wine(producer: "Château Margaux", name: "Grand Vin")
        let w2 = Wine(producer: "Ridge", name: "Monte Bello")
        let rows = [
            TastingRow(tasting: Tasting(id: "old", wineId: w1.id, date: Date(timeIntervalSince1970: 100), note: "Stunning balance"), wine: w1),
            TastingRow(tasting: Tasting(id: "new", wineId: w2.id, date: Date(timeIntervalSince1970: 300), note: "Tannic and young", withWhom: "Dad"), wine: w2),
        ]

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        await store.send(.tastingsLoaded(rows)) { $0.tastingRows = rows }

        // Default: newest first.
        XCTAssertEqual(store.state.visibleTastingRows.map(\.id), ["new", "old"])

        await store.send(.binding(.set(\.searchText, "margaux"))) { $0.searchText = "margaux" }
        XCTAssertEqual(store.state.visibleTastingRows.map(\.id), ["old"])

        await store.send(.binding(.set(\.searchText, "dad"))) { $0.searchText = "dad" }
        XCTAssertEqual(store.state.visibleTastingRows.map(\.id), ["new"])
    }

    // MARK: 5. On-hand tap → pour dialog → pour presents the tasting form

    func testOnHandTappedPourPresentsTastingForm() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let wine = Wine(producer: "Estate", vintage: 2018)
            let row = CellarRow(bottle: Bottle(id: "b1", wineId: wine.id, status: .cellared), wine: wine)

            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            }
            store.exhaustivity = .off

            await store.send(.onHandTapped(row))
            XCTAssertNotNil(store.state.pourDialog)

            await store.send(.pourDialog(.presented(.pour(row))))
            guard case let .pourTasting(form) = store.state.destination else {
                return XCTFail("expected pourTasting destination")
            }
            XCTAssertEqual(form.wine, wine)
            XCTAssertEqual(form.hid, "hid-1")
            XCTAssertEqual(form.uid, "uid-1")
        }
    }

    // MARK: 6. On-hand tap → view presents the owned bottle card with its journal entries

    func testOnHandTappedViewPushesBottleCardWithJournal() async {
        let wine = Wine(producer: "Estate", vintage: 2018)
        let bottle = Bottle(id: "b1", wineId: wine.id, quantity: 2, status: .cellared)
        let row = CellarRow(bottle: bottle, wine: wine)
        let tasting = Tasting(id: "t1", wineId: wine.id, ratingStars: 4.0)

        var initial = CellarReducer.State()
        initial.tastingRows = [TastingRow(tasting: tasting, wine: wine)]

        let store = TestStore(initialState: initial) {
            CellarReducer()
        }
        store.exhaustivity = .off

        await store.send(.onHandTapped(row))          // present the dialog first (ifLet gate)
        await store.send(.pourDialog(.presented(.view(row))))
        guard case let .wineDetail(detail) = store.state.destination else {
            return XCTFail("expected wineDetail destination")
        }
        XCTAssertEqual(detail.wine, wine)
        XCTAssertEqual(detail.ownedBottle, bottle)
        XCTAssertEqual(detail.journalEntries, [tasting])   // wine's journal threaded onto the card
    }

    // MARK: 7. Journal row tap → read-only tasting detail

    func testJournalRowTappedPushesTastingDetail() async {
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)
        let tasting = Tasting(id: "t-1", wineId: wine.id, ratingStars: 4.0)
        let row = TastingRow(tasting: tasting, wine: wine)

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        store.exhaustivity = .off

        await store.send(.journalRowTapped(row))
        guard case let .tastingDetail(detail) = store.state.destination else {
            return XCTFail("expected tastingDetail destination")
        }
        XCTAssertEqual(detail.tasting, tasting)
        XCTAssertEqual(detail.wine, wine)
    }

    // MARK: 8. Add tile → requests scan

    func testAddBottleTappedRequestsScan() async {
        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        await store.send(.addBottleTapped)
        await store.receive(.delegate(.requestScan))
    }

    // MARK: 9. Pour form saved → reloads

    func testPourTastingSavedReloads() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let wine = Wine(producer: "Estate", vintage: 2018)
            var initial = CellarReducer.State()
            initial.destination = .pourTasting(TastingFormReducer.State(wine: wine, hid: "hid-1", uid: "uid-1"))

            let store = TestStore(initialState: initial) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [] }
                $0.persistence.tastings = { _ in [] }
                $0.persistence.wines = { _ in [] }
                $0.date = .constant(self.year2026)
            }
            store.exhaustivity = .off

            let saved = Tasting(id: "t1", wineId: wine.id, ratingStars: 4.0)
            await store.send(.destination(.presented(.pourTasting(.delegate(.saved(saved))))))
            await store.receive(\.loaded)
            await store.receive(\.tastingsLoaded)
            XCTAssertNil(store.state.destination)
        }
    }

    // MARK: 10. wineDetail delete delegate → deletes + pops + reloads

    func testWineDetailBottleDeletedDeletesAndReloads() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let captured = LockIsolated<(hid: String, id: String)?>(nil)
            let w = Wine(producer: "Estate", vintage: 2018)
            let b = Bottle(id: "b1", wineId: w.id, status: .cellared, createdAt: Date(timeIntervalSince1970: 100))

            var initial = CellarReducer.State()
            initial.destination = .wineDetail(BottleCardFeature.State(wine: w, ownedBottle: b))

            let store = TestStore(initialState: initial) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.deleteBottle = { hid, id in captured.setValue((hid, id)) }
                $0.persistence.bottles = { _ in [] }
                $0.persistence.tastings = { _ in [] }
                $0.persistence.wines = { _ in [] }
                $0.date = .constant(self.year2026)
            }
            store.exhaustivity = .off

            await store.send(.destination(.presented(.wineDetail(.delegate(.bottleDeleted("b1"))))))
            await store.receive(\.loaded)
            await store.receive(\.tastingsLoaded)

            XCTAssertNil(store.state.destination)
            XCTAssertEqual(captured.value?.hid, "hid-1")
            XCTAssertEqual(captured.value?.id, "b1")
        }
    }

    // MARK: 11. tastingDetail delete delegate → deletes + reloads

    func testTastingDetailTastingDeletedDeletesAndReloads() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let captured = LockIsolated<(hid: String, id: String)?>(nil)
            let w = Wine(producer: "Estate", vintage: 2018)
            let t = Tasting(id: "t1", wineId: w.id, ratingStars: 4.0)

            var initial = CellarReducer.State()
            initial.destination = .tastingDetail(TastingDetailReducer.State(tasting: t, wine: w))

            let store = TestStore(initialState: initial) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.deleteTasting = { hid, id in captured.setValue((hid, id)) }
                $0.persistence.bottles = { _ in [] }
                $0.persistence.tastings = { _ in [] }
                $0.persistence.wines = { _ in [] }
                $0.date = .constant(self.year2026)
            }
            store.exhaustivity = .off

            await store.send(.destination(.presented(.tastingDetail(.delegate(.tastingDeleted("t1"))))))
            await store.receive(\.loaded)
            await store.receive(\.tastingsLoaded)

            XCTAssertNil(store.state.destination)
            XCTAssertEqual(captured.value?.hid, "hid-1")
            XCTAssertEqual(captured.value?.id, "t1")
        }
    }

    // MARK: 12. Swipe-to-delete a journal entry

    func testSwipeDeleteTastingDeletesAndReloads() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let captured = LockIsolated<(hid: String, id: String)?>(nil)
            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.deleteTasting = { hid, id in captured.setValue((hid, id)) }
                $0.persistence.bottles = { _ in [] }
                $0.persistence.tastings = { _ in [] }
                $0.persistence.wines = { _ in [] }
                $0.date = .constant(self.year2026)
            }
            store.exhaustivity = .off

            await store.send(.deleteTastingSwiped("t1"))
            await store.receive(\.loaded)
            await store.receive(\.tastingsLoaded)

            XCTAssertEqual(captured.value?.hid, "hid-1")
            XCTAssertEqual(captured.value?.id, "t1")
        }
    }

    // MARK: 13. Load failure surfaces error; retry clears it and reloads

    func testLoadFailureSurfacesErrorThenRetryReloads() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let failing = LockIsolated(true)
            let w = Wine(producer: "Estate", vintage: 2018)
            let b = Bottle(id: "b1", wineId: w.id, status: .cellared, createdAt: Date(timeIntervalSince1970: 100))

            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in
                    if failing.value { throw StubError() }
                    return [b]
                }
                $0.persistence.tastings = { _ in [] }
                $0.persistence.wines = { _ in [w] }
                $0.date = .constant(self.year2026)
            }

            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            await store.receive(\.loadFailed) {
                $0.isLoading = false
                $0.loadError = "load failed"
            }

            failing.setValue(false)
            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            let row = CellarRow(bottle: b, wine: w)
            await store.receive(.loaded([row])) {
                $0.isLoading = false
                $0.rows = [row]
            }
            await store.receive(.tastingsLoaded([]))
        }
    }

    // MARK: 14. journalEntries(forWineId:) surfaces a wine's tastings newest-first

    func testJournalEntriesForWine() async {
        let w1 = Wine(producer: "Estate A")
        let w2 = Wine(producer: "Estate B")
        let a = Tasting(id: "a", wineId: w1.id, date: Date(timeIntervalSince1970: 100))
        let b = Tasting(id: "b", wineId: w1.id, date: Date(timeIntervalSince1970: 300))
        let c = Tasting(id: "c", wineId: w2.id, date: Date(timeIntervalSince1970: 200))

        var state = CellarReducer.State()
        state.tastingRows = [
            TastingRow(tasting: a, wine: w1),
            TastingRow(tasting: b, wine: w1),
            TastingRow(tasting: c, wine: w2),
        ]

        XCTAssertEqual(state.journalEntries(forWineId: w1.id).map(\.id), ["b", "a"])
        XCTAssertEqual(state.journalEntries(forWineId: w2.id).map(\.id), ["c"])
    }
}
