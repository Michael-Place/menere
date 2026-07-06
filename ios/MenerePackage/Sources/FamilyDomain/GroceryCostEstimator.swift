import Foundation

/// Act V V1-C — the MEAL→GROCERY→MONEY cost loop.
///
/// A deliberately *rough* estimator that puts a dollar figure on a shopping trip so the meal plan
/// and Money can talk to each other. It is **not** a price lookup — every figure is an ESTIMATE
/// built from coarse US-average per-item prices bucketed by grocery aisle (`GroceryCategory`), reusing
/// the free, offline `GroceryItemDB` categorizer. Prices are per *distinct item*, not per quantity or
/// unit — "flour" costs the same whether the recipe wants 1 cup or 3.
///
/// Pure Foundation + deterministic (no `Date()` reads, no I/O), so it's unit-testable and safe to call
/// from any feature. Lives in `FamilyDomain` because both `RecipesFeature` (the meal-plan surface) and
/// `MoneyFeature` (the planned-spend surface) consume it and only share this module.
public enum GroceryCostEstimator {
    /// A ballpark shopping-trip total. `itemCount` is the number of distinct items priced.
    public struct Estimate: Equatable, Sendable {
        public var total: Double
        public var itemCount: Int

        public init(total: Double, itemCount: Int) {
            self.total = total
            self.itemCount = itemCount
        }

        public static let empty = Estimate(total: 0, itemCount: 0)
        public var isEmpty: Bool { itemCount == 0 }
    }

    /// Coarse per-item US-average price by aisle. Sensible ballparks, not real prices — this is the
    /// whole "it's an ESTIMATE" honesty story in one table. Tune freely; nothing depends on exactness.
    static let categoryPrice: [GroceryCategory: Double] = [
        .produce: 2.5,
        .dairy: 4,
        .meat: 9,
        .seafood: 11,
        .bakery: 4,
        .frozen: 5,
        .pantry: 3.5,
        .beverages: 4,
        .snacks: 4,
        .deli: 7,
        .household: 6,
        .health: 7,
        .baby: 12,
        .pets: 15,
        .other: 3.5,
    ]

    /// What an unrecognized / uncategorized item is assumed to cost.
    static let fallbackPrice = 3.5

    /// The estimated price of a single grocery item, by its name (categorized via `GroceryItemDB`).
    public static func price(forItemName name: String) -> Double {
        if let category = GroceryItemDB.categorize(name), let price = categoryPrice[category] {
            return price
        }
        return fallbackPrice
    }

    /// Estimate a trip from already-de-duplicated item names.
    public static func estimate(itemNames: [String]) -> Estimate {
        let prices = itemNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(price(forItemName:))
        return Estimate(total: prices.reduce(0, +), itemCount: prices.count)
    }

    /// Estimate a trip from raw recipe ingredients — de-duped by name (unit ignored), priced once each,
    /// so "1 cup flour" + "3 cups flour" is a single "flour" purchase.
    public static func estimate(ingredients: [Ingredient]) -> Estimate {
        var seen = Set<String>()
        var names: [String] = []
        for ingredient in ingredients {
            let name = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if seen.insert(name.lowercased()).inserted { names.append(name) }
        }
        return estimate(itemNames: names)
    }

    /// The week's grocery estimate straight off the meal plan: dinners assigned in `[weekStart, +7d)`,
    /// skipping eating-out nights, → their recipes' ingredients → de-duped + priced. Mirrors the exact
    /// set of ingredients `RecipesReducer.generateGroceryList` shops for, so the two surfaces agree.
    public static func weeklyEstimate(
        recipes: [Recipe],
        mealPlan: [MealPlanEntry],
        weekStart: Date,
        calendar: Calendar = .current
    ) -> Estimate {
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let weekRecipeIDs = Set(
            mealPlan
                .filter { $0.date >= weekStart && $0.date < weekEnd && !$0.isEatingOut }
                .map(\.recipeID)
        )
        let ingredients = recipes
            .filter { weekRecipeIDs.contains($0.id) }
            .flatMap(\.ingredients)
        return estimate(ingredients: ingredients)
    }
}
