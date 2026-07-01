import Foundation

/// A shared family list (shopping, tasks, etc.). Ported from Fambo's `FamboList`, trimmed to
/// Menere's core needs; grocery-specific specialization is deferred to the meal-planning phase.
///
/// Persisted at `households/{hid}/lists/{id}`.
public struct FamilyList: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var icon: String
    public var color: MemberColor
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        icon: String = "checklist",
        color: MemberColor = .ocean,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// An item within a `FamilyList`, optionally assigned to a member and/or given a due date.
///
/// Persisted at `households/{hid}/lists/{listID}/items/{id}`.
public struct ListItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var isCompleted: Bool
    /// The `HouseholdMember.id` (uid) this item is assigned to, if any.
    public var assigneeID: String?
    public var dueDate: Date?
    public var listID: String
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        isCompleted: Bool = false,
        assigneeID: String? = nil,
        dueDate: Date? = nil,
        listID: String,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.assigneeID = assigneeID
        self.dueDate = dueDate
        self.listID = listID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
