import Foundation

/// A family savings goal (Act V V4 — Money). Persisted at `households/{hid}/goals/{id}`.
///
/// Deliberately simple + warm: a name, a target, how much is set aside so far, an optional deadline,
/// and an optional monthly-contribution plan that powers the ETA. No account linkage — it's a jar the
/// family fills by hand ("contribute"). Decode-safe: partial/hand-written docs still resolve (only
/// `id` + `name` are hard, and even a zero target degrades gracefully).
public struct SavingsGoal: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The amount the family is saving toward (dollars).
    public var targetAmount: Double
    /// How much has been set aside so far (dollars).
    public var savedAmount: Double
    /// Optional deadline the family is aiming for.
    public var targetDate: Date?
    /// Optional planned monthly set-aside — drives the "on this pace, done by…" ETA when > 0.
    public var monthlyContribution: Double?
    /// Optional SF Symbol name for a little personality on the row (defaults to a piggy bank in UI).
    public var symbol: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        targetAmount: Double,
        savedAmount: Double = 0,
        targetDate: Date? = nil,
        monthlyContribution: Double? = nil,
        symbol: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.targetAmount = targetAmount
        self.savedAmount = savedAmount
        self.targetDate = targetDate
        self.monthlyContribution = monthlyContribution
        self.symbol = symbol
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Savings goal"
        targetAmount = try c.decodeIfPresent(Double.self, forKey: .targetAmount) ?? 0
        savedAmount = try c.decodeIfPresent(Double.self, forKey: .savedAmount) ?? 0
        targetDate = try c.decodeIfPresent(Date.self, forKey: .targetDate)
        monthlyContribution = try c.decodeIfPresent(Double.self, forKey: .monthlyContribution)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    // MARK: Derived

    /// 0…1 progress toward the target (clamped; 1 when the target is unset/zero but money is saved).
    public var progress: Double {
        guard targetAmount > 0 else { return savedAmount > 0 ? 1 : 0 }
        return min(max(savedAmount / targetAmount, 0), 1)
    }

    /// Dollars still to save (0 once met).
    public var remaining: Double { max(0, targetAmount - savedAmount) }

    /// True once fully funded.
    public var isComplete: Bool { targetAmount > 0 && savedAmount >= targetAmount }

    /// Whole months left at the planned monthly pace (nil when no positive plan or already done).
    public func monthsToGoal() -> Int? {
        guard let monthly = monthlyContribution, monthly > 0, remaining > 0 else { return nil }
        return Int((remaining / monthly).rounded(.up))
    }

    /// Estimated finish date at the planned monthly pace (nil when no plan / already done).
    public func etaDate(from now: Date, calendar: Calendar = .current) -> Date? {
        guard let months = monthsToGoal() else { return nil }
        return calendar.date(byAdding: .month, value: months, to: now)
    }

    /// True when a deadline is set and the planned pace won't reach it in time (a gentle heads-up).
    public func isBehindPace(now: Date, calendar: Calendar = .current) -> Bool {
        guard let target = targetDate, let eta = etaDate(from: now, calendar: calendar) else { return false }
        return eta > target
    }
}
