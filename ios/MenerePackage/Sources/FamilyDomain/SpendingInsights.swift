import Foundation

/// Pure spending-intelligence aggregator for the P22 Money "insights" surface.
///
/// The spending picture is **Expenses ⊕ Family-Brain financial documents**: manual/promoted
/// `Expense`s unioned with `Document`s that carry an amount AND read as a receipt/invoice/bill
/// (`isSpendDocument`), **deduped** so a Brain doc already promoted to an Expense (via
/// `Expense.documentId`) is never double-counted — the same key the "New from the Brain" inbox uses.
///
/// Each line is categorised (the Expense's own category, else derived from the doc's signals) and
/// very large one-time items (a mortgage closing disclosure, a whole-deck contract) are flagged
/// `isOneTime` so they land in a distinct "One-time / Housing" bucket and never skew a month's total
/// or the month-over-month trend.
///
/// UI-free + deterministic (no `Date()` reads — everything derives from the passed month), so it's
/// unit-testable and reusable anywhere spend is summarised.
public enum SpendingInsights {
    /// Amounts at or above this are treated as one-time / housing (closing disclosures, big
    /// renovations) rather than ordinary monthly spend. A single family line item this large is
    /// almost always a one-off, so it's kept out of monthly totals + trends.
    public static let oneTimeThreshold: Double = 5_000

    // MARK: Line

    /// One normalised spend line — from an `Expense` or a Brain `Document`.
    public struct Line: Equatable, Sendable, Identifiable {
        public var id: String
        public var amount: Double
        public var vendor: String?
        public var category: ExpenseCategory
        public var date: Date
        /// True for very large one-time items — excluded from monthly totals + trends.
        public var isOneTime: Bool

        public init(id: String, amount: Double, vendor: String?, category: ExpenseCategory, date: Date, isOneTime: Bool) {
            self.id = id
            self.amount = amount
            self.vendor = vendor
            self.category = category
            self.date = date
            self.isOneTime = isOneTime
        }
    }

    // MARK: Report pieces

    /// One category's slice of a total (this-month or all-time).
    public struct CategoryBreakdown: Equatable, Sendable, Identifiable {
        public var category: ExpenseCategory
        public var amount: Double
        /// 0…1 share of the total it belongs to.
        public var fraction: Double
        public var id: String { category.rawValue }

        public init(category: ExpenseCategory, amount: Double, fraction: Double) {
            self.category = category
            self.amount = amount
            self.fraction = fraction
        }
    }

    /// This month vs the previous month with data.
    public struct Trend: Equatable, Sendable {
        public var current: Double
        /// `nil` when there's no prior-month spend to compare against.
        public var previous: Double?

        public init(current: Double, previous: Double?) {
            self.current = current
            self.previous = previous
        }

        /// Signed change from previous → current (0 when no prior month).
        public var delta: Double { current - (previous ?? current) }
        public var hasComparison: Bool { previous != nil }
        public var isUp: Bool { delta > 0.005 }
        public var isDown: Bool { delta < -0.005 }
        /// Fractional change (e.g. 0.2 = +20%); `nil` when no/zero prior.
        public var fraction: Double? {
            guard let previous, previous > 0 else { return nil }
            return (current - previous) / previous
        }
    }

    /// A vendor seen in ≥2 distinct months — a likely recurring charge.
    public struct RecurringVendor: Equatable, Sendable, Identifiable {
        public var name: String
        public var averageAmount: Double
        /// Distinct calendar months the vendor appears in.
        public var monthCount: Int
        public var category: ExpenseCategory
        public var id: String { name.lowercased() }

        public init(name: String, averageAmount: Double, monthCount: Int, category: ExpenseCategory) {
            self.name = name
            self.averageAmount = averageAmount
            self.monthCount = monthCount
            self.category = category
        }
    }

    /// A seasonal spend note ("this summer, ~$X went to the garden").
    public struct SeasonalHint: Equatable, Sendable {
        public var season: String
        public var category: ExpenseCategory
        public var amount: Double

        public init(season: String, category: ExpenseCategory, amount: Double) {
            self.season = season
            self.category = category
            self.amount = amount
        }
    }

    /// The full insights report for a featured month + the whole spending history.
    public struct Report: Equatable, Sendable {
        /// First-of-month anchor of the featured month.
        public var monthStart: Date
        /// Featured month total (one-time items excluded).
        public var total: Double
        /// Featured-month category breakdown, spend-descending.
        public var breakdown: [CategoryBreakdown]
        /// The featured month's individual lines (fuel for the AI summary), newest first.
        public var monthLines: [Line]
        public var trend: Trend
        /// Vendors recurring across ≥2 months (all history), most-frequent first.
        public var recurring: [RecurringVendor]
        /// Sum of one-time / housing items across all history.
        public var oneTimeTotal: Double
        public var oneTimeLines: [Line]
        /// Every-month-combined category breakdown (one-time excluded).
        public var allTimeByCategory: [CategoryBreakdown]
        public var allTimeTotal: Double
        public var seasonalHint: SeasonalHint?

