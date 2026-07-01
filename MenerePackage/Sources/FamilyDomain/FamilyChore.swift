import Foundation

public enum ChoreDifficulty: String, Codable, CaseIterable, Sendable, Equatable {
    case easy, medium, hard

    public var displayName: String { rawValue.capitalized }

    public var icon: String {
        switch self {
        case .easy: "star"
        case .medium: "star.leadinghalf.filled"
        case .hard: "star.fill"
        }
    }

    public var baseXP: Int {
        switch self {
        case .easy: 10
        case .medium: 25
        case .hard: 50
        }
    }
}

/// A family chore. Ported from Fambo's `Chore`, trimmed (dropped: maintenance-task templating,
/// categories). XP is awarded **client-side** (see `XPCalculator`) rather than by a Cloud Function.
///
/// Persisted at `households/{hid}/chores/{id}`.
public struct Chore: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var assigneeID: String?
    public var dueDate: Date?
    public var recurrence: RecurrenceOption
    public var difficulty: ChoreDifficulty
    public var isCompleted: Bool
    public var completedAt: Date?
    public var completedByMemberID: String?
    public var xpAwarded: Int?
    public var streak: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        assigneeID: String? = nil,
        dueDate: Date? = nil,
        recurrence: RecurrenceOption = .none,
        difficulty: ChoreDifficulty = .easy,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        completedByMemberID: String? = nil,
        xpAwarded: Int? = nil,
        streak: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.assigneeID = assigneeID
        self.dueDate = dueDate
        self.recurrence = recurrence
        self.difficulty = difficulty
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.completedByMemberID = completedByMemberID
        self.xpAwarded = xpAwarded
        self.streak = streak
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        assigneeID = try c.decodeIfPresent(String.self, forKey: .assigneeID)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        recurrence = try c.decodeIfPresent(RecurrenceOption.self, forKey: .recurrence) ?? .none
        difficulty = try c.decodeIfPresent(ChoreDifficulty.self, forKey: .difficulty) ?? .easy
        isCompleted = try c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        completedByMemberID = try c.decodeIfPresent(String.self, forKey: .completedByMemberID)
        xpAwarded = try c.decodeIfPresent(Int.self, forKey: .xpAwarded)
        streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    public var effectiveXP: Int { difficulty.baseXP }
}

/// Per-member gamification stats. Persisted at `households/{hid}/memberStats/{memberID}`.
public struct MemberStats: Codable, Equatable, Identifiable, Sendable {
    public var id: String            // == memberID (uid)
    public var memberID: String
    public var totalXP: Int
    public var level: Int
    public var choresCompleted: Int
    public var currentStreak: Int
    public var longestStreak: Int
    public var lastCompletedAt: Date?
    public var updatedAt: Date

    public init(
        id: String,
        memberID: String,
        totalXP: Int = 0,
        level: Int = 1,
        choresCompleted: Int = 0,
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        lastCompletedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.memberID = memberID
        self.totalXP = totalXP
        self.level = level
        self.choresCompleted = choresCompleted
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.lastCompletedAt = lastCompletedAt
        self.updatedAt = updatedAt
    }

    /// Cumulative XP needed to reach `level` (triangular curve, 50 XP base step).
    public static func xpRequired(forLevel level: Int) -> Int {
        50 * level * (level - 1) / 2
    }

    public var levelProgress: Double {
        let current = Self.xpRequired(forLevel: level)
        let next = Self.xpRequired(forLevel: level + 1)
        let range = next - current
        guard range > 0 else { return 0 }
        return min(1, max(0, Double(totalXP - current) / Double(range)))
    }
}

public enum XPCalculator {
    /// Base XP + streak bonus (+10%/streak day, cap 50%) + on-time bonus (+25% before due date).
    public static func xpForCompletion(chore: Chore, currentStreak: Int, now: Date = Date()) -> Int {
        let base = chore.effectiveXP
        let streakBonus = Int(Double(base) * min(0.5, Double(currentStreak) * 0.1))
        var onTime = 0
        if let due = chore.dueDate, now < due { onTime = Int(Double(base) * 0.25) }
        return base + streakBonus + onTime
    }

    public static func level(forTotalXP totalXP: Int) -> Int {
        var level = 1
        while MemberStats.xpRequired(forLevel: level + 1) <= totalXP { level += 1 }
        return level
    }
}

/// A parent-defined reward redeemable with XP. Persisted at `households/{hid}/rewards/{id}`.
public struct Reward: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var xpCost: Int
    public var iconName: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        xpCost: Int,
        iconName: String = "gift.fill",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.xpCost = xpCost
        self.iconName = iconName
        self.createdAt = createdAt
    }
}

/// A record of a member redeeming a reward. Persisted at `households/{hid}/redemptions/{id}`.
public struct RewardRedemption: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var rewardID: String
    public var rewardTitle: String
    public var memberID: String
    public var xpCost: Int
    public var redeemedAt: Date

    public init(
        id: String = UUID().uuidString,
        rewardID: String,
        rewardTitle: String,
        memberID: String,
        xpCost: Int,
        redeemedAt: Date = Date()
    ) {
        self.id = id
        self.rewardID = rewardID
        self.rewardTitle = rewardTitle
        self.memberID = memberID
        self.xpCost = xpCost
        self.redeemedAt = redeemedAt
    }
}
