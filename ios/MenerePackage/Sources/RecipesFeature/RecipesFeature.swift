import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import LocationClient
import MenereUI
import SwiftUI
import UserDomain

@Reducer
public struct RecipesReducer {
    public enum Segment: String, CaseIterable, Equatable {
        case recipes = "Recipes"
        case mealPlan = "Meal Plan"
    }

    /// The working state of the "Eating out…" place-search sheet. A day is either still being
    /// searched (no `name` yet) or has a place chosen — a resolved restaurant (address + coords)
    /// or a name-only fallback (`name` set, coords nil).
    public struct EatingOutDraft: Equatable {
        var query: String = ""
        var name: String?
        var address: String?
        var latitude: Double?
        var longitude: Double?
        var reservationEnabled: Bool = false
        var reservationTime: Date = Date()

        /// A place (resolved or name-only) has been chosen — the sheet can save.
        var isPlaceSelected: Bool { name?.isEmpty == false }
        /// A real, coordinate-backed place (vs a typed-as-is name).
        var hasCoordinates: Bool { latitude != nil && longitude != nil }
    }

    @ObservableState
    public struct State: Equatable {
        var recipes: [Recipe] = []
        var mealPlan: [MealPlanEntry] = []
        var segment: Segment = .recipes
        var weekStart: Date = RecipesReducer.startOfWeek(Date())
        var isLoading = false
        /// True while "Plan my week ✨" is calling `planMealWeek` (drives the shimmer).
        var isPlanningWeek = false
        var generatedMessage: String?
        /// The day currently being assigned an "Eating out…" restaurant (drives the search sheet).
        var eatingOutDay: Date?
        var eatingOutDraft = EatingOutDraft()
        @Presents var form: RecipeFormReducer.State?

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case task
        /// Public entry point (used by the Today tab's "Plan dinner") — jump straight to the
        /// Meal Plan segment on the current week.
        case showMealPlan
        case loaded(recipes: [Recipe], mealPlan: [MealPlanEntry])
        case addTapped
        case editTapped(Recipe)
        case toggleFavorite(Recipe)
        case assignMeal(date: Date, recipe: Recipe)
        case eatingOutTapped(date: Date)
        /// A live completer suggestion was resolved to a real place via MKLocalSearch.
        case placeResolved(name: String, address: String, latitude: Double, longitude: Double)
        /// "Use "{typed}" as-is" — the name-only fallback (no address/coords).
        case useTypedAsIs
        /// Back out of a chosen place to search again.
        case changePlaceTapped
        case saveEatingOut
        case eatingOutDismissed
        case clearMeal(MealPlanEntry)
        /// "Plan my week ✨" — ask the AI to fill this week's dinners.
        case planWeekTapped
        case weekPlanned([MealWeekAssignment])
        case weekPlanFailed
        case generateGroceryList
        case groceryListGenerated(itemCount: Int)
        case dismissGeneratedMessage
        case form(PresentationAction<RecipeFormReducer.Action>)
        case binding(BindingAction<State>)
    }

    public init() {}

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    static func startOfWeek(_ date: Date) -> Date {
        let cal = Calendar.current
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
    }

    /// Merge a week's worth of ingredients into de-duplicated grocery lines. Same-name (and same-unit)
    /// ingredients are combined — quantities summed when both have one — so "2 cups flour" + "1 cup
    /// flour" becomes "3 cups flour", and exact repeats collapse to one line. Order of first
    /// appearance is preserved.
    static func mergedGroceryLines(from ingredients: [Ingredient]) -> [String] {
        struct Bucket { var quantity: Double?; var unit: String?; var name: String; var summable: Bool }
        var order: [String] = []
        var buckets: [String: Bucket] = [:]
        for ing in ingredients {
            let name = ing.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let unit = (ing.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased() + "|" + unit.lowercased()
            if var b = buckets[key] {
                if b.summable, let q = ing.quantity, let existing = b.quantity {
                    b.quantity = existing + q
                } else {
                    b.summable = false // can't cleanly sum (a quantity is missing) → keep as-is
                }
                buckets[key] = b
            } else {
                order.append(key)
                buckets[key] = Bucket(quantity: ing.quantity, unit: ing.unit,
                                      name: name, summable: ing.quantity != nil)
            }
        }
        return order.compactMap { key in
            guard let b = buckets[key] else { return nil }
            let merged = Ingredient(name: b.name,
                                    quantity: b.summable ? b.quantity : nil,
                                    unit: b.unit)
            return merged.displayLine
        }
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            @Dependency(\.analytics) var analytics   // P25 telemetry (fire-and-forget)
            switch action {
            case .task:
                guard let hid = hid() else { return .none }
                state.isLoading = true
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    async let recipes = persistence.recipes(hid)
                    async let plan = persistence.mealPlan(hid)
                    await send(.loaded(
                        recipes: (try? await recipes) ?? [],
                        mealPlan: (try? await plan) ?? []
                    ))
                }

            case .showMealPlan:
                state.segment = .mealPlan
                state.weekStart = RecipesReducer.startOfWeek(Date())
                return .none

            case let .loaded(recipes, plan):
                state.isLoading = false
                state.recipes = recipes.sorted {
                    $0.isFavorite == $1.isFavorite ? $0.title < $1.title : ($0.isFavorite && !$1.isFavorite)
                }
                state.mealPlan = plan
                return .none

            case .addTapped:
                state.form = RecipeFormReducer.State(recipe: Recipe(title: ""), isEditing: false)
                return .none

            case let .editTapped(recipe):
                analytics.log("recipe_opened")
                state.form = RecipeFormReducer.State(recipe: recipe, isEditing: true)
                return .none

            case let .toggleFavorite(recipe):
                guard let hid = hid(), let idx = state.recipes.firstIndex(where: { $0.id == recipe.id }) else { return .none }
                state.recipes[idx].isFavorite.toggle()
                let updated = state.recipes[idx]
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveRecipe(hid, updated)
                }

            case let .assignMeal(date, recipe):
                guard let hid = hid() else { return .none }
                analytics.log("meal_assigned")
                let day = Calendar.current.startOfDay(for: date)
                // Replace any existing entry for that day.
                let existing = state.mealPlan.first { Calendar.current.isDate($0.date, inSameDayAs: day) }
                let entry = MealPlanEntry(
                    id: existing?.id ?? UUID().uuidString,
                    date: day, recipeID: recipe.id, recipeTitle: recipe.title
                )
                if let i = state.mealPlan.firstIndex(where: { $0.id == entry.id }) {
                    state.mealPlan[i] = entry
                } else {
                    state.mealPlan.append(entry)
                }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveMealPlanEntry(hid, entry)
                }