        public var isEmptyMonth: Bool { monthLines.isEmpty }

        public init(
            monthStart: Date,
            total: Double,
            breakdown: [CategoryBreakdown],
            monthLines: [Line],
            trend: Trend,
            recurring: [RecurringVendor],
            oneTimeTotal: Double,
            oneTimeLines: [Line],
            allTimeByCategory: [CategoryBreakdown],
            allTimeTotal: Double,
            seasonalHint: SeasonalHint?
        ) {
            self.monthStart = monthStart
            self.total = total
            self.breakdown = breakdown
            self.monthLines = monthLines
            self.trend = trend
            self.recurring = recurring
            self.oneTimeTotal = oneTimeTotal
            self.oneTimeLines = oneTimeLines
            self.allTimeByCategory = allTimeByCategory
            self.allTimeTotal = allTimeTotal
            self.seasonalHint = seasonalHint
        }
    }

    // MARK: Spend-document classifier

    /// Keywords that mark a doc as an actual spend (money changed / is owed): receipts, invoices,
    /// bills, statements, tuition/fees, and closing disclosures (the record of money paid at closing).
    static let receiptKeywords = [
        "receipt", "invoice", "bill", "statement", "closing disclosure", "tuition", "fee",
    ]
    /// Keywords that mark a doc as NOT-yet-spent (an estimate or a loan figure): quotes, underwriting,
    /// commitment letters. Excluded unless the doc ALSO carries an explicit receipt/invoice signal.
    static let notSpendKeywords = [
        "quote", "estimate", "underwriting", "commitment", "pre-approval", "sales agreement", "pre-inspection",
    ]
    /// Document types that imply real spend when they carry an amount (a vet/medical bill, school fees).
    static let spendTypes: Set<DocumentType> = [.receipt, .school, .medical, .pet]

    /// True when a Family-Brain document represents actual spending (so it belongs in the ledger union).
    /// Requires a positive amount, excludes quotes/loan figures, and includes receipts/invoices/bills
    /// plus billed document types (school/medical/pet with an amount).
    public static func isSpendDocument(_ doc: Document) -> Bool {
        guard let amount = doc.amount, amount > 0 else { return false }
        let signals = (doc.tags + [doc.vendor ?? "", doc.title, doc.type.rawValue])
            .map { $0.lowercased() }
            .joined(separator: " ")
        let hasReceiptSignal = receiptKeywords.contains { signals.contains($0) }
        let hasNotSpend = notSpendKeywords.contains { signals.contains($0) }
        if hasNotSpend && !hasReceiptSignal { return false }
        if spendTypes.contains(doc.type) { return true }
        return hasReceiptSignal
    }

    // MARK: Union → lines

    /// Union manual/promoted `Expense`s with amount-bearing spend `Document`s, **deduping** any doc
    /// already promoted to an expense (matched on `Expense.documentId`). Each line is categorised and
    /// flagged one-time when at/above `oneTimeThreshold`.
    public static func lines(expenses: [Expense], documents: [Document]) -> [Line] {
        var out: [Line] = []
        out.reserveCapacity(expenses.count + documents.count)

        for e in expenses {
            out.append(Line(
                id: "exp_\(e.id)",
                amount: e.amount,
                vendor: e.vendor,
                category: e.category,
                date: e.date,
                isOneTime: e.amount >= oneTimeThreshold
            ))
        }

        // Dedup: any Brain doc already promoted to an Expense is represented by that Expense — skip it.
        let promoted = Set(expenses.compactMap(\.documentId))
        for d in documents {
            guard isSpendDocument(d), let amount = d.amount, amount > 0 else { continue }
            if promoted.contains(d.id) { continue }
            out.append(Line(
                id: "doc_\(d.id)",
                amount: amount,
                vendor: d.vendor,
                category: d.suggestedExpenseCategory,
                date: d.docDate ?? d.createdAt,
                isOneTime: amount >= oneTimeThreshold
            ))
        }
        return out
    }

    // MARK: Report

