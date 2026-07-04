import Foundation

/// A single recipe ingredient. Trimmed from Fambo's `Ingredient` (dropped grocery category).
public struct Ingredient: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var quantity: Double?
    public var unit: String?

    public init(id: String = UUID().uuidString, name: String, quantity: Double? = nil, unit: String? = nil) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
    }

    /// A "2 cups flour" style line for grocery lists.
    public var displayLine: String {
        var parts: [String] = []
        if let quantity {
            let q = quantity.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", quantity) : String(format: "%.1f", quantity)
            parts.append(q)
        }
        if let unit, !unit.isEmpty { parts.append(unit) }
        parts.append(name)
        return parts.joined(separator: " ")
    }
}

/// A family recipe. Ported from Fambo's `Recipe`, trimmed to core fields.
///
/// Persisted at `households/{hid}/recipes/{id}`.
public struct Recipe: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var servings: Int
    public var sourceURL: String?
    /// The recipe's photo (from JSON-LD `image` / `og:image` on import). Optional and decode-safe:
    /// bulk-imported docs carry it, hand-added/older recipes omit it (fall back to a food glyph).
    public var imageURL: String?
    public var ingredients: [Ingredient]
    public var instructions: [String]
    public var isFavorite: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        servings: Int = 4,
        sourceURL: String? = nil,
        imageURL: String? = nil,
        ingredients: [Ingredient] = [],
        instructions: [String] = [],
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.servings = servings
        self.sourceURL = sourceURL
        self.imageURL = imageURL
        self.ingredients = ingredients
        self.instructions = instructions
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, servings, sourceURL, imageURL
        case ingredients, instructions, isFavorite, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        servings = try c.decodeIfPresent(Int.self, forKey: .servings) ?? 4
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        ingredients = try c.decodeIfPresent([Ingredient].self, forKey: .ingredients) ?? []
        instructions = try c.decodeIfPresent([String].self, forKey: .instructions) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// Encode-safe mirror: a nil `imageURL` is omitted (never written as null), so hand-added
    /// recipes stay lean and imported ones keep their photo.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(servings, forKey: .servings)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try c.encodeIfPresent(imageURL, forKey: .imageURL)
        try c.encode(ingredients, forKey: .ingredients)
        try c.encode(instructions, forKey: .instructions)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// A cheap, client-side effort read on a recipe (P23 — the "meal rhythm"). Inferred purely from
/// ingredient + instruction counts — no model needed — so day rows can hint quick-weeknight vs
/// weekend-project at a glance and the planner can bias accordingly.
public enum RecipeEffort: String, Equatable, Sendable {
    case quick   // few ingredients AND few steps → a weeknight dinner
    case project // many ingredients OR many steps → a weekend cook

    /// A short chip label ("Quick" / "Project").
    public var label: String {
        switch self {
        case .quick: return "Quick"
        case .project: return "Project"
        }
    }
}

public extension Recipe {
    /// Heuristic effort read: `.quick` when ≤7 ingredients AND ≤6 steps, `.project` when ≥14
    /// ingredients OR ≥12 steps, and `nil` in the ambiguous middle (no chip shown).
    var effort: RecipeEffort? {
        let ing = ingredients.count
        let steps = instructions.count
        if ing <= 7, steps <= 6 { return .quick }
        if ing >= 14 || steps >= 12 { return .project }
        return nil
    }
}

