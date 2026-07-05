import FamilyDomain
import Foundation

/// P22.1 — forward-looking spend, computed purely on top of the existing `SpendingInsights` union.
///
/// Two read-only projections that turn Money from a rear-view mirror into a windshield:
///  1. **`SpendingForecast`** — the *next expected* charge for each recurring vendor (last-seen date
///     advanced by the vendor's typical month cadence). Honest about being an estimate.
///  2. **`PlannedSpending`** — intended future spend the family has already jotted into lists:
///     unbought wishlist + gift `price`s and open project `budget`s.
///
/// Both are UI-free + deterministic (a passed `now`, no `Date()` reads), so they're unit-testable and
/// reusable. Neither writes anything — pure aggregation over data other features own.
public enum SpendingForecast {
    /// One projected upcoming charge from a recurring vendor.
    public struct Upcoming: Equatable, Sendable, Identifiable {
        public var name: String
        /// The vendor's typical (average) charge — an estimate, not a bill.
        public var typicalAmount: Double
        /// The projected next occurrence: last-seen advanced by `cadenceMonths`, rolled to on/after `now`.
        public var nextDate: Date
        public var category: ExpenseCategory
        /// Typical months between charges (1 = monthly). Drives the projection + the "every N months" copy.
        public var cadenceMonths: Int
        public var id: String { name.lowercased() }

        public init(name: String, typicalAmount: Double, nextDate: Date, category: ExpenseCategory, cadenceMonths: Int) {
            self.name = name
            self.typicalAmount = typicalAmount
            self.nextDate = nextDate
            self.category = category
            self.cadenceMonths = cadenceMonths
        }
    }

    /// Project the next expected occurrence of each already-detected recurring vendor.
    ///
    /// Takes the `recurring` vendors straight from `SpendingInsights.Report` (the ≥2-distinct-month
    /// rule) so "Coming up" always mirrors "Looks recurring", then times each one from the raw lines:
    /// last-seen date + the vendor's typical month cadence, rolled forward to the first occurrence
    /// on/after `now`. Sorted soonest-first.
    public static func upcoming(
        expenses: [Expense],
        documents: [Document],
        recurring: [SpendingInsights.RecurringVendor],
        now: Date,
        calendar: Calendar = .current
    ) -> [Upcoming] {
        guard !recurring.isEmpty else { return [] }

        // Same non-one-time universe the recurring detector uses, grouped by lowercased vendor.
        var byVendor: [String: [SpendingInsights.Line]] = [:]
        for line in SpendingInsights.lines(expenses: expenses, documents: documents) where !line.isOneTime {
            guard let raw = line.vendor?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            byVendor[raw.lowercased(), default: []].append(line)
        }

        var out: [Upcoming] = []
        for vendor in recurring {
            let group = byVendor[vendor.id] ?? []
            guard let lastSeen = group.map(\.date).max() else { continue }
            let cadence = cadenceMonths(for: group, calendar: calendar)
            let next = nextOccurrence(after: lastSeen, cadenceMonths: cadence, notBefore: now, calendar: calendar)
            out.append(Upcoming(
                name: vendor.name,
                typicalAmount: vendor.averageAmount,
                nextDate: next,
                category: vendor.category,
                cadenceMonths: cadence
            ))
        }
        return out.sorted { $0.nextDate < $1.nextDate }
    }

    /// The typical whole-month gap between a vendor's distinct calendar months (min 1 = monthly).
    static func cadenceMonths(for lines: [SpendingInsights.Line], calendar: Calendar = .current) -> Int {
        let months = Set(lines.map { monthIndex($0.date, calendar: calendar) }).sorted()
        guard months.count >= 2 else { return 1 }
        var gaps: [Int] = []
        for i in 1..<months.count { gaps.append(months[i] - months[i - 1]) }
        let avg = Double(gaps.reduce(0, +)) / Double(gaps.count)
        return max(1, Int(avg.rounded()))
    }

    /// First `lastSeen + k·cadence` (k ≥ 1) that lands on/after `notBefore` — the *next* expected
    /// charge from today's vantage, even if the data is stale. Guarded against runaway loops.
    static func nextOccurrence(after lastSeen: Date, cadenceMonths: Int, notBefore: Date, calendar: Calendar) -> Date {
        var candidate = calendar.date(byAdding: .month, value: cadenceMonths, to: lastSeen) ?? lastSeen
        var guardCount = 0
        while candidate < notBefore, guardCount < 600 {
            candidate = calendar.date(byAdding: .month, value: cadenceMonths, to: candidate) ?? candidate
            guardCount += 1
        }
        return candidate
    }

    /// Absolute month count (year·12 + month), so gaps are real month differences across year boundaries.
    private static func monthIndex(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.year ?? 0) * 12 + (c.month ?? 0)
    }
}

/// Intended future spend already captured in the family's lists (P30/P30.5): unbought wishlist +
/// gift `price`s and open project `budget`s. Read-only — Money reflects what's *planned*, not just
/// what's past. Source list titles ride along so the UI can name where each figure comes from.
public enum PlannedSpending {
    public struct Rollup: Equatable, Sendable {
        public var wishlistTotal: Double
        public var giftTotal: Double
        public var projectTotal: Double
        /// Titles of the source lists contributing to each bucket (for "in your Costco run" copy).
        public var wishlistLists: [String]
        public var giftLists: [String]
        public var projectLists: [String]

        public static let empty = Rollup(
            wishlistTotal: 0, giftTotal: 0, projectTotal: 0,
            wishlistLists: [], giftLists: [], projectLists: []
        )

        public init(
            wishlistTotal: Double, giftTotal: Double, projectTotal: Double,
            wishlistLists: [String], giftLists: [String], projectLists: [String]
        ) {
            self.wishlistTotal = wishlistTotal
            self.giftTotal = giftTotal
            self.projectTotal = projectTotal
            self.wishlistLists = wishlistLists
            self.giftLists = giftLists
            self.projectLists = projectLists
        }

        public var total: Double { wishlistTotal + giftTotal + projectTotal }
        public var isEmpty: Bool { total <= 0 }
    }

    /// Roll up planned spend across the given lists. Wishlist/gift buckets sum **unbought** item
    /// `price`s (bought reuses `isCompleted`); the project bucket sums **not-done** item `budget`s.
    /// A list contributes to a bucket only when its own sum is > 0 (so empty lists stay silent).
    public static func rollup(lists: [FamilyList], itemsByList: [String: [ListItem]]) -> Rollup {
        var wishlistTotal = 0.0, giftTotal = 0.0, projectTotal = 0.0
        var wishlistLists: [String] = [], giftLists: [String] = [], projectLists: [String] = []

        for list in lists {
            let items = itemsByList[list.id] ?? []
            if list.isWishlist {
                let sum = items.filter { !$0.isCompleted }.compactMap(\.price).reduce(0, +)
                if sum > 0 { wishlistTotal += sum; wishlistLists.append(list.title) }
            } else if list.isGift {
                let sum = items.filter { !$0.isCompleted }.compactMap(\.price).reduce(0, +)
                if sum > 0 { giftTotal += sum; giftLists.append(list.title) }
            } else if list.isProject {
                let sum = items.filter { $0.effectiveProjectStatus != .done }.compactMap(\.budget).reduce(0, +)
                if sum > 0 { projectTotal += sum; projectLists.append(list.title) }
            }
        }

        return Rollup(
            wishlistTotal: wishlistTotal, giftTotal: giftTotal, projectTotal: projectTotal,
            wishlistLists: wishlistLists, giftLists: giftLists, projectLists: projectLists
        )
    }
}
