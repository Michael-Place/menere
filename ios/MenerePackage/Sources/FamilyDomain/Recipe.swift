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

    public init(id: String = UUID().uuidString, date: Date, recipeID: String, recipeTitle: String) {
        self.id = id
        self.date = date
        self.recipeID = recipeID
        self.recipeTitle = recipeTitle
    }
}
