import Foundation

/// Pure monthly-rollup math for the Money feature: filter expenses to a month, group + sum by
/// category, and fold in budgets (over-budget detection). UI-free and deterministic so it's covered
/// by unit tests and reused everywhere spend is summarized.
// SEAM (P13-C2): Today "This month" card reads the same monthly rollup.
// SEAM (P14): agent tools — month_summary returns this MonthSummary as its payload.
public enum MoneyRollup {
    /// One category's slice of a month: what was spent and the budget (if any).
    public struct CategoryLine: Equatable, Identifiable, Sendable {
        public var category: ExpenseCategory
        public var spent: Double
        public var limit: Double?

        public var id: String { category.rawValue }

        public init(category: ExpenseCategory, spent: Double, limit: Double?) {
            self.category = category
            self.spent = spent
            self.limit = limit
        }

        /// True when a budget is set and spending has passed it.
        public var isOverBudget: Bool {
            guard let limit else { return false }
            return spent > limit
        }

        /// Dollars over budget (0 when under or no budget).
        public var overBy: Double {
            guard let limit, spent > limit else { return 0 }
            return spent - limit
        }

        /// 0…1 fill fraction for the capsule bar. With a budget: spent/limit (clamped to 1). Without:
        /// spent/`neutralMax` (the month's largest category spend), so bars read relative to each other.
        public func fillFraction(neutralMax: Double) -> Double {
            if let limit, limit > 0 {
                return min(spent / limit, 1)
            }
            guard neutralMax > 0 else { return 0 }
            return min(spent / neutralMax, 1)
        }
    }

    /// A month's worth of spending, rolled up.
    public struct MonthSummary: Equatable, Sendable {
        /// Start-of-day of the first day of the month (the anchor the UI shows/navigates).
        public var monthStart: Date
        public var total: Double
        /// Category lines, spend-descending. Includes every category with spend > 0 OR a budget set.
        public var lines: [CategoryLine]

        public init(monthStart: Date, total: Double, lines: [CategoryLine]) {
            self.monthStart = monthStart
            self.total = total
            self.lines = lines
        }

        public var isEmpty: Bool { lines.isEmpty }

        /// The largest single-category spend this month — the scale for budget-less "neutral" bars.
        public var maxSpend: Double { lines.map(\.spent).max() ?? 0 }
    }

    /// The `[start, end)` half-open range of the calendar month containing `date`.
    public static func monthRange(containing date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let comps = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: comps) ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return (start, end)
    }

    /// True when `date` falls inside the calendar month containing `anchor`.
    public static func isInMonth(_ date: Date, of anchor: Date, calendar: Calendar = .current) -> Bool {
        let (start, end) = monthRange(containing: anchor, calendar: calendar)
        return date >= start && date < end
    }

    /// Shift a month anchor by `months` (negative = back). Returns the first day of the target month.
    public static func shiftMonth(_ anchor: Date, by months: Int, calendar: Calendar = .current) -> Date {
        let (start, _) = monthRange(containing: anchor, calendar: calendar)
        return calendar.date(byAdding: .month, value: months, to: start) ?? start
    }

    /// Roll up `expenses` for the month containing `month`, folding in `budgets`. A category appears
    /// when it has spend this month OR a budget set (so an unspent-but-budgeted category still shows
    /// its empty bar). Lines are sorted by spend descending, then display name for stability.
    public static func summary(
        expenses: [Expense],
        budgets: BudgetConfig?,
        month: Date,
        calendar: Calendar = .current
    ) -> MonthSummary {
        let (start, end) = monthRange(containing: month, calendar: calendar)
        let inMonth = expenses.filter { $0.date >= start && $0.date < end }

        var spendByCategory: [ExpenseCategory: Double] = [:]
        for e in inMonth { spendByCategory[e.category, default: 0] += e.amount }

        var lines: [CategoryLine] = []
        for category in ExpenseCategory.allCases {
            let spent = spendByCategory[category] ?? 0
            let limit = budgets?.limit(for: category)
            guard spent > 0 || limit != nil else { continue }
            lines.append(CategoryLine(category: category, spent: spent, limit: limit))
        }
        lines.sort {
            $0.spent != $1.spent ? $0.spent > $1.spent : $0.category.displayName < $1.category.displayName
        }

        let total = inMonth.reduce(0) { $0 + $1.amount }
        return MonthSummary(monthStart: start, total: total, lines: lines)
    }
}
