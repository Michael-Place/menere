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
    /// "took care of …" activity item attributed to the actor's name (looked up in `members`) and
    /// carrying the item's own icon. Returns `nil` if the task isn't found.
    public static func markDone(
        item: CareItem, taskID: String, byMemberID uid: String,
        members: [HouseholdMember], now: Date = Date()
    ) -> Outcome? {
        guard let t = item.tasks.firstIndex(where: { $0.id == taskID }) else { return nil }
        var updated = item
        updated.tasks[t].lastDoneAt = now
        updated.tasks[t].lastDoneBy = uid
        let actorName = members.first { $0.id == uid }?.name
        let activity = ActivityItem.careDone(item: item.name, by: actorName, actorID: uid, symbol: item.iconSymbol)
        return Outcome(updated: updated, activity: activity)
    }
}
