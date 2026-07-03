import FamilyDomain
import Foundation
import XCTest

/// Pure coverage for the Money domain: monthly rollup math (boundaries, category grouping,
/// over-budget), the category auto-suggest keyword map, and Expense/BudgetConfig decode-safety.
final class MoneyRollupTests: XCTestCase {
    /// A UTC calendar so month boundaries are deterministic regardless of the runner's timezone.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: Month boundaries

    func testMonthRangeAndBoundaryInclusion() {
        let anchor = date(2026, 7, 15)
        let (start, end) = MoneyRollup.monthRange(containing: anchor, calendar: utc)
        XCTAssertEqual(utc.dateComponents([.year, .month, .day], from: start), DateComponents(year: 2026, month: 7, day: 1))
        XCTAssertEqual(utc.dateComponents([.year, .month, .day], from: end), DateComponents(year: 2026, month: 8, day: 1))

        // Last instant of June and first of August are OUT; July days are IN.
        XCTAssertFalse(MoneyRollup.isInMonth(date(2026, 6, 30), of: anchor, calendar: utc))
        XCTAssertTrue(MoneyRollup.isInMonth(date(2026, 7, 1), of: anchor, calendar: utc))
        XCTAssertTrue(MoneyRollup.isInMonth(date(2026, 7, 31), of: anchor, calendar: utc))
        XCTAssertFalse(MoneyRollup.isInMonth(date(2026, 8, 1), of: anchor, calendar: utc))
    }

    func testShiftMonthWrapsYear() {
        let jan = MoneyRollup.shiftMonth(date(2026, 1, 10), by: -1, calendar: utc)
        XCTAssertEqual(utc.dateComponents([.year, .month, .day], from: jan), DateComponents(year: 2025, month: 12, day: 1))
        let feb = MoneyRollup.shiftMonth(date(2026, 12, 20), by: 2, calendar: utc)
        XCTAssertEqual(utc.dateComponents([.year, .month, .day], from: feb), DateComponents(year: 2027, month: 2, day: 1))
    }

    // MARK: Category grouping + total

    func testSummaryGroupsByCategoryAndExcludesOtherMonths() {
        let expenses = [
            Expense(amount: 100, category: .groceries, date: date(2026, 7, 3)),
            Expense(amount: 50, category: .groceries, date: date(2026, 7, 20)),
            Expense(amount: 40, category: .dining, date: date(2026, 7, 10)),
            Expense(amount: 999, category: .kids, date: date(2026, 6, 30)),   // previous month → excluded
            Expense(amount: 999, category: .fun, date: date(2026, 8, 1)),     // next month → excluded
        ]
        let summary = MoneyRollup.summary(expenses: expenses, budgets: nil, month: date(2026, 7, 15), calendar: utc)
        XCTAssertEqual(summary.total, 190)
        // Sorted spend-descending: groceries (150) then dining (40).
        XCTAssertEqual(summary.lines.map(\.category), [.groceries, .dining])
        XCTAssertEqual(summary.lines.first?.spent, 150)
        XCTAssertEqual(summary.maxSpend, 150)
    }

    func testBudgetedButUnspentCategoryStillAppears() {
        let budgets = BudgetConfig(limits: ["kids": 500])
        let summary = MoneyRollup.summary(
            expenses: [Expense(amount: 30, category: .dining, date: date(2026, 7, 4))],
            budgets: budgets, month: date(2026, 7, 15), calendar: utc
        )
        // Dining has spend; Kids has a budget but no spend — both show.
        XCTAssertTrue(summary.lines.contains { $0.category == .kids && $0.spent == 0 && $0.limit == 500 })
        XCTAssertTrue(summary.lines.contains { $0.category == .dining })
    }

    // MARK: Over-budget detection + fill fractions

    func testOverBudgetDetectionAndOverBy() {
        let budgets = BudgetConfig(limits: ["kids": 500, "garden": 100])
        let expenses = [
            Expense(amount: 620, category: .kids, date: date(2026, 7, 5)),
            Expense(amount: 60, category: .garden, date: date(2026, 7, 6)),
        ]
        let summary = MoneyRollup.summary(expenses: expenses, budgets: budgets, month: date(2026, 7, 15), calendar: utc)
        let kids = summary.lines.first { $0.category == .kids }!
        let garden = summary.lines.first { $0.category == .garden }!
        XCTAssertTrue(kids.isOverBudget)
        XCTAssertEqual(kids.overBy, 120)
        XCTAssertFalse(garden.isOverBudget)
        XCTAssertEqual(garden.overBy, 0)
        // Budgeted fill = spent/limit, clamped to 1 when over.
        XCTAssertEqual(kids.fillFraction(neutralMax: 620), 1, accuracy: 0.0001)
        XCTAssertEqual(garden.fillFraction(neutralMax: 620), 0.6, accuracy: 0.0001)
    }