    /// Build the insights report for the featured `month` (defaults to the lines' own dates for the
    /// month view). All-history pieces (recurring, one-time, all-time, seasonal) span every line.
    public static func report(
        expenses: [Expense],
        documents: [Document],
        month: Date,
        calendar: Calendar = .current
    ) -> Report {
        let all = lines(expenses: expenses, documents: documents)
        let monthly = all.filter { !$0.isOneTime }

        // Featured month.
        let (start, end) = MoneyRollup.monthRange(containing: month, calendar: calendar)
        let thisMonth = monthly.filter { $0.date >= start && $0.date < end }.sorted { $0.date > $1.date }
        let total = thisMonth.reduce(0) { $0 + $1.amount }
        let breakdown = breakdownLines(thisMonth, total: total)

        // Trend vs previous month.
        let prevStart = calendar.date(byAdding: .month, value: -1, to: start) ?? start
        let prevMonth = monthly.filter { $0.date >= prevStart && $0.date < start }
        let prevTotal = prevMonth.reduce(0) { $0 + $1.amount }
        let trend = Trend(current: total, previous: prevMonth.isEmpty ? nil : prevTotal)

        // Recurring across all months.
        let recurring = recurringVendors(from: monthly, calendar: calendar)

        // One-time / housing.
        let oneTimes = all.filter { $0.isOneTime }.sorted { $0.amount > $1.amount }
        let oneTimeTotal = oneTimes.reduce(0) { $0 + $1.amount }

        // All-time by category.
        let allTotal = monthly.reduce(0) { $0 + $1.amount }
        let allTime = breakdownLines(monthly, total: allTotal)

        let seasonal = seasonalHint(from: monthly, month: month, calendar: calendar)

        return Report(
            monthStart: start,
            total: total,
            breakdown: breakdown,
            monthLines: thisMonth,
            trend: trend,
            recurring: recurring,
            oneTimeTotal: oneTimeTotal,
            oneTimeLines: oneTimes,
            allTimeByCategory: allTime,
            allTimeTotal: allTotal,
            seasonalHint: seasonal
        )
    }

    // MARK: Helpers

    private static func breakdownLines(_ lines: [Line], total: Double) -> [CategoryBreakdown] {
        var byCategory: [ExpenseCategory: Double] = [:]
        for l in lines { byCategory[l.category, default: 0] += l.amount }
        return byCategory
            .map { CategoryBreakdown(category: $0.key, amount: $0.value, fraction: total > 0 ? $0.value / total : 0) }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.category.displayName < $1.category.displayName }
    }

    private static func recurringVendors(from lines: [Line], calendar: Calendar) -> [RecurringVendor] {
        var byVendor: [String: [Line]] = [:]
        for l in lines {
            guard let raw = l.vendor?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            byVendor[raw.lowercased(), default: []].append(l)
        }
        var out: [RecurringVendor] = []
        for (_, group) in byVendor {
            let months = Set(group.map { yearMonth(from: $0.date, calendar: calendar) })
            guard months.count >= 2 else { continue }
            let name = group.first?.vendor ?? ""
            let avg = group.reduce(0) { $0 + $1.amount } / Double(group.count)
            out.append(RecurringVendor(
                name: name,
                averageAmount: avg,
                monthCount: months.count,
                category: mostCommonCategory(group)
            ))
        }
        return out.sorted {
            $0.monthCount != $1.monthCount ? $0.monthCount > $1.monthCount : $0.averageAmount > $1.averageAmount
        }
    }

    private static func mostCommonCategory(_ lines: [Line]) -> ExpenseCategory {
        var counts: [ExpenseCategory: Int] = [:]
        for l in lines { counts[l.category, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? .other
    }

    private static func yearMonth(from date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.year ?? 0) * 100 + (c.month ?? 0)
    }

    /// (name, months) of the meteorological season containing `month`.
    static func season(of month: Date, calendar: Calendar) -> (name: String, months: Set<Int>) {
        let m = calendar.component(.month, from: month)
        switch m {
        case 12, 1, 2: return ("winter", [12, 1, 2])
        case 3, 4, 5: return ("spring", [3, 4, 5])
        case 6, 7, 8: return ("summer", [6, 7, 8])
        default: return ("fall", [9, 10, 11])
        }
    }

    /// A seasonal note when garden spend is present in the featured month's season (the roadmap's
    /// "~$X/season on the garden" example). Returns `nil` — gracefully — when there's nothing to say.
    private static func seasonalHint(from lines: [Line], month: Date, calendar: Calendar) -> SeasonalHint? {
        let s = season(of: month, calendar: calendar)
        let seasonLines = lines.filter { s.months.contains(calendar.component(.month, from: $0.date)) }
        let garden = seasonLines.filter { $0.category == .garden }.reduce(0) { $0 + $1.amount }
        guard garden > 0 else { return nil }
        return SeasonalHint(season: s.name, category: .garden, amount: garden)
    }
}
