import Dependencies
import DependenciesMacros
import FamilyDomain
import FirebaseFunctions
import Foundation

/// Wraps the `extractRecipe` HTTPS callable: given a recipe URL, returns a parsed `Recipe`
/// (JSON-LD fast path or Claude on the server). Ingredient quantities/units are best-effort.
@DependencyClient
public struct RecipeImportClient: Sendable {
    public var importFromURL: @Sendable (_ url: String) async throws -> Recipe
}

public enum RecipeImportError: Error, Equatable {
    case invalidResponse
}

extension RecipeImportClient: DependencyKey {
    public static let liveValue = RecipeImportClient(
        importFromURL: { url in
            let callable = Functions.functions(region: "us-central1").httpsCallable("extractRecipe")
            let result = try await callable.call(["url": url])
            guard
                let data = result.data as? [String: Any],
                let r = data["recipe"] as? [String: Any],
                let title = r["title"] as? String
            else { throw RecipeImportError.invalidResponse }

            let servings = (r["servings"] as? Int) ?? Int((r["servings"] as? Double) ?? 4)
            let ingredients: [Ingredient] = (r["ingredients"] as? [[String: Any]] ?? []).compactMap { dict in
                guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
                let quantity = dict["quantity"] as? Double ?? (dict["quantity"] as? Int).map(Double.init)
                let unit = dict["unit"] as? String
                return Ingredient(name: name, quantity: quantity, unit: unit)
            }
            let instructions = (r["instructions"] as? [String] ?? []).filter { !$0.isEmpty }

            let imageURL = (r["imageURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            return Recipe(
                title: title,
                servings: max(1, servings),
                sourceURL: (r["sourceURL"] as? String) ?? url,
                imageURL: imageURL,
                ingredients: ingredients,
                instructions: instructions
            )
        }
    )
}

extension DependencyValues {
    public var recipeImport: RecipeImportClient {
        get { self[RecipeImportClient.self] }
        set { self[RecipeImportClient.self] = newValue }
    }
}
