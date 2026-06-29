import ComposableArchitecture
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
            $user.withLock { $0 = User(id: "uid-1", displayName: "T") }

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

            let store = TestStore(initialState: CellarReducer.State()) {
                CellarReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [b1, b2, b3] }
                $0.persistence.wines = { _ in [w1, w2] }
                $0.date = .constant(self.year2026)
            }

            let expected = [
                CellarRow(bottle: b1, wine: w1, drinkStatus: .hold),
                CellarRow(bottle: b2, wine: w2, drinkStatus: .drinkNow),
            ]

            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            await store.receive(.loaded(expected)) {
                $0.isLoading = false
                $0.rows = expected
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
        }
    }
}
