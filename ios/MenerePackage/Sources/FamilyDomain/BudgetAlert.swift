import Foundation

/// Where a budgeted category sits this month (Act V V4 — per-category alerts). Pure + deterministic,
/// so Money surfaces it and the Radar/Today could later read the same flag without recomputing.
public enum BudgetStatus: String, Sendable, Equatable {
    /// Under budget and on pace — nothing to say.
    case under
    /// Not over yet, but at the current daily pace it's projected to blow past the limit this month.
    case trendingOver
    /// Already spent past the monthly limit.
    case over
}

/// One category's budget alert for a month.
public struct BudgetAlert: Equatable, Identifiable, Sendable {
    public var category: ExpenseCategory
    public var status: BudgetStatus
    public var spent: Double
    public var limit: Double
    /// End-of-month projection (spent extrapolated by how much of the month has elapsed).
    public var projected: Double
    public var id: String { category.rawValue }

    public init(category: ExpenseCategory, status: BudgetStatus, spent: Double, limit: Double, projected: Double) {
        self.category = category
        self.status = status
        self.spent = spent
        self.limit = limit
        self.projected = projected
    }

    /// Dollars over the limit (0 unless already over).
    public var overBy: Double { max(0, spent - limit) }
    /// Projected dollars over the limit at month's end (0 when the projection stays under).
    public var projectedOverBy: Double { max(0, projected - limit) }
}

/// Budget-alert math over a `MoneyRollup.MonthSummary`. `monthProgress` is the 0…1 fraction of the
/// anchored month that has elapsed (1 for any fully-past month), which turns spend-to-date into an
/// end-of-month projection for the "trending over" heads-up.
public enum BudgetAlerts {
    /// Ignore trending-over noise in the first few days of a month (a single big buy would always
    /// project "over" on day 2). Over-budget is always reported regardless of how far in we are.
    static let trendingFloor: Double = 0.12

    public static func projected(spent: Double, monthProgress: Double) -> Double {
        guard monthProgress > 0, monthProgress < 1 else { return spent }
        return spent / monthProgress
    }

    public static func status(spent: Double, limit: Double, monthProgress: Double) -> BudgetStatus {
        guard limit > 0 else { return .under }
        if spent > limit { return .over }
        let proj = projected(spent: spent, monthProgress: monthProgress)
        if monthProgress >= trendingFloor, proj > limit { return .trendingOver }
        return .under
    }

    /// Every budgeted category that's over or trending over this month, most-urgent first
    /// (over before trending, then by dollars past the line).
    public static func alerts(summary: MoneyRollup.MonthSummary, monthProgress: Double) -> [BudgetAlert] {
        var out: [BudgetAlert] = []
        for line in summary.lines {
            guard let limit = line.limit, limit > 0 else { continue }
            let s = status(spent: line.spent, limit: limit, monthProgress: monthProgress)
            guard s != .under else { continue }
            out.append(BudgetAlert(
                category: line.category,
                status: s,
                spent: line.spent,
                limit: limit,
                projected: projected(spent: line.spent, monthProgress: monthProgress)
            ))
        }
        return out.sorted { a, b in
            if a.status != b.status { return a.status == .over }
            return (a.status == .over ? a.overBy : a.projectedOverBy) > (b.status == .over ? b.overBy : b.projectedOverBy)
        }
    }
}
