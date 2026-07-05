import Foundation

/// The kind of list, driving how its detail screen renders. Ported from Fambo (P30) and
/// extended in P30.5 with `packing` (per-person + reusable templates) and `gift` (per
/// recipient/occasion, bought-status). Decode-safe: persisted as an optional on `FamilyList`,
/// and any unknown/`nil` raw value is treated as `.standard` (see the failable init below), so
/// older clients never choke on a list type they predate.
public enum ListType: String, Codable, Sendable, Equatable {
    case standard
    case grocery
    case packing
    case gift

    /// Decode-safe: an unknown raw value (a type this build predates) degrades to `.standard`
    /// instead of failing the whole `FamilyList` decode.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ListType(rawValue: raw) ?? .standard
    }
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

    /// Whether this list should render the per-person, category-grouped packing experience (P30.5).
    public var isPacking: Bool { listType == .packing }

    /// Whether this list should render the gift experience (recipient/occasion/price/link/bought).
    public var isGift: Bool { listType == .gift }
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

    // MARK: Packing-specific fields (P30.5)
    // Decode-safe optionals — packing lists group by `packingCategory` and (optionally) filter by
    // `forMemberID`. "Packed" reuses `isCompleted` (no new flag).
    /// The packing bucket this item belongs to (clothes / toiletries / documents / …).
    public var packingCategory: PackingCategory?
    /// The `HouseholdMember.id` this packing item is *for* (per-person sections). Distinct from
    /// `assigneeID` (who's responsible) — a packing list is organized by whose bag it goes in.
    public var forMemberID: String?

    // MARK: Gift-specific fields (P30.5)
    // Decode-safe optionals — gift lists show recipient/occasion/price/link. "Bought" reuses
    // `isCompleted` (no new flag).
    /// Who the gift is for (freeform name, or a `HouseholdMember.id`).
    public var recipient: String?
    /// The occasion ("Birthday", "Christmas", "Anniversary").
    public var occasion: String?
    /// Estimated / actual price, used for the list's total-spend line.
    public var price: Double?
    /// A store / product URL for the idea.
    public var link: String?

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
        recipeSourceID: String? = nil,
        packingCategory: PackingCategory? = nil,
        forMemberID: String? = nil,
        recipient: String? = nil,
        occasion: String? = nil,
        price: Double? = nil,
        link: String? = nil
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
        self.packingCategory = packingCategory
        self.forMemberID = forMemberID
        self.recipient = recipient
        self.occasion = occasion
        self.price = price
        self.link = link
    }

    /// The packing bucket to display this item under (defaults to `.misc` for un-tagged items).
    public var effectivePackingCategory: PackingCategory {
        packingCategory ?? .misc
    }

    /// The aisle to display this item under: its stored category, else a best-effort lookup
    /// from the item name (categorize-on-display for P23-generated items that carry no category).
    public var effectiveCategory: GroceryCategory {
        groceryCategory ?? GroceryItemDB.categorize(title) ?? .other
    }
}
