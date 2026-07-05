import FamilyDomain
import Foundation
import XCTest

@testable import MoneyFeature

/// Pure coverage for the P22.1 forward-looking spend: the recurring-bill forecast (cadence +
/// next-occurrence projection) and the planned-spending rollup over wishlist/gift/project lists.
final class SpendingForecastTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func expense(_ vendor: String, _ amount: Double, _ y: Int, _ m: Int, _ d: Int, _ cat: ExpenseCategory = .kids) -> Expense {
        Expense(amount: amount, vendor: vendor, category: cat, date: date(y, m, d))
    }

    // MARK: Forecast

    func testMonthlyVendorProjectsNextMonth() {
        // Kindercare seen May/Jun/Jul → monthly cadence, last seen Jul 1, "now" mid-Jul → next Aug 1.
        let expenses = [
            expense("Kindercare", 175, 2026, 5, 1),
            expense("Kindercare", 175, 2026, 6, 1),
            expense("Kindercare", 175, 2026, 7, 1),
        ]
        let report = SpendingInsights.report(expenses: expenses, documents: [], month: date(2026, 7, 15), calendar: utc)
        let upcoming = SpendingForecast.upcoming(
            expenses: expenses, documents: [], recurring: report.recurring,
            now: date(2026, 7, 15), calendar: utc
        )
        XCTAssertEqual(upcoming.count, 1)
        let k = try? XCTUnwrap(upcoming.first)
        XCTAssertEqual(k?.name, "Kindercare")
        XCTAssertEqual(k?.cadenceMonths, 1)
        XCTAssertEqual(k?.typicalAmount ?? 0, 175, accuracy: 0.01)
        XCTAssertEqual(utc.dateComponents([.year, .month], from: k!.nextDate), DateComponents(year: 2026, month: 8))
    }

    func testStaleVendorRollsForwardPastNow() {
        // Last seen Jan, monthly, "now" is July → the *next* expected charge is Aug, not Feb.
        let expenses = [
            expense("Netflix", 20, 2025, 12, 5, .fun),
            expense("Netflix", 20, 2026, 1, 5, .fun),
        ]
        let report = SpendingInsights.report(expenses: expenses, documents: [], month: date(2026, 7, 1), calendar: utc)
        let upcoming = SpendingForecast.upcoming(
            expenses: expenses, documents: [], recurring: report.recurring,
            now: date(2026, 7, 15), calendar: utc
        )
        let n = try? XCTUnwrap(upcoming.first)
        XCTAssertGreaterThanOrEqual(n!.nextDate, date(2026, 7, 15))
        XCTAssertEqual(utc.dateComponents([.year, .month], from: n!.nextDate), DateComponents(year: 2026, month: 8))
    }

    func testSortedSoonestFirst() {
        let expenses = [
            expense("Kindercare", 175, 2026, 6, 1),
            expense("Kindercare", 175, 2026, 7, 1),
            expense("Water", 60, 2026, 5, 20, .house),
            expense("Water", 60, 2026, 7, 20, .house), // every 2 months → next ~Sep 20
        ]
        let report = SpendingInsights.report(expenses: expenses, documents: [], month: date(2026, 7, 15), calendar: utc)
        let upcoming = SpendingForecast.upcoming(
            expenses: expenses, documents: [], recurring: report.recurring,
            now: date(2026, 7, 15), calendar: utc
        )
        XCTAssertEqual(upcoming.map(\.name), ["Kindercare", "Water"])
        XCTAssertTrue(upcoming[0].nextDate <= upcoming[1].nextDate)
    }

    func testNoRecurringVendorsIsEmpty() {
        let upcoming = SpendingForecast.upcoming(expenses: [], documents: [], recurring: [], now: date(2026, 7, 1), calendar: utc)
        XCTAssertTrue(upcoming.isEmpty)
    }

    // MARK: Planned rollup

    func testPlannedRollupSumsUnboughtByType() {
        let wish = FamilyList(id: "w", title: "Costco run", listType: .wishlist)
        let gift = FamilyList(id: "g", title: "Christmas", listType: .gift)
        let proj = FamilyList(id: "p", title: "Deck", listType: .project)
        let standard = FamilyList(id: "s", title: "Groceries", listType: .standard) // ignored

        let items: [String: [ListItem]] = [
            "w": [
                ListItem(title: "Robot vac", listID: "w", price: 300),
                ListItem(title: "Blender", isCompleted: true, listID: "w", price: 90), // bought → excluded
            ],
            "g": [ListItem(title: "Lego", listID: "g", price: 60)],
            "p": [
                ListItem(title: "Boards", listID: "p", projectStatus: .planning, budget: 4000),
                ListItem(title: "Old fence", listID: "p", projectStatus: .done, budget: 1000), // done → excluded
            ],
            "s": [ListItem(title: "Milk", listID: "s")],
        ]

        let rollup = PlannedSpending.rollup(lists: [wish, gift, proj, standard], itemsByList: items)
        XCTAssertEqual(rollup.wishlistTotal, 300, accuracy: 0.01)
        XCTAssertEqual(rollup.giftTotal, 60, accuracy: 0.01)
        XCTAssertEqual(rollup.projectTotal, 4000, accuracy: 0.01)
        XCTAssertEqual(rollup.total, 4360, accuracy: 0.01)
        XCTAssertEqual(rollup.wishlistLists, ["Costco run"])
        XCTAssertFalse(rollup.isEmpty)
    }

    func testPlannedRollupEmptyWhenNoPricedItems() {
        let wish = FamilyList(id: "w", title: "Ideas", listType: .wishlist)
        let rollup = PlannedSpending.rollup(lists: [wish], itemsByList: ["w": [ListItem(title: "Something", listID: "w")]])
        XCTAssertTrue(rollup.isEmpty)
        XCTAssertTrue(rollup.wishlistLists.isEmpty)
    }
}