            case let .eatingOutTapped(date):
                let cal = Calendar.current
                let day = cal.startOfDay(for: date)
                state.eatingOutDay = day
                var draft = EatingOutDraft()
                // Default the reservation picker to ~7:00 PM of that day.
                draft.reservationTime = cal.date(bySettingHour: 19, minute: 0, second: 0, of: day) ?? day
                // Re-opening an existing eating-out day prefills name/place/time.
                if let existing = state.mealPlan.first(where: { cal.isDate($0.date, inSameDayAs: day) }),
                   existing.isEatingOut {
                    draft.name = existing.restaurantName
                    draft.query = existing.restaurantName ?? ""
                    draft.address = existing.restaurantAddress
                    draft.latitude = existing.restaurantLatitude
                    draft.longitude = existing.restaurantLongitude
                    if let reservationAt = existing.reservationAt {
                        draft.reservationEnabled = true
                        draft.reservationTime = reservationAt
                    }
                }
                state.eatingOutDraft = draft
                return .none

            case let .placeResolved(name, address, latitude, longitude):
                state.eatingOutDraft.name = name
                state.eatingOutDraft.query = name
                state.eatingOutDraft.address = address
                state.eatingOutDraft.latitude = latitude
                state.eatingOutDraft.longitude = longitude
                return .none

