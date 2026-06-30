import BottleCardFeature
import ComposableArchitecture
import JournalFeature
import PersistenceClient
import UserDomain
import WineDomain
import XCTest

@testable import CellarFeature

/// `TestStore` coverage for the Cellar tab: the bottle→wine join + drink-window classification at
/// load time, and the pure `visibleRows` search / filter / sort pipeline.
///
/// `@Shared(.user)` is fileStorage-backed, so each test that loads pins `defaultFileStorage =
/// .inMemory` and seeds the user to stay hermetic (mirrors `BottleCardFeatureTests`).
@MainActor
final class CellarReducerTests: XCTestCase {
    private struct StubError: Error, LocalizedError {
        var errorDescription: String? { "load failed" }
    }

    /// A fixed date in calendar year 2026, robust to the test machine's timezone.
    private var year2026: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    }

    // MARK: 1. Load + join + drink-window classify

    func testLoadJoinsBottlesAndClassifiesDrinkWindow() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let w1 = Wine(producer: "Hold Estate", vintage: 2018)
            let w2 = Wine(producer: "Ready Estate", vintage: 2015)

            let b1 = Bottle(
                id: "b1", wineId: w1.id, drinkFrom: 2030, drinkBy: 2040,
                status: .cellared, createdAt: Date(timeIntervalSince1970: 100)
            )
            let b2 = Bottle(
                id: "b2", wineId: w2.id, drinkFrom: 2024, drinkBy: 2032,
                status: .cellared, createdAt: Date(timeIntervalSince1970: 200)
            )
            // No matching wine → dropped from the join.
            let b3 = Bottle(
                id: "b3", wineId: "missing-wine-id",
                status: .cellared, createdAt: Date(timeIntervalSince1970: 300)
            )

            let t1 = Tasting(id: "t1", wineId: w1.id, date: Date(timeIntervalSince1970: 500), ratingStars: 4.5)

            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [b1, b2, b3] }
                $0.persistence.tastings = { _ in [t1] }
                $0.persistence.wines = { _ in [w1, w2] }
                $0.date = .constant(self.year2026)
            }

            let expected = [
                CellarRow(bottle: b1, wine: w1, drinkStatus: .hold),
                CellarRow(bottle: b2, wine: w2, drinkStatus: .drinkNow),
            ]
            let expectedTastings = [TastingRow(tasting: t1, wine: w1)]

            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            await store.receive(.loaded(expected)) {
                $0.isLoading = false
                $0.rows = expected
            }
            await store.receive(.tastingsLoaded(expectedTastings)) {
                $0.tastingRows = expectedTastings
            }
            let expectedDashboard = DashboardData(
                cellaredBottleCount: 3,      // b1 + b2 + b3 (default qty 1, raw counts)
                distinctWineCount: 3,        // {w1, w2, "missing-wine-id"}
                wishlistCount: 0,
                tastingCount: 1,
                drinkSoon: [HomeBottleRow(bottle: b2, wine: w2)],   // b1 is hold, b3 has no wine
                recentTastings: [HomeTastingRow(tasting: t1, wine: w1)],
                typeBreakdown: [TypeSlice(type: .other, count: 2)]  // w1+w2 default .other; b3 skipped
            )
            await store.receive(.dashboardLoaded(expectedDashboard)) {
                $0.dashboard = expectedDashboard
            }

            XCTAssertEqual(store.state.rows.count, 2)
            XCTAssertEqual(store.state.rows.map(\.id), ["b1", "b2"])
            XCTAssertEqual(store.state.rows[0].drinkStatus, .hold)
            XCTAssertEqual(store.state.rows[1].drinkStatus, .drinkNow)
        }
    }

    // MARK: 2. Search filter

    func testSearchFiltersByProducerAndRegion() async {
        let margaux = Wine(
            producer: "Château Margaux", name: "Grand Vin", vintage: 2015,
            region: Region(country: "France", region: "Bordeaux")
        )
        let ridge = Wine(
            producer: "Ridge", name: "Monte Bello", vintage: 2018,
            region: Region(country: "USA", region: "California")
        )
        let rows = [
            CellarRow(
                bottle: Bottle(id: "m", wineId: margaux.id, createdAt: Date(timeIntervalSince1970: 200)),
                wine: margaux, drinkStatus: .unknown
            ),
            CellarRow(
                bottle: Bottle(id: "r", wineId: ridge.id, createdAt: Date(timeIntervalSince1970: 100)),
                wine: ridge, drinkStatus: .unknown
            ),
        ]

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        await store.send(.loaded(rows)) { $0.rows = rows }

        await store.send(.binding(.set(\.searchText, "margaux"))) { $0.searchText = "margaux" }
        XCTAssertEqual(store.state.visibleRows.map(\.id), ["m"])

        await store.send(.binding(.set(\.searchText, "california"))) { $0.searchText = "california" }
        XCTAssertEqual(store.state.visibleRows.map(\.id), ["r"])
    }

    // MARK: 3. Status filter

    func testStatusFilterExcludesNonMatching() async {
        let w1 = Wine(producer: "Cellared Co", vintage: 2019)
        let w2 = Wine(producer: "Wishlist Co", vintage: 2020)
        let rows = [
            CellarRow(
                bottle: Bottle(id: "c", wineId: w1.id, status: .cellared, createdAt: Date(timeIntervalSince1970: 200)),
                wine: w1, drinkStatus: .unknown
            ),
            CellarRow(
                bottle: Bottle(id: "w", wineId: w2.id, status: .wishlist, createdAt: Date(timeIntervalSince1970: 100)),
                wine: w2, drinkStatus: .unknown
            ),
        ]

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        await store.send(.loaded(rows)) { $0.rows = rows }

        await store.send(.binding(.set(\.statusFilter, .cellared))) { $0.statusFilter = .cellared }
        XCTAssertEqual(store.state.visibleRows.map(\.id), ["c"])
    }

    // MARK: 4. Sort

    func testSortByProducerVintageAndDrinkWindow() async {
        let wA = Wine(producer: "Zind", vintage: 2010)
        let wB = Wine(producer: "Antinori", vintage: 2020)
        let wC = Wine(producer: "Mascarello") // nil vintage

        let rows = [
            CellarRow(
                bottle: Bottle(id: "a", wineId: wA.id, drinkFrom: 2025, drinkBy: 2040, createdAt: Date(timeIntervalSince1970: 300)),
                wine: wA, drinkStatus: .drinkNow
            ),
            CellarRow(
                bottle: Bottle(id: "b", wineId: wB.id, drinkFrom: 2022, drinkBy: 2030, createdAt: Date(timeIntervalSince1970: 200)),
                wine: wB, drinkStatus: .drinkNow
            ),
            CellarRow(
                bottle: Bottle(id: "c", wineId: wC.id, createdAt: Date(timeIntervalSince1970: 100)),
                wine: wC, drinkStatus: .unknown
            ),
        ]

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        await store.send(.loaded(rows)) { $0.rows = rows }

        await store.send(.binding(.set(\.sort, .producer))) { $0.sort = .producer }
        XCTAssertEqual(store.state.visibleRows.map(\.id), ["b", "c", "a"])

        await store.send(.binding(.set(\.sort, .vintage))) { $0.sort = .vintage }
        XCTAssertEqual(store.state.visibleRows.map(\.id), ["a", "b", "c"])

        await store.send(.binding(.set(\.sort, .drinkWindow))) { $0.sort = .drinkWindow }
        XCTAssertEqual(store.state.visibleRows.map(\.id), ["b", "a", "c"])
    }

    // MARK: 5. No uid → empty load

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
            await store.receive(.dashboardLoaded(.empty))
        }
    }

    // MARK: 6. Tasting load joins + drops orphans

    func testTastingLoadJoinsAndDropsOrphans() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let w1 = Wine(producer: "Estate A", vintage: 2018)
            let w2 = Wine(producer: "Estate B", vintage: 2015)

            let t1 = Tasting(id: "t1", wineId: w1.id, date: Date(timeIntervalSince1970: 100), ratingStars: 4.0)
            let t2 = Tasting(id: "t2", wineId: w2.id, date: Date(timeIntervalSince1970: 200), ratingStars: 3.0)
            // References a wine that won't be returned → dropped.
            let t3 = Tasting(id: "t3", wineId: "missing", date: Date(timeIntervalSince1970: 300))

            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [] }
                $0.persistence.tastings = { _ in [t1, t2, t3] }
                $0.persistence.wines = { _ in [w1, w2] }
                $0.date = .constant(self.year2026)
            }

            let expectedTastings = [
                TastingRow(tasting: t1, wine: w1),
                TastingRow(tasting: t2, wine: w2),
            ]

            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            await store.receive(.loaded([])) {
                $0.isLoading = false
            }
            await store.receive(.tastingsLoaded(expectedTastings)) {
                $0.tastingRows = expectedTastings
            }
            let expectedDashboard = DashboardData(
                tastingCount: 3,
                recentTastings: [
                    HomeTastingRow(tasting: t2, wine: w2),   // date 200, sorted desc
                    HomeTastingRow(tasting: t1, wine: w1),   // date 100
                ]                                            // t3 dropped (no wine)
            )
            await store.receive(.dashboardLoaded(expectedDashboard)) {
                $0.dashboard = expectedDashboard
            }

            XCTAssertEqual(store.state.tastingRows.map(\.id), ["t1", "t2"])
        }
    }

    // MARK: 7. Min-rating filter

    func testMinRatingFilter() async {
        let w = Wine(producer: "Estate", vintage: 2018)
        let rows = [
            TastingRow(tasting: Tasting(id: "r3", wineId: w.id, ratingStars: 3.0), wine: w),
            TastingRow(tasting: Tasting(id: "r4", wineId: w.id, ratingStars: 4.0), wine: w),
            TastingRow(tasting: Tasting(id: "r45", wineId: w.id, ratingStars: 4.5), wine: w),
            TastingRow(tasting: Tasting(id: "rnil", wineId: w.id, ratingStars: nil), wine: w),
        ]

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        await store.send(.tastingsLoaded(rows)) { $0.tastingRows = rows }

        await store.send(.binding(.set(\.minRating, 4.0))) { $0.minRating = 4.0 }
        XCTAssertEqual(Set(store.state.visibleTastingRows.map(\.id)), ["r4", "r45"])
    }

    // MARK: 8. Grape filter

    func testGrapeFilter() async {
        let pinot = Wine(producer: "Burgundy Co", grapes: ["Pinot Noir"])
        let cab = Wine(producer: "Bordeaux Co", grapes: ["Cabernet Sauvignon", "Merlot"])
        let rows = [
            TastingRow(tasting: Tasting(id: "p", wineId: pinot.id), wine: pinot),
            TastingRow(tasting: Tasting(id: "c", wineId: cab.id), wine: cab),
        ]

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        await store.send(.tastingsLoaded(rows)) { $0.tastingRows = rows }

        await store.send(.binding(.set(\.grapeFilter, "Pinot Noir"))) { $0.grapeFilter = "Pinot Noir" }
        XCTAssertEqual(store.state.visibleTastingRows.map(\.id), ["p"])
        XCTAssertEqual(store.state.availableGrapes, ["Cabernet Sauvignon", "Merlot", "Pinot Noir"])
    }

    // MARK: 9. History sort

    func testHistorySort() async {
        let w = Wine(producer: "Estate", vintage: 2018)
        // a: old date, high rating; b: new date, low rating; c: mid date, nil rating
        let a = TastingRow(tasting: Tasting(id: "a", wineId: w.id, date: Date(timeIntervalSince1970: 100), ratingStars: 5.0), wine: w)
        let b = TastingRow(tasting: Tasting(id: "b", wineId: w.id, date: Date(timeIntervalSince1970: 300), ratingStars: 3.0), wine: w)
        let c = TastingRow(tasting: Tasting(id: "c", wineId: w.id, date: Date(timeIntervalSince1970: 200), ratingStars: nil), wine: w)
        let rows = [a, b, c]

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        await store.send(.tastingsLoaded(rows)) { $0.tastingRows = rows }

        // dateNewest is the default.
        XCTAssertEqual(store.state.visibleTastingRows.map(\.id), ["b", "c", "a"])

        await store.send(.binding(.set(\.historySort, .dateOldest))) { $0.historySort = .dateOldest }
        XCTAssertEqual(store.state.visibleTastingRows.map(\.id), ["a", "c", "b"])

        await store.send(.binding(.set(\.historySort, .ratingHigh))) { $0.historySort = .ratingHigh }
        XCTAssertEqual(store.state.visibleTastingRows.map(\.id), ["a", "b", "c"])
    }

    // MARK: 10. Shared search over tasting fields

    func testSharedSearchOverTastingFields() async {
        let w1 = Wine(producer: "Château Margaux", name: "Grand Vin")
        let w2 = Wine(producer: "Ridge", name: "Monte Bello")
        let rows = [
            TastingRow(tasting: Tasting(id: "m", wineId: w1.id, note: "Stunning balance"), wine: w1),
            TastingRow(tasting: Tasting(id: "r", wineId: w2.id, note: "Tannic and young", withWhom: "Dad"), wine: w2),
        ]

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        await store.send(.tastingsLoaded(rows)) { $0.tastingRows = rows }

        await store.send(.binding(.set(\.searchText, "margaux"))) { $0.searchText = "margaux" }
        XCTAssertEqual(store.state.visibleTastingRows.map(\.id), ["m"])

        await store.send(.binding(.set(\.searchText, "tannic"))) { $0.searchText = "tannic" }
        XCTAssertEqual(store.state.visibleTastingRows.map(\.id), ["r"])

        await store.send(.binding(.set(\.searchText, "dad"))) { $0.searchText = "dad" }
        XCTAssertEqual(store.state.visibleTastingRows.map(\.id), ["r"])
    }

    // MARK: 11. Load failure surfaces error; retry clears it and reloads

    func testLoadFailureSurfacesErrorThenRetryReloads() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let failing = LockIsolated(true)
            let w = Wine(producer: "Estate", vintage: 2018)
            let b = Bottle(id: "b1", wineId: w.id, status: .cellared,
                           createdAt: Date(timeIntervalSince1970: 100))

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

            // First load fails → loadError surfaced.
            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            await store.receive(\.loadFailed) {
                $0.isLoading = false
                $0.loadError = "load failed"
            }

            // Retry: flip the stub to succeed; .task clears the error and reloads.
            failing.setValue(false)
            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            let row = CellarRow(bottle: b, wine: w, drinkStatus: .unknown)
            await store.receive(.loaded([row])) {
                $0.isLoading = false
                $0.rows = [row]
            }
            await store.receive(.tastingsLoaded([]))
            let expectedDashboard = DashboardData(
                cellaredBottleCount: 1,
                distinctWineCount: 1,
                typeBreakdown: [TypeSlice(type: .other, count: 1)]
            )
            await store.receive(.dashboardLoaded(expectedDashboard)) {
                $0.dashboard = expectedDashboard
            }
        }
    }

    // MARK: 12. Tapping a cellar row pushes the owned-bottle card

    func testWineRowTappedPushesOwnedBottleCard() async {
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)
        let bottle = Bottle(id: "b-1", wineId: wine.id, quantity: 2, status: .cellared)
        let row = CellarRow(bottle: bottle, wine: wine, drinkStatus: .drinkNow)

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        store.exhaustivity = .off

        await store.send(.wineRowTapped(row))

        guard case let .wineDetail(detail) = store.state.destination else {
            return XCTFail("expected wineDetail destination")
        }
        XCTAssertEqual(detail.wine, wine)
        XCTAssertEqual(detail.ownedBottle, bottle)
    }

    // MARK: 13. Tapping a history row pushes the read-only tasting detail

    func testTastingRowTappedPushesTastingDetail() async {
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)
        let tasting = Tasting(id: "t-1", wineId: wine.id, ratingStars: 4.0)
        let row = TastingRow(tasting: tasting, wine: wine)

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        store.exhaustivity = .off

        await store.send(.tastingRowTapped(row))

        guard case let .tastingDetail(detail) = store.state.destination else {
            return XCTFail("expected tastingDetail destination")
        }
        XCTAssertEqual(detail.tasting, tasting)
        XCTAssertEqual(detail.wine, wine)
    }

    // MARK: 14. wineDetail delete delegate → deletes + pops + reloads

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

    // MARK: 15. tastingDetail delete delegate → deletes + reloads

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

    // MARK: swipe-to-delete (UX2b)

    func testSwipeDeleteBottleDeletesAndReloads() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let captured = LockIsolated<(hid: String, id: String)?>(nil)
            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.deleteBottle = { hid, id in captured.setValue((hid, id)) }
                $0.persistence.bottles = { _ in [] }
                $0.persistence.tastings = { _ in [] }
                $0.persistence.wines = { _ in [] }
                $0.date = .constant(self.year2026)
            }
            store.exhaustivity = .off

            await store.send(.deleteBottleSwiped("b1"))
            await store.receive(\.loaded)
            await store.receive(\.tastingsLoaded)

            XCTAssertEqual(captured.value?.hid, "hid-1")
            XCTAssertEqual(captured.value?.id, "b1")
        }
    }

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

    // MARK: 16. update delegates → reload only (no delete)

    func testUpdateDelegatesReloadWithoutDeleting() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let w = Wine(producer: "Estate", vintage: 2018)
            let b = Bottle(id: "b1", wineId: w.id, status: .cellared, createdAt: Date(timeIntervalSince1970: 100))
            let t = Tasting(id: "t1", wineId: w.id, ratingStars: 4.0)

            var initial = CellarReducer.State()
            initial.destination = .wineDetail(BottleCardFeature.State(wine: w, ownedBottle: b))

            let store = TestStore(initialState: initial) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.deleteBottle = { _, _ in XCTFail("delete must not be called on update") }
                $0.persistence.deleteTasting = { _, _ in XCTFail("delete must not be called on update") }
                $0.persistence.bottles = { _ in [] }
                $0.persistence.tastings = { _ in [] }
                $0.persistence.wines = { _ in [] }
                $0.date = .constant(self.year2026)
            }
            store.exhaustivity = .off

            await store.send(.destination(.presented(.wineDetail(.delegate(.bottleUpdated(b))))))
            await store.receive(\.loaded)
            await store.receive(\.tastingsLoaded)
            XCTAssertNil(store.state.destination)

            // tastingUpdated reloads too. Re-present a tasting detail via a row tap.
            await store.send(.tastingRowTapped(TastingRow(tasting: t, wine: w)))
            await store.send(.destination(.presented(.tastingDetail(.delegate(.tastingUpdated(t))))))
            await store.receive(\.loaded)
            await store.receive(\.tastingsLoaded)
            XCTAssertNil(store.state.destination)
        }
    }

    // MARK: applyPreset (cross-tab deep-link presets)

    func testApplyPresetSetsSegmentStatusAndClearsSearch() async {
        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }

        await store.send(.binding(.set(\.searchText, "x"))) {
            $0.searchText = "x"
        }

        await store.send(.applyPreset(segment: .cellar, statusFilter: .wishlist)) {
            $0.segment = .cellar
            $0.statusFilter = .wishlist
            $0.searchText = ""
        }

        await store.send(.applyPreset(segment: .history, statusFilter: nil)) {
            $0.segment = .history
            $0.statusFilter = nil
        }
    }

    // MARK: Dashboard — stat-tile tap applies an inline preset

    func testStatTileTappedAppliesPreset() async {
        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }

        await store.send(.binding(.set(\.searchText, "x"))) {
            $0.searchText = "x"
        }

        await store.send(.statTileTapped(.wishlist)) {
            $0.segment = .cellar
            $0.statusFilter = .wishlist
            $0.searchText = ""
        }

        await store.send(.statTileTapped(.tastings)) {
            $0.segment = .history
            $0.statusFilter = nil
        }
    }

    // MARK: Dashboard — tapping a drink-soon row pushes the owned-bottle card

    func testDrinkSoonRowTappedPushesWineDetail() async {
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)
        let bottle = Bottle(id: "b-1", wineId: wine.id, quantity: 2, status: .cellared)
        let row = HomeBottleRow(bottle: bottle, wine: wine)

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        store.exhaustivity = .off

        await store.send(.drinkSoonRowTapped(row))

        guard case let .wineDetail(detail) = store.state.destination else {
            return XCTFail("expected wineDetail destination")
        }
        XCTAssertEqual(detail.wine, wine)
        XCTAssertEqual(detail.ownedBottle, bottle)
    }

    // MARK: Dashboard — tapping a recent-tasting row pushes the read-only tasting detail

    func testRecentTastingRowTappedPushesTastingDetail() async {
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)
        let tasting = Tasting(id: "t-1", wineId: wine.id, ratingStars: 4.0)
        let row = HomeTastingRow(tasting: tasting, wine: wine)

        let store = TestStore(initialState: CellarReducer.State()) {
            CellarReducer()
        }
        store.exhaustivity = .off

        await store.send(.recentTastingRowTapped(row))

        guard case let .tastingDetail(detail) = store.state.destination else {
            return XCTFail("expected tastingDetail destination")
        }
        XCTAssertEqual(detail.tasting, tasting)
        XCTAssertEqual(detail.wine, wine)
    }

    // MARK: Dashboard aggregation — stats computed from raw bottles/tastings

    func testDashboardLoadComputesStats() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let w1 = Wine(producer: "Ready Estate", vintage: 2018)   // drink now
            let w2 = Wine(producer: "Hold Estate", vintage: 2020)    // hold

            // Cellared (counts come from RAW bottles regardless of wine presence).
            let b1 = Bottle(id: "b1", wineId: w1.id, quantity: 2, drinkFrom: 2024, drinkBy: 2030,
                            status: .cellared, createdAt: Date(timeIntervalSince1970: 100))
            let b2 = Bottle(id: "b2", wineId: w2.id, quantity: 3, drinkFrom: 2030, drinkBy: 2040,
                            status: .cellared, createdAt: Date(timeIntervalSince1970: 200))
            // Drink-now but its wine is missing → counted in stats, dropped from drinkSoon.
            let b3 = Bottle(id: "b3", wineId: "missing", quantity: 1, drinkFrom: 2024, drinkBy: 2030,
                            status: .cellared, createdAt: Date(timeIntervalSince1970: 300))
            let b4 = Bottle(id: "b4", wineId: w1.id, quantity: 1, status: .wishlist,
                            createdAt: Date(timeIntervalSince1970: 400))
            let b5 = Bottle(id: "b5", wineId: w1.id, quantity: 5, status: .consumed,
                            createdAt: Date(timeIntervalSince1970: 500))

            let t1 = Tasting(id: "t1", wineId: w1.id, date: Date(timeIntervalSince1970: 800), ratingStars: 4.5)
            let t2 = Tasting(id: "t2", wineId: w2.id, date: Date(timeIntervalSince1970: 700), rating100: 92)
            let t3 = Tasting(id: "t3", wineId: "missing", date: Date(timeIntervalSince1970: 600))

            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [b1, b2, b3, b4, b5] }
                $0.persistence.tastings = { _ in [t1, t2, t3] }
                $0.persistence.wines = { _ in [w1, w2] }
                $0.date = .constant(self.year2026)
            }
            store.exhaustivity = .off

            let expected = DashboardData(
                cellaredBottleCount: 6,      // b1(2) + b2(3) + b3(1)
                distinctWineCount: 3,        // {w1, w2, missing}
                wishlistCount: 1,            // b4
                tastingCount: 3,             // t1, t2, t3
                drinkSoon: [HomeBottleRow(bottle: b1, wine: w1)],   // b2 is hold, b3 has no wine
                recentTastings: [
                    HomeTastingRow(tasting: t1, wine: w1),
                    HomeTastingRow(tasting: t2, wine: w2),
                ],                           // t3 dropped (no wine), sorted date desc
                typeBreakdown: [TypeSlice(type: .other, count: 5)]  // b1(2)+b2(3); b3/b4/b5 excluded
            )

            await store.send(.task)
            await store.receive(.dashboardLoaded(expected))
        }
    }

    // MARK: Dashboard aggregation — cellar composition by wine type

    func testDashboardComputesTypeBreakdown() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let red1 = Wine(producer: "Red One", vintage: 2018, type: .red)
            let red2 = Wine(producer: "Red Two", vintage: 2019, type: .red)
            let white = Wine(producer: "White One", vintage: 2020, type: .white)

            // Two cellared reds + one cellared white → [red:2, white:1] (qty-summed, count desc).
            let b1 = Bottle(id: "b1", wineId: red1.id, status: .cellared, createdAt: Date(timeIntervalSince1970: 100))
            let b2 = Bottle(id: "b2", wineId: red2.id, status: .cellared, createdAt: Date(timeIntervalSince1970: 200))
            let b3 = Bottle(id: "b3", wineId: white.id, status: .cellared, createdAt: Date(timeIntervalSince1970: 300))
            // Wishlist + orphan (missing wine) must not contribute to the breakdown.
            let b4 = Bottle(id: "b4", wineId: red1.id, status: .wishlist, createdAt: Date(timeIntervalSince1970: 400))
            let b5 = Bottle(id: "b5", wineId: "missing", status: .cellared, createdAt: Date(timeIntervalSince1970: 500))

            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [b1, b2, b3, b4, b5] }
                $0.persistence.tastings = { _ in [] }
                $0.persistence.wines = { _ in [red1, red2, white] }
                $0.date = .constant(self.year2026)
            }
            store.exhaustivity = .off

            await store.send(.task)
            await store.receive(\.dashboardLoaded)

            XCTAssertEqual(store.state.dashboard.typeBreakdown, [
                TypeSlice(type: .red, count: 2),
                TypeSlice(type: .white, count: 1),
            ])
        }
    }

    // MARK: Dashboard aggregation — drinkSoon classification + sort + cap

    func testDashboardDrinkSoonClassificationSortAndCap() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            // Distinct wines via distinct producers.
            let wines = (0..<8).map { Wine(producer: "Estate \($0)", vintage: 2018) }

            func bottle(_ idx: Int, from: Int?, by: Int?) -> Bottle {
                Bottle(id: "b\(idx)", wineId: wines[idx].id, drinkFrom: from, drinkBy: by,
                       status: .cellared, createdAt: Date(timeIntervalSince1970: Double(idx)))
            }

            // Six drink-now bottles (year 2026) + one with nil drinkBy (sorts last) + hold + past.
            let a = bottle(0, from: 2020, by: 2027)
            let b = bottle(1, from: 2020, by: 2028)
            let c = bottle(2, from: 2020, by: 2029)
            let d = bottle(3, from: 2020, by: 2030)
            let e = bottle(4, from: 2020, by: 2031)
            let f = bottle(5, from: 2020, by: nil)   // drink-now (only-from), nil drinkBy → sorts last
            let hold = bottle(6, from: 2030, by: 2040)
            let past = bottle(7, from: nil, by: 2020)

            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [past, e, hold, c, a, f, d, b] } // shuffled
                $0.persistence.tastings = { _ in [] }
                $0.persistence.wines = { _ in wines }
                $0.date = .constant(self.year2026)
            }
            store.exhaustivity = .off

            // Sorted by drinkBy asc, nil last, capped at 5 → a,b,c,d,e (f's nil sorts 6th → dropped).
            let expected = DashboardData(
                cellaredBottleCount: 8,
                distinctWineCount: 8,
                drinkSoon: [
                    HomeBottleRow(bottle: a, wine: wines[0]),
                    HomeBottleRow(bottle: b, wine: wines[1]),
                    HomeBottleRow(bottle: c, wine: wines[2]),
                    HomeBottleRow(bottle: d, wine: wines[3]),
                    HomeBottleRow(bottle: e, wine: wines[4]),
                ],
                typeBreakdown: [TypeSlice(type: .other, count: 8)]  // all 8 wines default .other
            )

            await store.send(.task)
            await store.receive(.dashboardLoaded(expected))
        }
    }

    // MARK: Dashboard aggregation — recentTastings sort + cap

    func testDashboardRecentTastingsSortAndCap() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let w = Wine(producer: "Estate", vintage: 2018)
            let tastings = (1...6).map {
                Tasting(id: "t\($0)", wineId: w.id, date: Date(timeIntervalSince1970: Double($0 * 100)))
            }

            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [] }
                $0.persistence.tastings = { _ in tastings }
                $0.persistence.wines = { _ in [w] }
                $0.date = .constant(self.year2026)
            }
            store.exhaustivity = .off

            // Newest 5 by date desc: t6, t5, t4, t3, t2.
            let expected = DashboardData(
                tastingCount: 6,
                recentTastings: [
                    HomeTastingRow(tasting: tastings[5], wine: w),
                    HomeTastingRow(tasting: tastings[4], wine: w),
                    HomeTastingRow(tasting: tastings[3], wine: w),
                    HomeTastingRow(tasting: tastings[2], wine: w),
                    HomeTastingRow(tasting: tastings[1], wine: w),
                ]
            )

            await store.send(.task)
            await store.receive(.dashboardLoaded(expected))
        }
    }
}