    func testNeutralFillScalesToMonthMax() {
        // No budgets → bars scale to the month's largest category spend.
        let line = MoneyRollup.CategoryLine(category: .dining, spent: 40, limit: nil)
        XCTAssertEqual(line.fillFraction(neutralMax: 160), 0.25, accuracy: 0.0001)
        XCTAssertEqual(line.fillFraction(neutralMax: 0), 0, accuracy: 0.0001)
    }

    // MARK: Auto-suggest keyword map

    func testAutoSuggestKeywordMap() {
        XCTAssertEqual(ExpenseCategory.suggested(from: ["school", "childcare"]), .kids)
        XCTAssertEqual(ExpenseCategory.suggested(from: ["garden", "plants"]), .garden)
        XCTAssertEqual(ExpenseCategory.suggested(from: ["grocery run"]), .groceries)
        XCTAssertEqual(ExpenseCategory.suggested(from: ["Costco"]), .groceries)
        XCTAssertEqual(ExpenseCategory.suggested(from: ["Home Depot", "repair"]), .house)
        XCTAssertEqual(ExpenseCategory.suggested(from: ["vet visit"]), .pets)
        XCTAssertEqual(ExpenseCategory.suggested(from: ["something random"]), .other)
    }

    func testKindercareDocumentSuggestsKids() {
        // Mirrors Michael's real "Kindercare Fall Registration" doc (type .school, $175).
        let doc = Document(
            id: "doc-1",
            title: "Kindercare Fall Registration",
            type: .school,
            tags: ["kindercare", "registration", "fall-2026", "childcare", "fees"],
            amount: 175,
            vendor: "KinderCare - Heather Park",
            uploadedBy: "uid-1"
        )
        XCTAssertEqual(doc.suggestedExpenseCategory, .kids)
    }

    // MARK: Decode-safety

    func testExpenseDecodesFromMinimalPayload() throws {
        let json = Data(#"{"id":"e1","amount":42.5}"#.utf8)
        let expense = try JSONDecoder().decode(Expense.self, from: json)
        XCTAssertEqual(expense.id, "e1")
        XCTAssertEqual(expense.amount, 42.5)
        XCTAssertEqual(expense.category, .other)   // defaulted
        XCTAssertEqual(expense.source, .manual)    // defaulted
        XCTAssertNil(expense.vendor)
        XCTAssertNil(expense.documentId)
    }

    func testExpenseToleratesUnknownCategoryString() throws {
        // A newer client wrote a category we don't know → degrade to .other, don't fail the doc.
        let json = Data(#"{"id":"e1","amount":10,"category":"crypto"}"#.utf8)
        let expense = try JSONDecoder().decode(Expense.self, from: json)
        XCTAssertEqual(expense.category, .other)
    }

    func testBudgetConfigDecodesFromEmptyObject() throws {
        let empty = try JSONDecoder().decode(BudgetConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.limits.isEmpty)
        XCTAssertTrue(empty.dismissedDocumentIds.isEmpty)

        let partial = try JSONDecoder().decode(BudgetConfig.self, from: Data(#"{"limits":{"kids":500}}"#.utf8))
        XCTAssertEqual(partial.limit(for: .kids), 500)
        XCTAssertNil(partial.limit(for: .garden))
        XCTAssertTrue(partial.dismissedDocumentIds.isEmpty)
    }

    // MARK: Promotion helper

    func testPromotingDocumentBuildsLinkedExpense() {
        let now = date(2026, 7, 2)
        let doc = Document(
            id: "doc-9", title: "Green Thumb", type: .receipt,
            tags: ["garden", "plants"], amount: 84.12, vendor: "Green Thumb Nursery",
            uploadedBy: "uid-1"
        )
        let expense = Expense.promoting(document: doc, id: "exp-9", now: now)
        XCTAssertEqual(expense.amount, 84.12)
        XCTAssertEqual(expense.vendor, "Green Thumb Nursery")
        XCTAssertEqual(expense.category, .garden)
        XCTAssertEqual(expense.source, .receiptScan)
        XCTAssertEqual(expense.documentId, "doc-9")
        XCTAssertEqual(expense.date, now)   // no docDate → now
    }
}
