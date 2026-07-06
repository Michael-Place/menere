import Foundation

/// The family's proactive-notification preferences (Act V V2-E) — governs the **weekly family
/// digest** and the daily **"your 3 things"** nudge, both delivered by scheduled Cloud Functions
/// (`weeklyFamilyDigest` / `dailyThreeThings`). The functions read this doc and RESPECT it: skip when
/// a channel is off, only send the weekly digest on the chosen weekday, and never push inside quiet
/// hours.
///
/// A **household** setting (one calm cadence for the family), persisted at
/// `households/{hid}/config/notificationPrefs` — the same cheap config-doc pattern as the smart-home
/// configs and `BudgetConfig`. Every field is decode-safe with a sensible, calm default so a partial
/// or absent doc still resolves (an absent doc simply means "defaults").
public struct NotificationPrefs: Codable, Equatable, Sendable {
    /// Master switch for the Sunday-morning "week ahead" digest push. Default on.
    public var weeklyDigestEnabled: Bool
    /// Which day the weekly digest lands, as an Apple `Calendar` weekday (1 = Sunday … 7 = Saturday).
    /// Default Sunday (1). The scheduled function ticks daily and emits on this weekday.
    public var weeklyDigestWeekday: Int
    /// Master switch for the daily "your 3 things" nudge (only sent when there's something to say).
    /// Default on.
    public var dailyNudgeEnabled: Bool
    /// When true, no proactive push is sent inside `[quietHoursStart, quietHoursEnd)` (ET). Default off
    /// — the schedules already run at a civil hour — but available for anyone who wants it stricter.
    public var quietHoursEnabled: Bool
    /// Quiet-hours start hour, 0–23 (ET). Default 21:00.
    public var quietHoursStart: Int
    /// Quiet-hours end hour, 0–23 (ET). Default 07:00. A window that wraps midnight (start > end) is
    /// treated as overnight by the delivery gate.
    public var quietHoursEnd: Int

    public init(
        weeklyDigestEnabled: Bool = true,
        weeklyDigestWeekday: Int = 1,
        dailyNudgeEnabled: Bool = true,
        quietHoursEnabled: Bool = false,
        quietHoursStart: Int = 21,
        quietHoursEnd: Int = 7
    ) {
        self.weeklyDigestEnabled = weeklyDigestEnabled
        self.weeklyDigestWeekday = Self.clampWeekday(weeklyDigestWeekday)
        self.dailyNudgeEnabled = dailyNudgeEnabled
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHoursStart = Self.clampHour(quietHoursStart)
        self.quietHoursEnd = Self.clampHour(quietHoursEnd)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weeklyDigestEnabled = try c.decodeIfPresent(Bool.self, forKey: .weeklyDigestEnabled) ?? true
        weeklyDigestWeekday = Self.clampWeekday(
            try c.decodeIfPresent(Int.self, forKey: .weeklyDigestWeekday) ?? 1)
        dailyNudgeEnabled = try c.decodeIfPresent(Bool.self, forKey: .dailyNudgeEnabled) ?? true
        quietHoursEnabled = try c.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? false
        quietHoursStart = Self.clampHour(try c.decodeIfPresent(Int.self, forKey: .quietHoursStart) ?? 21)
        quietHoursEnd = Self.clampHour(try c.decodeIfPresent(Int.self, forKey: .quietHoursEnd) ?? 7)
    }

    private static func clampWeekday(_ v: Int) -> Int { min(7, max(1, v)) }
    private static func clampHour(_ v: Int) -> Int { min(23, max(0, v)) }

    // MARK: Display helpers (UI-free — the Settings picker reads these)

    /// Weekday choices in picker order, as `(Apple weekday, name)` — Sunday … Saturday.
    public static let weekdayChoices: [(weekday: Int, name: String)] = [
        (1, "Sunday"), (2, "Monday"), (3, "Tuesday"), (4, "Wednesday"),
        (5, "Thursday"), (6, "Friday"), (7, "Saturday"),
    ]

    /// The name of an Apple-weekday value ("Sunday" … "Saturday"); "Sunday" for anything out of range.
    public static func weekdayName(_ weekday: Int) -> String {
        weekdayChoices.first { $0.weekday == weekday }?.name ?? "Sunday"
    }

    /// A 12-hour clock label for an hour-of-day, e.g. `21 → "9 PM"`, `7 → "7 AM"`, `0 → "12 AM"`.
    public static func hourLabel(_ hour: Int) -> String {
        let h = min(23, max(0, hour))
        let period = h < 12 ? "AM" : "PM"
        let display = h % 12 == 0 ? 12 : h % 12
        return "\(display) \(period)"
    }

    /// A short summary line for a Settings row subtitle — "Weekly on Sunday · daily 3 things".
    public var summaryLine: String {
        var parts: [String] = []
        if weeklyDigestEnabled { parts.append("Weekly on \(Self.weekdayName(weeklyDigestWeekday))") }
        if dailyNudgeEnabled { parts.append("daily 3 things") }
        if parts.isEmpty { return "All quiet" }
        return parts.joined(separator: " · ")
    }
}
