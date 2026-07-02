import Foundation

/// A family activity-feed entry. Written client-side by features as things happen (chores
/// completed, events added, list items checked) and read back for a "Recent activity" view.
/// Fambo writes these from Cloud Function triggers; a private app can do it inline just as well.
///
/// Persisted at `households/{hid}/activity/{id}`.
public struct ActivityItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var systemImage: String
    public var actorID: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        text: String,
        systemImage: String,
        actorID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.systemImage = systemImage
        self.actorID = actorID
        self.createdAt = createdAt
    }

    public static func choreCompleted(title: String, by name: String?, actorID: String?) -> ActivityItem {
        let who = name.map { "\($0) " } ?? ""
        return ActivityItem(text: "\(who)completed \"\(title)\"", systemImage: "checkmark.seal.fill", actorID: actorID)
    }

    public static func eventAdded(title: String, actorID: String?) -> ActivityItem {
        ActivityItem(text: "New event: \"\(title)\"", systemImage: "calendar.badge.plus", actorID: actorID)
    }

    public static func listItemChecked(title: String, list: String, actorID: String?) -> ActivityItem {
        ActivityItem(text: "Checked \"\(title)\" off \(list)", systemImage: "checklist.checked", actorID: actorID)
    }

    /// A care task was marked done. `name` is the actor's first-name-friendly name; `item` is the
    /// care item's name ("HVAC filter", "Monstera"); `task` is the completed task's title, which
    /// picks a natural verb (water→"watered", feed→"fed", mist→"misted", else "took care of") so
    /// plants read "Migueluh watered "Monstera"". `symbol` defaults to a house glyph but callers
    /// pass the item's own icon. Purely additive — activity docs are plain text, so old ones decode.
    public static func careDone(
        item: String, task: String? = nil, by name: String?, actorID: String?, symbol: String = "house.fill"
    ) -> ActivityItem {
        let who = name.map { "\($0) " } ?? ""
        return ActivityItem(text: "\(who)\(careVerb(forTask: task)) \"\(item)\"", systemImage: symbol, actorID: actorID)
    }

    /// The past-tense verb for a care-task completion, keyed off the task title. Kept liberal
    /// (substring match, case-insensitive) so "Water", "Water thoroughly", "Deep water" all read
    /// "watered". Falls back to the kind-agnostic "took care of". Public so plant rows can reuse it
    /// for their "Watered Jul 2 by …" done line.
    public static func careVerb(forTask task: String?) -> String {
        guard let t = task?.lowercased() else { return "took care of" }
        if t.contains("water") { return "watered" }
        if t.contains("feed") || t.contains("fertil") { return "fed" }
        if t.contains("mist") { return "misted" }
        // Pet care (P10). The composed line is "{name} {verb} \"{pet}\"", so "trimmed nails for"
        // reads "Migueluh trimmed nails for \"Fajita\"". Clinical med verbs are deliberately skipped
        // (heartworm/flea-tick fall to the warm "took care of"). "bath" only — "wash" would misfire on
        // the house "Wash bedding" starter.
        if t.contains("groom") { return "groomed" }
        if t.contains("nail") { return "trimmed nails for" }
        if t.contains("walk") { return "walked" }
        if t.contains("bath") { return "bathed" }
        return "took care of"
    }
}
