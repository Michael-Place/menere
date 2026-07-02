import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

@Reducer
public struct ChoreFormReducer {
    @ObservableState
    public struct State: Equatable {
        var chore: Chore
        let isEditing: Bool
        var members: [HouseholdMember]
        var hasDueDate: Bool

        public init(chore: Chore, isEditing: Bool, members: [HouseholdMember]) {
            self.chore = chore
            self.isEditing = isEditing
            self.members = members
            self.hasDueDate = chore.dueDate != nil
        }
    }

    public enum Action: Equatable, BindableAction {
        case saveTapped
        case deleteTapped
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
            case .binding(\.hasDueDate):
                if state.hasDueDate, state.chore.dueDate == nil {
                    state.chore.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
                } else if !state.hasDueDate {
                    state.chore.dueDate = nil
                }
                return .none

            case .binding:
                return .none

            case .saveTapped:
                guard let hid = hid(),
                      !state.chore.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return .none }
                let chore = state.chore
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveChore(hid, chore)
                    await send(.delegate(.didChange))
                    await dismiss()
                }

            case .deleteTapped:
                guard let hid = hid() else { return .none }
                let id = state.chore.id
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.deleteChore(hid, id)
                    await send(.delegate(.didChange))
                    await dismiss()
                }

            case .delegate:
                return .none
            }
        }
    }
}

public struct ChoreFormView: View {
    @Bindable var store: StoreOf<ChoreFormReducer>

    public init(store: StoreOf<ChoreFormReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $store.chore.title)
                        .accessibilityIdentifier("chore-title-field")
                }

                Section("Difficulty") {
                    Picker("Difficulty", selection: $store.chore.difficulty) {
                        ForEach(ChoreDifficulty.allCases, id: \.self) { d in
                            Label("\(d.displayName) · \(d.baseXP) XP", systemImage: d.icon).tag(d)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Assign to") {
                    Picker("Assignee", selection: $store.chore.assigneeID) {
                        Text("Anyone").tag(String?.none)
                        ForEach(store.members) { member in
                            Text(member.name).tag(String?.some(member.id))
                        }
                    }
                }

                Section("Due") {
                    Toggle("Has due date", isOn: $store.hasDueDate)
                    if store.hasDueDate {
                        DatePicker(
                            "Due",
                            selection: Binding(
                                get: { store.chore.dueDate ?? Date() },
                                set: { store.chore.dueDate = $0 }
                            ),
                            displayedComponents: [.date]
                        )
                        Picker("Repeats", selection: $store.chore.recurrence) {
                            ForEach(RecurrenceOption.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                }

                if store.isEditing {
                    Section {
                        Button("Delete Chore", role: .destructive) { store.send(.deleteTapped) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle(store.isEditing ? "Edit Chore" : "New Chore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveTapped) }
                        .accessibilityIdentifier("save-chore-button")
                }
            }
        }
    }
}
