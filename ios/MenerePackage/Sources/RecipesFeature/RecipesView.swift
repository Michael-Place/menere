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
                    // Motion & Delight — Kitchen's signature: recipe cards RISE + settle (slide-up +
                    // fade), a "plating" feel. Replays on every (re)selection.
                    ForEach(Array(store.recipes.enumerated()), id: \.element.id) { index, recipe in
                        Button { store.send(.editTapped(recipe)) } label: {
                            HStack(spacing: 12) {
                                RecipeThumbnail(imageURL: recipe.imageURL)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(recipe.title).foregroundStyle(Color.ink)
                                    HStack(spacing: 6) {
                                        if let effort = recipe.effort { EffortChip(effort: effort) }
                                        Text("\(recipe.ingredients.count) ingredients · serves \(recipe.servings)")
                                            .font(.caption).foregroundStyle(Color.inkSoft)
                                    }
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
                        .tabEntrance(.rise, index: index)
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

    /// The full recipe backing a day's entry (for the thumbnail + effort chip), matched by id.
    private func recipe(for entry: MealPlanEntry) -> Recipe? {
        store.recipes.first { $0.id == entry.recipeID }
    }

    private var mealPlan: some View {
        VStack(spacing: 0) {
            // "Plan my week ✨" — the AI rhythm. Shimmers while Claude is thinking.
            Button {
                store.send(.planWeekTapped)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(store.isPlanningWeek ? "Planning the week…" : "Plan my week")
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .redacted(reason: store.isPlanningWeek ? .placeholder : [])
                .shimmering(active: store.isPlanningWeek)
            }
            .background(Color.marigold.opacity(0.22))
            .foregroundStyle(Color.terracotta)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(store.isPlanningWeek)
            .padding(.horizontal)
            .padding(.bottom, 4)
            .accessibilityIdentifier("plan-my-week-button")

            List {
                ForEach(Array(weekDays.enumerated()), id: \.element) { index, day in
                    dayRow(day)
                        .listRowBackground(
                            cal.isDateInToday(day) ? Color.bacanGreen.opacity(0.10) : Color.familyCanvas
                        )
                        .tabEntrance(.rise, index: index)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)

            if !groceryEstimate.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "cart.badge.questionmark")
                        .font(.footnote)
                        .foregroundStyle(Color.bacanGreen)
                    Text("Estimated groceries this week: ~\(Self.currency(groceryEstimate.total))")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal)
                .accessibilityIdentifier("grocery-cost-estimate")
                Text("A rough guess from typical prices — not a real total.")
                    .font(.caption2)
                    .foregroundStyle(Color.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 1)
            }

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

    /// The MEAL→GROCERY cost loop (V1-C): a ballpark price on this week's shopping trip, computed
    /// from the meal plan's dinners. An honest estimate — see `GroceryCostEstimator`.
    private var groceryEstimate: GroceryCostEstimator.Estimate {
        GroceryCostEstimator.weeklyEstimate(
            recipes: store.recipes, mealPlan: store.mealPlan, weekStart: store.weekStart
        )
    }

    static func currency(_ amount: Double) -> String {
        amount.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    @ViewBuilder
    private func dayRow(_ day: Date) -> some View {
        let e = entry(for: day)
        HStack(spacing: 12) {
            if let e, !e.isEatingOut, let r = recipe(for: e) {
                RecipeThumbnail(imageURL: r.imageURL, size: 44)
            } else if let e, e.isEatingOut {
                thumbGlyph("storefront", tint: .marigold)
            } else {
                thumbGlyph("plus", tint: .inkSoft)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dayName(day)).foregroundStyle(Color.ink)
                    if cal.isDateInToday(day) {
                        Text("Today").font(.caption2).fontWeight(.bold)
                            .foregroundStyle(Color.bacanGreen)
                    }
                }
                if let e {
                    if e.isEatingOut {
                        Text(eatingOutLine(e)).font(.caption).foregroundStyle(Color.marigold)
                    } else {
                        HStack(spacing: 6) {
                            Text(e.recipeTitle).font(.caption).foregroundStyle(Color.bacanGreen)
                            if let r = recipe(for: e), let effort = r.effort { EffortChip(effort: effort) }
                        }
                    }
                } else {
                    Text("Add a dinner").font(.caption).foregroundStyle(Color.inkSoft)
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
                if let e {
                    Divider()
                    Button("Clear", role: .destructive) { store.send(.clearMeal(e)) }
                }
            } label: {
                Image(systemName: "pencil.circle").foregroundStyle(Color.bacanGreen)
            }
        }
    }

    private func thumbGlyph(_ systemName: String, tint: Color) -> some View {
        ZStack {
            Color.bacanGreen.opacity(0.10)
            Image(systemName: systemName).font(.system(size: 18, weight: .medium)).foregroundStyle(tint)
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

/// A subtle "Quick" / "Project" pill (P23 — effort at a glance). Quick reads sage-green (a
/// weeknight go), Project reads terracotta (a weekend cook).
struct EffortChip: View {
    let effort: RecipeEffort

    private var tint: Color { effort == .quick ? .bacanGreen : .terracotta }

    var body: some View {
        Text(effort.label)
            .font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.16))
            .foregroundStyle(tint)
            .clipShape(Capsule())
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
                BacanImage(url: url, targetSize: CGSize(width: size, height: size), contentMode: .fill) {
                    placeholder(showsSpinner: false)
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