/// One day's dinner assignment in the weekly meal plan.
///
/// Persisted at `households/{hid}/mealPlan/{id}`, one doc per planned day.
public struct MealPlanEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Start-of-day for the planned date.
    public var date: Date
    public var recipeID: String
    public var recipeTitle: String
    /// When set, this night the family is eating out; the recipe fields are empty.
    /// An entry is EITHER a recipe (recipeID/recipeTitle) OR eating out (restaurantName).
    public var restaurantName: String?
    /// Formatted street address, resolved via MKLocalSearch when a real place is picked.
    public var restaurantAddress: String?
    /// Resolved coordinates (present together, or both nil for a name-only entry).
    public var restaurantLatitude: Double?
    public var restaurantLongitude: Double?
    /// The reservation / plan-to-arrive time, when the family set one. Drives the Today card's
    /// "leave by" math and the one-tap add-to-calendar.
    public var reservationAt: Date?

    public init(
        id: String = UUID().uuidString,
        date: Date,
        recipeID: String,
        recipeTitle: String,
        restaurantName: String? = nil,
        restaurantAddress: String? = nil,
        restaurantLatitude: Double? = nil,
        restaurantLongitude: Double? = nil,
        reservationAt: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.recipeID = recipeID
        self.recipeTitle = recipeTitle
        self.restaurantName = restaurantName
        self.restaurantAddress = restaurantAddress
        self.restaurantLatitude = restaurantLatitude
        self.restaurantLongitude = restaurantLongitude
        self.reservationAt = reservationAt
    }

    /// Convenience: an eating-out entry (recipe fields cleared, restaurant set). Place details
    /// (address/coords/reservation) are optional — a name-only night just omits them.
    public init(
        id: String = UUID().uuidString,
        date: Date,
        restaurantName: String,
        restaurantAddress: String? = nil,
        restaurantLatitude: Double? = nil,
        restaurantLongitude: Double? = nil,
        reservationAt: Date? = nil
    ) {
        self.init(
            id: id, date: date, recipeID: "", recipeTitle: "",
            restaurantName: restaurantName, restaurantAddress: restaurantAddress,
            restaurantLatitude: restaurantLatitude, restaurantLongitude: restaurantLongitude,
            reservationAt: reservationAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, recipeID, recipeTitle, restaurantName
        case restaurantAddress, restaurantLatitude, restaurantLongitude, reservationAt
    }

    /// Decode-safe: existing recipe docs (no `restaurantName`) keep decoding; older docs
    /// missing recipe fields tolerate absence too. Every place field is `decodeIfPresent`, so
    /// pre-P6.2 eating-out docs (name only) decode with nil address/coords/reservation.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        recipeID = try c.decodeIfPresent(String.self, forKey: .recipeID) ?? ""
        recipeTitle = try c.decodeIfPresent(String.self, forKey: .recipeTitle) ?? ""
        restaurantName = try c.decodeIfPresent(String.self, forKey: .restaurantName)
        restaurantAddress = try c.decodeIfPresent(String.self, forKey: .restaurantAddress)
        restaurantLatitude = try c.decodeIfPresent(Double.self, forKey: .restaurantLatitude)
        restaurantLongitude = try c.decodeIfPresent(Double.self, forKey: .restaurantLongitude)
        reservationAt = try c.decodeIfPresent(Date.self, forKey: .reservationAt)
    }

    /// Encode-safe mirror of the custom decode: nil place fields are omitted (never written as
    /// null), so a name-only night stays a lean doc and recipe docs are unchanged.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(recipeID, forKey: .recipeID)
        try c.encode(recipeTitle, forKey: .recipeTitle)
        try c.encodeIfPresent(restaurantName, forKey: .restaurantName)
        try c.encodeIfPresent(restaurantAddress, forKey: .restaurantAddress)
        try c.encodeIfPresent(restaurantLatitude, forKey: .restaurantLatitude)
        try c.encodeIfPresent(restaurantLongitude, forKey: .restaurantLongitude)
        try c.encodeIfPresent(reservationAt, forKey: .reservationAt)
    }

    /// True when this night is a restaurant, not a home recipe.
    public var isEatingOut: Bool {
        if let restaurantName, !restaurantName.isEmpty { return true }
        return false
    }

    /// True when a real, resolved place is attached (both coordinates present) — powers the
    /// Today card's address + drive-time intelligence. Name-only nights are `false`.
    public var hasPlace: Bool {
        restaurantLatitude != nil && restaurantLongitude != nil
    }

    /// The reservation time formatted like "7:30" (used in day rows and the Today title). Nil when
    /// no reservation is set.
    public var reservationTimeShort: String? {
        guard let reservationAt else { return nil }
        return MealPlanEntry.shortTime(reservationAt)
    }

    /// "7:30"-style short time (no AM/PM), shared so day rows and the Today card format identically.
    public static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f.string(from: date)
    }
}
