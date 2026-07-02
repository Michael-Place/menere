import Foundation

/// Shared client-side chore-completion logic, used by **both** the Chores tab and the Today
/// dashboard so completing a chore behaves identically wherever it's tapped.
///
/// XP itself is awarded **server-side** by the `onChoreToggled` trigger — this only records
/// completion + who gets credit, spawns the next occurrence for recurring chores, and builds the
/// activity-feed entry. Never add client-side XP math here.
public enum ChoreCompletion {
    /// The outcome of toggling a chore: the `updated` chore to persist, an optional freshly-spawned
    /// `next` occurrence (recurring chores only), and an optional `activity` feed entry.
    public struct Outcome: Equatable, Sendable {
        public let updated: Chore
        public let next: Chore?
        public let activity: ActivityItem?

        public init(updated: Chore, next: Chore?, activity: ActivityItem?) {
            self.updated = updated
            self.next = next
            self.activity = activity
        }
    }

    /// Complete a chore: record who gets credit (`chore.assigneeID ?? fallbackCreditID`), spawn the
    /// next occurrence for recurring chores, and build a "completed" activity item (attributed to
    /// the credited member's name, looked up in `members`).
    public static func complete(_ chore: Chore, fallbackCreditID: String, members: [HouseholdMember]) -> Outcome {
        let creditID = chore.assigneeID ?? fallbackCreditID
        var updated = chore
        updated.isCompleted = true
        updated.completedAt = Date()
        updated.completedByMemberID = creditID
        let actorName = members.first { $0.id == creditID }?.name
        let activity = ActivityItem.choreCompleted(title: chore.title, by: actorName, actorID: creditID)
        return Outcome(updated: updated, next: nextOccurrence(of: chore), activity: activity)
    }

    /// Uncomplete a chore. The server reverses the prior award from the pre-update snapshot, so
    /// clearing these fields here is safe. No next occurrence, no activity entry.
    public static func uncomplete(_ chore: Chore) -> Outcome {
        var updated = chore
        updated.isCompleted = false
        updated.completedAt = nil
        updated.completedByMemberID = nil
        updated.xpAwarded = nil
        return Outcome(updated: updated, next: nil, activity: nil)
    }

    /// For a recurring chore, a fresh incomplete copy with its due date advanced one interval
    /// (from the old due date if set, else from today). Returns nil for non-recurring chores.
    public static func nextOccurrence(of chore: Chore) -> Chore? {
        guard let step = chore.recurrence.step else { return nil }
        let base = chore.dueDate ?? Date()
        let nextDue = Calendar.current.date(byAdding: step.component, value: step.value, to: base)
        return Chore(
            title: chore.title,
            assigneeID: chore.assigneeID,
            dueDate: nextDue,
            recurrence: chore.recurrence,
            difficulty: chore.difficulty,
            streak: chore.streak
        )
    }
}
