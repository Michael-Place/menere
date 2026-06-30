import BottleCardFeature
import ComposableArchitecture
import PersistenceClient
import UserDomain
import WineDomain
import XCTest

@testable import HomeFeature

/// `TestStore` coverage for the Home dashboard: stat aggregation from raw bottles/tastings, the
/// drink-now classification (sort + cap) for "Drink soon", and recent-tasting sort + cap.
///
/// `@Shared(.user)` is fileStorage-backed, so each test that loads pins `defaultFileStorage =
/// .inMemory` and seeds the user to stay hermetic (mirrors `CellarReducerTests`).
@MainActor
final class HomeReducerTests: XCTestCase {
    /// A fixed date in calendar year 2026, robust to the test machine's timezone.
    private var year2026: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    }

    // MARK: 1. Stats computed from raw bottles/tastings

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

            let store = TestStore(initialState: HomeReducer.State()) {
                HomeReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [b1, b2, b3, b4, b5] }
                $0.persistence.tastings = { _ in [t1, t2, t3] }
                $0.persistence.wines = { _ in [w1, w2] }
                $0.date = .constant(self.year2026)
            }

            let expected = DashboardData(
                cellaredBottleCount: 6,      // b1(2) + b2(3) + b3(1)
                distinctWineCount: 3,        // {w1, w2, missing}
                wishlistCount: 1,            // b4
                tastingCount: 3,             // t1, t2, t3
                drinkSoon: [HomeBottleRow(bottle: b1, wine: w1)],   // b2 is hold, b3 has no wine
                recentTastings: [
                    HomeTastingRow(tasting: t1, wine: w1),
                    HomeTastingRow(tasting: t2, wine: w2),
                ]                            // t3 dropped (no wine), sorted date desc
            )

            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            await store.receive(.loaded(expected)) {
                $0.isLoading = false
                $0.data = expected
            }
        }
    }

    // MARK: 2. drinkSoon classification + sort + cap

    func testDrinkSoonClassificationSortAndCap() async {
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

            let store = TestStore(initialState: HomeReducer.State()) {
                HomeReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [past, e, hold, c, a, f, d, b] } // shuffled
                $0.persistence.tastings = { _ in [] }
                $0.persistence.wines = { _ in wines }
                $0.date = .constant(self.year2026)
            }

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
                ]
            )

            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            await store.receive(.loaded(expected)) {
                $0.isLoading = false
                $0.data = expected
            }
        }
    }

    // MARK: 3. recentTastings sort + cap

    func testRecentTastingsSortAndCap() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "T", householdId: "hid-1") }

            let w = Wine(producer: "Estate", vintage: 2018)
            let tastings = (1...6).map {
                Tasting(id: "t\($0)", wineId: w.id, date: Date(timeIntervalSince1970: Double($0 * 100)))
            }

            let store = TestStore(initialState: HomeReducer.State()) {
                HomeReducer()
            } withDependencies: {
                $0.persistence.bottles = { _ in [] }
                $0.persistence.tastings = { _ in tastings }
                $0.persistence.wines = { _ in [w] }
                $0.date = .constant(self.year2026)
            }

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

            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            await store.receive(.loaded(expected)) {
                $0.isLoading = false
                $0.data = expected
            }
        }
    }

    // MARK: 4. No uid → empty dashboard

    func testNoUidLoadsEmpty() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = nil }

            let store = TestStore(initialState: HomeReducer.State()) {
                HomeReducer()
            } withDependencies: {
                $0.date = .constant(self.year2026)
            }

            await store.send(.task) {
                $0.isLoading = true
                $0.loadError = nil
            }
            await store.receive(.loaded(.empty)) {
                $0.isLoading = false
            }
        }
    }

    // MARK: 5. Tapping a drink-soon row pushes the owned-bottle card

    func testDrinkSoonRowTappedPushesOwnedBottleCard() async {
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)
        let bottle = Bottle(id: "b-1", wineId: wine.id, quantity: 2, status: .cellared)
        let row = HomeBottleRow(bottle: bottle, wine: wine)

        let store = TestStore(initialState: HomeReducer.State()) {
            HomeReducer()
        }
        store.exhaustivity = .off

        await store.send(.drinkSoonRowTapped(row))

        guard case let .wineDetail(detail) = store.state.destination else {
            return XCTFail("expected wineDetail destination")
        }
        XCTAssertEqual(detail.wine, wine)
        XCTAssertEqual(detail.ownedBottle, bottle)
    }
}
