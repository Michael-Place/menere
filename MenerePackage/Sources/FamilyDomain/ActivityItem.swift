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
}
