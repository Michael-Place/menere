import Dependencies
import DependenciesMacros
import FamilyDomain
import FirebaseFunctions
import Foundation

/// One recipe, distilled to just what the planner needs to judge effort + variety (never the full
/// ingredient/instruction text).
public struct MealWeekRecipe: Equatable, Sendable {
    public var id: String
    public var title: String
    public var ingredientCount: Int
    public var servings: Int

    public init(id: String, title: String, ingredientCount: Int, servings: Int) {
        self.id = id
        self.title = title
        self.ingredientCount = ingredientCount
        self.servings = servings
    }
}

/// One day of the week to plan, tagged weeknight vs weekend so the planner can bias effort.
public struct MealWeekDay: Equatable, Sendable {
    public var date: Date
    public var isWeekend: Bool

    public init(date: Date, isWeekend: Bool) {
        self.date = date
        self.isWeekend = isWeekend
    }
}

/// One AI dinner assignment: which recipe lands on which day, and Claude's one-line rationale.
public struct MealWeekAssignment: Equatable, Sendable {
    public var date: Date
    public var recipeID: String
    public var reason: String

    public init(date: Date, recipeID: String, reason: String) {
        self.date = date
        self.recipeID = recipeID
        self.reason = reason
    }
}

/// Wraps the `planMealWeek` HTTPS callable (P23 — "Plan my week ✨"): given the family's recipes and
/// the 7 days of this week, Claude returns a balanced, varied week of dinners (quick weeknights,
/// project weekends). The returned assignments are matched back to the input `Date`s here, so the
/// reducer works in real dates.
@DependencyClient
public struct MealPlanClient: Sendable {
    public var planWeek: @Sendable (_ recipes: [MealWeekRecipe], _ days: [MealWeekDay]) async throws -> [MealWeekAssignment]
}

enum MealPlanClientError: Error { case invalidResponse }

/// yyyy-MM-dd in the current calendar/zone — the stable day key sent to and echoed by the server.
private let dayKeyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar.current
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private let weekdayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = "EEEE"
    return f
}()

extension MealPlanClient: DependencyKey {
    public static let liveValue = MealPlanClient(
        planWeek: { recipes, days in
            let recipePayload = recipes.map { r -> [String: Any] in
                ["id": r.id, "title": r.title, "ingredientCount": r.ingredientCount, "servings": r.servings]
            }
            // date string → the real Date, so we can map Claude's echo back.
            var dateByKey: [String: Date] = [:]
            let dayPayload = days.map { d -> [String: Any] in
                let key = dayKeyFormatter.string(from: d.date)
                dateByKey[key] = d.date
                return ["date": key, "weekday": weekdayFormatter.string(from: d.date),
                        "kind": d.isWeekend ? "weekend" : "weeknight"]
            }
            let callable = Functions.functions(region: "us-central1").httpsCallable("planMealWeek")
            let result = try await callable.call(["recipes": recipePayload, "days": dayPayload])
            guard let dict = result.data as? [String: Any],
                  let plan = dict["plan"] as? [[String: Any]] else {
                throw MealPlanClientError.invalidResponse
            }
            return plan.compactMap { entry -> MealWeekAssignment? in
                guard let key = entry["date"] as? String, let date = dateByKey[key],
                      let recipeID = entry["recipeId"] as? String, !recipeID.isEmpty else { return nil }
                let reason = (entry["reason"] as? String) ?? ""
                return MealWeekAssignment(date: date, recipeID: recipeID, reason: reason)
            }
        }
    )
}

public extension DependencyValues {
    var mealPlanClient: MealPlanClient {
        get { self[MealPlanClient.self] }
        set { self[MealPlanClient.self] = newValue }
    }
}
