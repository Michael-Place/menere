import Foundation

/// Shared client-side care-task completion logic, used by **both** the Home tab's House-care section
/// and the Today dashboard's "Home care" card so marking a care task done behaves identically
/// wherever it's tapped (mirrors ``ChoreCompletion``).
///
/// Unlike a chore, a care task earns **no XP** — it only records *who did it last, and when*, and
/// builds a best-effort activity entry. There is no server trigger involved.
public enum CareCompletion {
    /// The outcome of marking a care task done: the `updated` ``CareItem`` to persist and an optional
    /// `activity` feed entry attributed to the actor.
    public struct Outcome: Equatable, Sendable {
        public let updated: CareItem
        public let activity: ActivityItem?

        public init(updated: CareItem, activity: ActivityItem?) {
            self.updated = updated
            self.activity = activity
        }
    }

    /// Mark the task `taskID` inside `item` done by `uid`: stamp `lastDoneAt`/`lastDoneBy` and build a
    /// verb-appropriate activity item ("watered "Monstera"" / "took care of "HVAC filter"") attributed
    /// to the actor's name (looked up in `members`) and carrying the item's own icon. The verb is
    /// picked from the completed task's title. Returns `nil` if the task isn't found.
    public static func markDone(
        item: CareItem, taskID: String, byMemberID uid: String,
        members: [HouseholdMember], now: Date = Date()
    ) -> Outcome? {
        guard let t = item.tasks.firstIndex(where: { $0.id == taskID }) else { return nil }
        var updated = item
        updated.tasks[t].lastDoneAt = now
        updated.tasks[t].lastDoneBy = uid
        // Actually doing the task clears any "soil's still damp" snooze so the normal cadence resumes
        // from this completion (a snooze longer than the interval shouldn't outlive the real care).
        updated.tasks[t].snoozedUntil = nil
        let actorName = members.first { $0.id == uid }?.name
        let activity = ActivityItem.careDone(
            item: item.name, task: item.tasks[t].title,
            by: actorName, actorID: uid, symbol: item.iconSymbol
        )
        return Outcome(updated: updated, activity: activity)
    }

    /// "Not yet — the soil's still damp" (D1.5): push the task's next-due out by `days` WITHOUT marking
    /// it done. Sets ``CareTask/snoozedUntil`` to `days` from now; leaves `lastDoneAt`/`lastDoneBy`
    /// untouched (no completion, no XP, no activity). Kind-agnostic — any care can snooze. Returns the
    /// updated ``CareItem`` to persist via the usual `saveCareItem` path, or `nil` if the task is gone.
    public static func snoozed(
        item: CareItem, taskID: String, days: Int, now: Date = Date()
    ) -> CareItem? {
        guard let t = item.tasks.firstIndex(where: { $0.id == taskID }) else { return nil }
        var updated = item
        let target = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        updated.tasks[t].snoozedUntil = target
        return updated
    }
}
