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
        self.ingredients = ingredients
        self.instructions = instructions
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        servings = try c.decodeIfPresent(Int.self, forKey: .servings) ?? 4
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        ingredients = try c.decodeIfPresent([Ingredient].self, forKey: .ingredients) ?? []
        instructions = try c.decodeIfPresent([String].self, forKey: .instructions) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
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

    public init(
        id: String = UUID().uuidString,
        date: Date,
        recipeID: String,
        recipeTitle: String,
        restaurantName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.recipeID = recipeID
        self.recipeTitle = recipeTitle
        self.restaurantName = restaurantName
    }

    /// Convenience: an eating-out entry (recipe fields cleared, restaurant set).
    public init(id: String = UUID().uuidString, date: Date, restaurantName: String) {
        self.init(id: id, date: date, recipeID: "", recipeTitle: "", restaurantName: restaurantName)
    }

    /// Decode-safe: existing recipe docs (no `restaurantName`) keep decoding; older docs
    /// missing recipe fields tolerate absence too.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        recipeID = try c.decodeIfPresent(String.self, forKey: .recipeID) ?? ""
        recipeTitle = try c.decodeIfPresent(String.self, forKey: .recipeTitle) ?? ""
        restaurantName = try c.decodeIfPresent(String.self, forKey: .restaurantName)
    }

    /// True when this night is a restaurant, not a home recipe.
    public var isEatingOut: Bool {
        if let restaurantName, !restaurantName.isEmpty { return true }
        return false
    }
}