            case .useTypedAsIs:
                let name = state.eatingOutDraft.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return .none }
                state.eatingOutDraft.name = name
                state.eatingOutDraft.address = nil
                state.eatingOutDraft.latitude = nil
                state.eatingOutDraft.longitude = nil
                return .none

            case .changePlaceTapped:
                state.eatingOutDraft.name = nil
                state.eatingOutDraft.address = nil
                state.eatingOutDraft.latitude = nil
                state.eatingOutDraft.longitude = nil
                return .none

            case .saveEatingOut:
                guard let hid = hid(), let day = state.eatingOutDay else { return .none }
                let cal = Calendar.current
                let draft = state.eatingOutDraft
                guard let rawName = draft.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawName.isEmpty else {
                    state.eatingOutDay = nil
                    return .none
                }
                // Combine the picked day with the reservation time-of-day.
                let reservationAt: Date? = draft.reservationEnabled
                    ? cal.date(
                        bySettingHour: cal.component(.hour, from: draft.reservationTime),
                        minute: cal.component(.minute, from: draft.reservationTime),
                        second: 0, of: day
                    )
                    : nil
                state.eatingOutDay = nil
                state.eatingOutDraft = EatingOutDraft()
                // Eating out clears any recipe for that day (an entry is one kind or the other).
                let existing = state.mealPlan.first { cal.isDate($0.date, inSameDayAs: day) }
                let entry = MealPlanEntry(
                    id: existing?.id ?? UUID().uuidString, date: day,
                    restaurantName: rawName, restaurantAddress: draft.address,
                    restaurantLatitude: draft.latitude, restaurantLongitude: draft.longitude,
                    reservationAt: reservationAt
                )
                if let i = state.mealPlan.firstIndex(where: { $0.id == entry.id }) {
                    state.mealPlan[i] = entry
                } else {
                    state.mealPlan.append(entry)
                }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveMealPlanEntry(hid, entry)
                }

            case .eatingOutDismissed:
                state.eatingOutDay = nil
                state.eatingOutDraft = EatingOutDraft()
                return .none

            case let .clearMeal(entry):
                guard let hid = hid() else { return .none }
                state.mealPlan.removeAll { $0.id == entry.id }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.deleteMealPlanEntry(hid, entry.id)
                }

            case .planWeekTapped:
                guard !state.isPlanningWeek else { return .none }
                // Build the recipe corpus + the 7 days of this week (weekend = Sat/Sun).
                let recipes = state.recipes.map {
                    MealWeekRecipe(id: $0.id, title: $0.title,
                                   ingredientCount: $0.ingredients.count, servings: $0.servings)
                }
                guard !recipes.isEmpty else {
                    state.generatedMessage = "Add a few recipes first, then I'll plan the week."
                    return .none
                }
                let cal = Calendar.current
                let weekStart = state.weekStart
                let days: [MealWeekDay] = (0..<7).compactMap { offset in
                    guard let day = cal.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
                    let wd = cal.component(.weekday, from: day) // 1 = Sun … 7 = Sat
                    return MealWeekDay(date: day, isWeekend: wd == 1 || wd == 7)
                }
                state.isPlanningWeek = true
                return .run { send in
                    @Dependency(\.mealPlanClient) var mealPlanClient
                    do {
                        let plan = try await mealPlanClient.planWeek(recipes, days)
                        await send(.weekPlanned(plan))
                    } catch {
                        await send(.weekPlanFailed)
                    }
                }

            case let .weekPlanned(assignments):
                state.isPlanningWeek = false
                guard let hid = hid() else { return .none }
                analytics.log("meal_week_planned", ["days": String(assignments.count)])
                let cal = Calendar.current
                let entries: [MealPlanEntry] = assignments.compactMap { a in
                    guard let recipe = state.recipes.first(where: { $0.id == a.recipeID }) else { return nil }
                    let day = cal.startOfDay(for: a.date)
                    let existing = state.mealPlan.first { cal.isDate($0.date, inSameDayAs: day) }
                    return MealPlanEntry(
                        id: existing?.id ?? UUID().uuidString,
                        date: day, recipeID: recipe.id, recipeTitle: recipe.title
                    )
                }
                for entry in entries {
                    if let i = state.mealPlan.firstIndex(where: { $0.id == entry.id }) {
                        state.mealPlan[i] = entry
                    } else {
                        state.mealPlan.append(entry)
                    }
                }
                if entries.isEmpty {
                    state.generatedMessage = "Couldn't find enough dinner-worthy recipes to plan the week."
                    return .none
                }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    for entry in entries { try await persistence.saveMealPlanEntry(hid, entry) }
                }

            case .weekPlanFailed:
                state.isPlanningWeek = false
                state.generatedMessage = "The planner couldn't reach the kitchen just now — try again in a moment."
                return .none

            case .generateGroceryList:
                guard let hid = hid() else { return .none }
                let cal = Calendar.current
                let weekEnd = cal.date(byAdding: .day, value: 7, to: state.weekStart)!
                let weekRecipeIDs = Set(
                    state.mealPlan
                        .filter { $0.date >= state.weekStart && $0.date < weekEnd }
                        .filter { !$0.isEatingOut } // eating-out nights have no ingredients
                        .map(\.recipeID)
                )
                let ingredients = state.recipes
                    .filter { weekRecipeIDs.contains($0.id) }
                    .flatMap(\.ingredients)
                guard !ingredients.isEmpty else {
                    state.generatedMessage = "Nothing to shop for yet — plan a few meals this week first."
                    return .none
                }
                let list = FamilyList(title: "Groceries", icon: "cart", color: .sage)
                let items = RecipesReducer.mergedGroceryLines(from: ingredients).enumerated().map { idx, line in
                    ListItem(title: line, listID: list.id, sortOrder: idx)
                }
                let count = items.count
                analytics.log("grocery_list_generated", ["items": String(count)])
                // V1-C — the meal→grocery→Money cost loop: log the ballpark spend for this trip.
                let estimate = GroceryCostEstimator.estimate(ingredients: ingredients)
                analytics.log("grocery_cost_estimated", ["estimate": String(Int(estimate.total.rounded()))])
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveList(hid, list)
                    for item in items { try await persistence.saveListItem(hid, item) }
                    await send(.groceryListGenerated(itemCount: count))
                }

            case let .groceryListGenerated(count):
                state.generatedMessage = "Done — \(count) item\(count == 1 ? "" : "s") added to a new Groceries list."
                return .none

            case .dismissGeneratedMessage:
                state.generatedMessage = nil
                return .none

            case .form(.presented(.delegate(.didChange))):
                return .send(.task)

            case .form, .binding:
                return .none
            }
        }
        .ifLet(\.$form, action: \.form) {
            RecipeFormReducer()
        }
    }
}
