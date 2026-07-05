import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

@Reducer
public struct RecipeFormReducer {
    @ObservableState
    public struct State: Equatable {
        var recipe: Recipe
        let isEditing: Bool
        var newIngredient = ""
        var newInstruction = ""
        var isImporting = false
        var importError: String?

        public init(recipe: Recipe, isEditing: Bool) {
            self.recipe = recipe
            self.isEditing = isEditing
        }
    }

    public enum Action: Equatable, BindableAction {
        case addIngredient
        case removeIngredients(IndexSet)
        case addInstruction
        case removeInstructions(IndexSet)
        case importFromURLTapped
        case importResponse(Result<Recipe, ImportFailure>)
        case saveTapped
        case deleteTapped
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum Delegate: Equatable { case didChange }
        public struct ImportFailure: Equatable, Error { public var message: String }
    }

    public init() {}

    @Dependency(\.dismiss) var dismiss

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .addIngredient:
                let name = state.newIngredient.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return .none }
                state.recipe.ingredients.append(Ingredient(name: name))
                state.newIngredient = ""
                return .none

            case let .removeIngredients(offsets):
                state.recipe.ingredients.remove(atOffsets: offsets)
                return .none

            case .addInstruction:
                let step = state.newInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !step.isEmpty else { return .none }
                state.recipe.instructions.append(step)
                state.newInstruction = ""
                return .none

            case let .removeInstructions(offsets):
                state.recipe.instructions.remove(atOffsets: offsets)
                return .none

            case .importFromURLTapped:
                let url = (state.recipe.sourceURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty, !state.isImporting else { return .none }
                state.isImporting = true
                state.importError = nil
                return .run { send in
                    @Dependency(\.recipeImport) var recipeImport
                    do {
                        let imported = try await recipeImport.importFromURL(url)
                        await send(.importResponse(.success(imported)))
                    } catch {
                        await send(.importResponse(.failure(.init(message: error.localizedDescription))))
                    }
                }

            case let .importResponse(.success(imported)):
                state.isImporting = false
                @Dependency(\.analytics) var analytics
                analytics.log("recipe_imported")   // P25 telemetry (fire-and-forget)
                // Keep the existing id/favorite; overlay imported content.
                state.recipe.title = imported.title
                state.recipe.servings = imported.servings
                state.recipe.ingredients = imported.ingredients
                state.recipe.instructions = imported.instructions
                if let src = imported.sourceURL { state.recipe.sourceURL = src }
                if let img = imported.imageURL { state.recipe.imageURL = img }
                return .none

            case let .importResponse(.failure(failure)):
                state.isImporting = false
                state.importError = failure.message
                return .none

            case .saveTapped:
                guard let hid = hid(),
                      !state.recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return .none }
                state.recipe.updatedAt = Date()
                let recipe = state.recipe
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveRecipe(hid, recipe)
                    await send(.delegate(.didChange))
                    await dismiss()
                }

            case .deleteTapped:
                guard let hid = hid() else { return .none }
                let id = state.recipe.id
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.deleteRecipe(hid, id)
                    await send(.delegate(.didChange))
                    await dismiss()
                }

            case .delegate:
                return .none

            case .binding:
                return .none
            }
        }
    }
}

public struct RecipeFormView: View {
    @Bindable var store: StoreOf<RecipeFormReducer>

    /// Non-destructive "scale to serve" target — display-only, seeded from the recipe's own
    /// servings and reset whenever that changes. Never written back to the recipe.
    @State private var targetServings: Int?
    /// Drives the full-screen Cook Mode cover.
    @State private var isCooking = false

    public init(store: StoreOf<RecipeFormReducer>) {
        self.store = store
    }

    /// The effective scale target (defaults to the recipe's own servings until the stepper moves).
    private var effectiveServings: Int { targetServings ?? store.recipe.servings }
    private var scale: Double {
        ServingsMath.scale(target: effectiveServings, original: store.recipe.servings)
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let imageURL = store.recipe.imageURL, let url = URL(string: imageURL) {
                    Section {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case let .success(image):
                                image.resizable().scaledToFill()
                            case .empty:
                                ZStack { Color.bacanGreen.opacity(0.12); ProgressView() }
                            default:
                                ZStack {
                                    Color.bacanGreen.opacity(0.12)
                                    Image(systemName: "fork.knife")
                                        .font(.largeTitle).foregroundStyle(Color.bacanGreen)
                                }
                            }
                        }
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }

                Section {
                    TextField("Title", text: $store.recipe.title)
                        .accessibilityIdentifier("recipe-title-field")
                    Stepper("Servings: \(store.recipe.servings)", value: $store.recipe.servings, in: 1...24)
                    Toggle("Favorite", isOn: $store.recipe.isFavorite)
                    TextField("Source URL", text: Binding(
                        get: { store.recipe.sourceURL ?? "" },
                        set: { store.recipe.sourceURL = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                    Button {
                        store.send(.importFromURLTapped)
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import from URL")
                            Spacer()
                            if store.isImporting { ProgressView() }
                        }
                    }
                    .disabled((store.recipe.sourceURL ?? "").isEmpty || store.isImporting)
                    .accessibilityIdentifier("import-recipe-button")

                    if let err = store.importError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }

                cookSection

                Section("Ingredients") {
                    ForEach(store.recipe.ingredients) { ing in
                        Text(ServingsMath.scaledLine(ing, scale: scale)).foregroundStyle(Color.ink)
                    }
                    .onDelete { store.send(.removeIngredients($0)) }
                    HStack {
                        TextField("Add ingredient", text: $store.newIngredient)
                            .onSubmit { store.send(.addIngredient) }
                        Button { store.send(.addIngredient) } label: { Image(systemName: "plus.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(Color.bacanGreen)
                    }
                }

                Section("Instructions") {
                    ForEach(Array(store.recipe.instructions.enumerated()), id: \.offset) { idx, step in
                        Text("\(idx + 1). \(step)").foregroundStyle(Color.ink)
                    }
                    .onDelete { store.send(.removeInstructions($0)) }
                    HStack {
                        TextField("Add step", text: $store.newInstruction, axis: .vertical)
                            .writingToolsBehavior(.complete)
                            .onSubmit { store.send(.addInstruction) }
                        Button { store.send(.addInstruction) } label: { Image(systemName: "plus.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(Color.bacanGreen)
                    }
                }

                // Rich-Text C1 — the family's personal tweaks ("Mom's tweak: less sugar…"),
                // persisted as Markdown via the recipe's own Save path. Writing Tools + Genmoji ride
                // along for free (Apple-Intelligence devices only).
                Section("Notes") {
                    RichNoteEditor(
                        markdown: Binding(
                            get: { store.recipe.notes ?? "" },
                            set: { store.recipe.notes = $0.isEmpty ? nil : $0 }
                        ),
                        placeholder: "Mom's tweak, swaps, what worked…"
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
                }

                if store.isEditing {
                    Section {
                        Button("Delete Recipe", role: .destructive) { store.send(.deleteTapped) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle(store.isEditing ? "Edit Recipe" : "New Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveTapped) }
                        .accessibilityIdentifier("save-recipe-button")
                }
            }
            // Editing the recipe's own servings resets any display-only scaling.
            .onChange(of: store.recipe.servings) { targetServings = nil }
            .fullScreenCover(isPresented: $isCooking) {
                CookModeView(recipe: store.recipe, initialServings: effectiveServings)
            }
        }
    }

    // MARK: Cook + servings scaler

    /// A non-destructive "scale to serve" control + "Start cooking" entry point. Shown only once a
    /// recipe has content to cook from, so a blank new recipe stays uncluttered.
    @ViewBuilder
    private var cookSection: some View {
        if !store.recipe.ingredients.isEmpty || !store.recipe.instructions.isEmpty {
            Section("Cook") {
                Stepper(value: scaleBinding, in: 1...48) {
                    HStack {
                        Label("Scale to serve", systemImage: "person.2.fill")
                            .foregroundStyle(Color.ink)
                        Spacer()
                        Text("\(effectiveServings)")
                            .font(.system(.body, design: .rounded).weight(.bold))
                            .foregroundStyle(Color.bacanGreen)
                    }
                }
                .accessibilityIdentifier("scale-servings-stepper")

                if effectiveServings != store.recipe.servings {
                    Text("Showing quantities for \(effectiveServings) — this recipe makes \(store.recipe.servings). The recipe itself is unchanged.")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                    Button("Reset to \(store.recipe.servings)") { targetServings = nil }
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.bacanGreen)
                }

                Button {
                    isCooking = true
                } label: {
                    HStack {
                        Spacer()
                        Label("Start cooking", systemImage: "flame.fill")
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                }
                .listRowBackground(Color.bacanGreen)
                .disabled(store.recipe.instructions.isEmpty)
                .accessibilityIdentifier("start-cooking-button")
            }
        }
    }

    /// Binding for the scaler stepper — reads the effective target, writes the display-only override.
    private var scaleBinding: Binding<Int> {
        Binding(get: { effectiveServings }, set: { targetServings = $0 })
    }
}
