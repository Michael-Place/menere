import ComposableArchitecture
import FamilyDomain
import MenereUI
import SwiftUI
import UserDomain

@Reducer
public struct RecipesReducer {
    public enum Segment: String, CaseIterable, Equatable {
        case recipes = "Recipes"
        case mealPlan = "Meal Plan"
    }

    @ObservableState
    public struct State: Equatable {
        var recipes: [Recipe] = []
        var mealPlan: [MealPlanEntry] = []
        var segment: Segment = .recipes
        var weekStart: Date = RecipesReducer.startOfWeek(Date())
        var isLoading = false
        var generatedMessage: String?
        @Presents var form: RecipeFormReducer.State?

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case task
        case loaded(recipes: [Recipe], mealPlan: [MealPlanEntry])
        case addTapped
        case editTapped(Recipe)
        case toggleFavorite(Recipe)
        case assignMeal(date: Date, recipe: Recipe)
        case clearMeal(MealPlanEntry)
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

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
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

            case let .clearMeal(entry):
                guard let hid = hid() else { return .none }
                state.mealPlan.removeAll { $0.id == entry.id }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.deleteMealPlanEntry(hid, entry.id)
                }

            case .generateGroceryList:
                guard let hid = hid() else { return .none }
                let cal = Calendar.current
                let weekEnd = cal.date(byAdding: .day, value: 7, to: state.weekStart)!
                let weekRecipeIDs = Set(
                    state.mealPlan
                        .filter { $0.date >= state.weekStart && $0.date < weekEnd }
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
                let items = ingredients.enumerated().map { idx, ing in
                    ListItem(title: ing.displayLine, listID: list.id, sortOrder: idx)
                }
                let count = items.count
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
