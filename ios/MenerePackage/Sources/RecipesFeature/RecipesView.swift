import ComposableArchitecture
import FamilyDomain
import MenereUI
import SwiftUI

public struct RecipesView: View {
    @Bindable var store: StoreOf<RecipesReducer>
    private let cal = Calendar.current

    public init(store: StoreOf<RecipesReducer>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            FamilySegmentedControl(
                selection: $store.segment,
                options: RecipesReducer.Segment.allCases.map { ($0, $0.rawValue) }
            )
            .padding()
            .selectionHaptic(store.segment)

            switch store.segment {
            case .recipes: recipesList
            case .mealPlan: mealPlan
            }
        }
        .background(Color.familyCanvas)
        .navigationTitle("Kitchen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.segment == .recipes {
                ToolbarItem(placement: .primaryAction) {
                    Button { store.send(.addTapped) } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("add-recipe-button")
                }
            }
        }
        .task { store.send(.task) }
        .sheet(item: $store.scope(state: \.form, action: \.form)) { formStore in
            RecipeFormView(store: formStore)
        }
        .alert(
            "Grocery list",
            isPresented: Binding(
                get: { store.generatedMessage != nil },
                set: { if !$0 { store.send(.dismissGeneratedMessage) } }
            )
        ) {
            Button("OK") { store.send(.dismissGeneratedMessage) }
        } message: {
            Text(store.generatedMessage ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { store.eatingOutDay != nil },
                set: { if !$0 { store.send(.eatingOutDismissed) } }
            )
        ) {
            EatingOutSheet(store: store)
        }
    }

    // MARK: Recipes

    private var recipesList: some View {
        Group {
            if store.recipes.isEmpty, store.isLoading {
                ProgressView().frame(maxHeight: .infinity)
            } else if store.recipes.isEmpty {
                ContentUnavailableView(
                    "No recipes yet",
                    systemImage: "book.closed",
                    description: Text("Add one, or import from a URL — future dinner-you says thanks.")
                )
            } else {
                List {
                    ForEach(store.recipes) { recipe in
                        Button { store.send(.editTapped(recipe)) } label: {
                            HStack(spacing: 12) {
                                RecipeThumbnail(imageURL: recipe.imageURL)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(recipe.title).foregroundStyle(Color.ink)
                                    Text("\(recipe.ingredients.count) ingredients · serves \(recipe.servings)")
                                        .font(.caption).foregroundStyle(Color.inkSoft)
                                }
                                Spacer(minLength: 0)
                                Button { store.send(.toggleFavorite(recipe)) } label: {
                                    Image(systemName: recipe.isFavorite ? "star.fill" : "star")
                                        .foregroundStyle(recipe.isFavorite ? Color.marigold : Color.inkSoft)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.familyCanvas)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.familyCanvas)
            }
        }
    }

    // MARK: Meal plan

    private var weekDays: [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: store.weekStart) }
    }

    private func entry(for day: Date) -> MealPlanEntry? {
        store.mealPlan.first { cal.isDate($0.date, inSameDayAs: day) }
    }

    private var mealPlan: some View {
        VStack(spacing: 0) {
            List {
                ForEach(weekDays, id: \.self) { day in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(dayName(day)).foregroundStyle(Color.ink)
                            if let e = entry(for: day) {
                                if e.isEatingOut {
                                    HStack(spacing: 4) {
                                        Image(systemName: "storefront").foregroundStyle(Color.marigold)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(eatingOutLine(e)).font(.caption).foregroundStyle(Color.marigold)
                                            Text(e.restaurantAddress ?? "Eating out")
                                                .font(.caption2).foregroundStyle(Color.inkSoft)
                                                .lineLimit(1)
                                        }
                                    }
                                } else {
                                    Text(e.recipeTitle).font(.caption).foregroundStyle(Color.bacanGreen)
                                }
                            } else {
                                Text("Nothing planned — cereal night?").font(.caption).foregroundStyle(Color.inkSoft)
                            }
                        }
                        Spacer()
                        Menu {
                            Button {
                                store.send(.eatingOutTapped(date: day))
                            } label: {
                                Label("Eating out…", systemImage: "fork.knife.circle")
                            }
                            if !store.recipes.isEmpty {
                                Divider()
                                ForEach(store.recipes) { recipe in
                                    Button(recipe.title) { store.send(.assignMeal(date: day, recipe: recipe)) }
                                }
                            }
                            if let e = entry(for: day) {
                                Divider()
                                Button("Clear", role: .destructive) { store.send(.clearMeal(e)) }
                            }
                        } label: {
                            Image(systemName: "pencil.circle").foregroundStyle(Color.bacanGreen)
                        }
                    }
                    .listRowBackground(Color.familyCanvas)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)

            Button {
                store.send(.generateGroceryList)
            } label: {
                Label("Generate grocery list", systemImage: "cart.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .background(Color.bacanGreen)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding()
            .accessibilityIdentifier("generate-grocery-list-button")
        }
    }

    private func dayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }

    /// "Test Bistro" or, with a reservation, "Test Bistro · 7:30".
    private func eatingOutLine(_ entry: MealPlanEntry) -> String {
        let name = entry.restaurantName ?? ""
        if let time = entry.reservationTimeShort { return "\(name) · \(time)" }
        return name
    }
}

/// A small rounded leading square for a recipe row: loads the recipe photo when there is one,
/// shows a warm placeholder while it loads, and falls back to a tinted food glyph when the recipe
/// has no image (or the URL fails to load).
struct RecipeThumbnail: View {
    let imageURL: String?
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        placeholder(showsSpinner: true)
                    default:
                        placeholder(showsSpinner: false)
                    }
                }
            } else {
                placeholder(showsSpinner: false)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func placeholder(showsSpinner: Bool) -> some View {
        ZStack {
            Color.bacanGreen.opacity(0.14)
            if showsSpinner {
                ProgressView()
            } else {
                Image(systemName: "fork.knife")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(Color.bacanGreen)
            }
        }
    }
}
