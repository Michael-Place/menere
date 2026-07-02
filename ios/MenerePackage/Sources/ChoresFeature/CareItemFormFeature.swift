import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

/// A one-tap starter for the House-care empty state — the family's real recurring upkeep.
/// Tapping one creates a pre-filled ``CareItem`` the user can edit afterward.
public struct CareSuggestion: Equatable, Identifiable, Sendable {
    public let id: String
    let name: String
    let icon: String
    let taskTitle: String
    let intervalDays: Int?

    func makeItem() -> CareItem {
        CareItem(
            kind: .house,
            name: name,
            iconSymbol: icon,
            tasks: [CareTask(title: taskTitle, intervalDays: intervalDays)]
        )
    }

    /// The Place family's real "stuff you always forget."
    static let starters: [CareSuggestion] = [
        .init(id: "hvac", name: "HVAC filter", icon: "wind", taskTitle: "Replace filter", intervalDays: 90),
        .init(id: "gutters", name: "Gutters", icon: "drop.fill", taskTitle: "Clean gutters", intervalDays: 180),
        .init(id: "kitchen", name: "Deep clean: kitchen", icon: "sparkles", taskTitle: "Deep clean", intervalDays: 30),
        .init(id: "bathrooms", name: "Deep clean: bathrooms", icon: "shower.fill", taskTitle: "Deep clean", intervalDays: 30),
        .init(id: "bedding", name: "Laundry: bedding", icon: "bed.double.fill", taskTitle: "Wash bedding", intervalDays: 14),
        .init(id: "waterheater", name: "Water heater flush", icon: "flame.fill", taskTitle: "Flush tank", intervalDays: 180),
    ]
}

@Reducer
public struct CareItemFormReducer {
    @ObservableState
    public struct State: Equatable {
        var item: CareItem
        let isEditing: Bool

        public init(item: CareItem, isEditing: Bool) {
            self.item = item
            self.isEditing = isEditing
        }
    }

    public enum Action: Equatable, BindableAction {
        case saveTapped
        case deleteTapped
        case addTaskTapped
        case removeTask(id: String)
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum Delegate: Equatable { case didChange }
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
            case .addTaskTapped:
                state.item.tasks.append(CareTask(title: "", intervalDays: 30))
                return .none

            case let .removeTask(id):
                state.item.tasks.removeAll { $0.id == id }
                return .none

            case .saveTapped:
                guard let hid = hid(),
                      !state.item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return .none }
                var item = state.item
                // Trim empty-title tasks and normalize a blank location to nil.
                item.tasks.removeAll { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if item.location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    item.location = nil
                }
                let saved = item
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveCareItem(hid, saved)
                    await send(.delegate(.didChange))
                    await dismiss()
                }

            case .deleteTapped:
                guard let hid = hid() else { return .none }
                let id = state.item.id
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.deleteCareItem(hid, id)
                    await send(.delegate(.didChange))
                    await dismiss()
                }

            case .delegate, .binding:
                return .none
            }
        }
    }
}

public struct CareItemFormView: View {
    @Bindable var store: StoreOf<CareItemFormReducer>
    private let columns = Array(repeating: GridItem(.flexible()), count: 4)

    public init(store: StoreOf<CareItemFormReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("What needs care?", text: $store.item.name)
                        .accessibilityIdentifier("care-name-field")
                }

                Section("Icon") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(CareItem.iconOptions, id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.title2)
                                .foregroundStyle(store.item.iconSymbol == symbol ? Color.bacanGreen : Color.inkSoft)
                                .frame(width: 40, height: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(store.item.iconSymbol == symbol ? Color.bacanGreen.opacity(0.15) : .clear)
                                )
                                .onTapGesture { store.item.iconSymbol = symbol }
                                .accessibilityIdentifier("care-icon-\(symbol)")
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Location") {
                    TextField("Where? (optional)", text: Binding(
                        get: { store.item.location ?? "" },
                        set: { store.item.location = $0 }
                    ))
                    .accessibilityIdentifier("care-location-field")
                }

                Section("Tasks") {
                    ForEach($store.item.tasks) { $task in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Task", text: $task.title)
                            Picker("Repeats", selection: $task.intervalDays) {
                                ForEach(CareItem.intervalChoices, id: \.self) { choice in
                                    Text(CareItem.intervalLabel(choice)).tag(choice)
                                }
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { indexSet in
                        for i in indexSet { store.send(.removeTask(id: store.item.tasks[i].id)) }
                    }
                    Button {
                        store.send(.addTaskTapped)
                    } label: {
                        Label("Add a task", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("add-care-task-button")
                }

                if store.isEditing {
                    Section {
                        Button("Delete", role: .destructive) { store.send(.deleteTapped) }
                            .accessibilityIdentifier("delete-care-button")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle(store.isEditing ? "Edit care item" : "New care item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveTapped) }
                        .accessibilityIdentifier("save-care-button")
                }
            }
        }
    }
}
