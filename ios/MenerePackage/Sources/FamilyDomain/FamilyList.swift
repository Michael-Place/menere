import Foundation

/// The kind of list, driving how its detail screen renders. Ported from Fambo (P30).
/// Decode-safe: persisted as an optional on `FamilyList`, and `nil` is treated as `.standard`.
public enum ListType: String, Codable, Sendable, Equatable {
    case standard
    case grocery
}

/// A shared family list (shopping, tasks, etc.). Ported from Fambo's `FamboList`, trimmed to
/// Menere's core needs. P30 adds a `listType` so a list can specialize into a grocery list
/// (aisle-grouped detail + auto-categorization) while standard lists keep the flat checklist.
///
/// Persisted at `households/{hid}/lists/{id}`.
public struct FamilyList: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var icon: String
    public var color: MemberColor
    /// The list's specialization. Decode-safe: `nil` (legacy lists) is treated as `.standard`.
    public var listType: ListType?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        icon: String = "checklist",
        color: MemberColor = .ocean,
        listType: ListType? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.color = color
        self.listType = listType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether this list should render the aisle-grouped grocery experience.
    ///
    /// Recognizes both an explicit `.grocery` type and — for backward compatibility — the
    /// P23 meal-plan generator's `cart`-icon "Groceries" list, which predates `listType` and
    /// so persists with `listType == nil`.
    public var isGrocery: Bool {
        listType == .grocery || icon == "cart"
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

    // MARK: Grocery-specific fields (P30)
    // All optional + decode-safe — standard list items leave these `nil` and ignore them.
    /// Amount to buy (e.g. `2`). Grocery lists may show it before the name.
    public var quantity: Double?
    /// Unit for `quantity` (e.g. "lb", "oz", "bunch").
    public var unit: String?
    /// The aisle this item belongs to. May be `nil` on generated items and resolved at render
    /// via `GroceryItemDB.categorize(_:)`.
    public var groceryCategory: GroceryCategory?
    /// Freeform note ("organic", "the green kind").
    public var note: String?
    /// The `Recipe.id` this item was generated from (P23 meal-plan → grocery), if any.
    public var recipeSourceID: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        isCompleted: Bool = false,
        assigneeID: String? = nil,
        dueDate: Date? = nil,
        listID: String,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        quantity: Double? = nil,
        unit: String? = nil,
        groceryCategory: GroceryCategory? = nil,
        note: String? = nil,
        recipeSourceID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.isCompleted = isCompleted
        self.assigneeID = assigneeID
        self.dueDate = dueDate
        self.listID = listID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.quantity = quantity
        self.unit = unit
        self.groceryCategory = groceryCategory
        self.note = note
        self.recipeSourceID = recipeSourceID
    }

    /// The aisle to display this item under: its stored category, else a best-effort lookup
    /// from the item name (categorize-on-display for P23-generated items that carry no category).
    public var effectiveCategory: GroceryCategory {
        groceryCategory ?? GroceryItemDB.categorize(title) ?? .other
    }
}
