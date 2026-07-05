import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

@Reducer
public struct ListDetailReducer {
    @ObservableState
    public struct State: Equatable {
        public let list: FamilyList
        var members: [HouseholdMember]
        var items: [ListItem] = []
        var isLoading = false
        var newItemTitle = ""

        // Grocery specialization (P30) — only used when `list.isGrocery`.
        /// Live aisle guess for the item being typed (shown as a hint under the field).
        var suggestedCategory: GroceryCategory?
        /// Autocomplete matches for the current prefix (tap to fill).
        var autocompleteSuggestions: [String] = []

        public init(list: FamilyList, members: [HouseholdMember]) {
            self.list = list
            self.members = members
        }

        // MARK: Grocery groupings (categorize-on-display)

        /// Pending items grouped by aisle and ordered by store walk (`aisleOrder`). Each item's
        /// aisle is its stored `groceryCategory`, else a live `GroceryItemDB.categorize(title)`.
        var groupedPendingItems: [(category: GroceryCategory, items: [ListItem])] {
            let pending = items.filter { !$0.isCompleted }
            return Dictionary(grouping: pending, by: \.effectiveCategory)
                .map { (category: $0.key, items: $0.value.sorted { $0.sortOrder < $1.sortOrder }) }
                .sorted { $0.category.aisleOrder < $1.category.aisleOrder }
        }

        var completedItems: [ListItem] {
            items.filter(\.isCompleted).sorted { $0.sortOrder < $1.sortOrder }
        }

        var completedCount: Int { completedItems.count }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case itemsLoaded([ListItem])
        case addItem
        case suggestionTapped(String)
        case toggle(ListItem)
        case assign(item: ListItem, memberID: String?)
        case deleteItems(IndexSet)
        case deleteItem(id: String)
        case clearCompleted
        case binding(BindingAction<State>)
    }

    public init() {}

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                guard let hid = hid() else { return .none }
                state.isLoading = true
                let listID = state.list.id
                if state.list.isGrocery {
                    @Dependency(\.analytics) var analytics
                    analytics.log("grocery_list_opened")
                }
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let items = (try? await persistence.listItems(hid, listID)) ?? []
                    await send(.itemsLoaded(items))
                }

            case let .itemsLoaded(items):
                state.isLoading = false
                state.items = items.sorted {
                    $0.isCompleted == $1.isCompleted ? $0.sortOrder < $1.sortOrder : (!$0.isCompleted && $1.isCompleted)
                }
                return .none

            case .addItem:
                let title = state.newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let hid = hid() else { return .none }
                // On grocery lists, auto-tag the aisle at write time.
                let category: GroceryCategory? = state.list.isGrocery ? GroceryItemDB.categorize(title) : nil
                let item = ListItem(
                    title: title,
                    listID: state.list.id,
                    sortOrder: (state.items.map(\.sortOrder).max() ?? 0) + 1,
                    groceryCategory: category
                )
                state.items.append(item)
                state.newItemTitle = ""
                state.suggestedCategory = nil
                state.autocompleteSuggestions = []
                if state.list.isGrocery {
                    @Dependency(\.analytics) var analytics
                    analytics.log("grocery_item_added")
                }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveListItem(hid, item)
                }

            case let .suggestionTapped(suggestion):
                state.newItemTitle = suggestion
                state.suggestedCategory = GroceryItemDB.categorize(suggestion)
                state.autocompleteSuggestions = []
                return .none

            case let .toggle(item):
                guard let hid = hid(), let idx = state.items.firstIndex(where: { $0.id == item.id }) else { return .none }
                state.items[idx].isCompleted.toggle()
                let updated = state.items[idx]
                let listTitle = state.list.title
                @Shared(.user) var user
                let actorID = user?.id
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveListItem(hid, updated)
                    if updated.isCompleted {
                        try? await persistence.logActivity(hid, .listItemChecked(title: updated.title, list: listTitle, actorID: actorID))
                    }
                }

            case let .assign(item, memberID):
                guard let hid = hid(), let idx = state.items.firstIndex(where: { $0.id == item.id }) else { return .none }
                state.items[idx].assigneeID = memberID
                let updated = state.items[idx]
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveListItem(hid, updated)
                }

            case let .deleteItems(offsets):
                guard let hid = hid() else { return .none }
                let listID = state.list.id
                let toDelete = offsets.map { state.items[$0] }
                state.items.remove(atOffsets: offsets)
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    for item in toDelete { try await persistence.deleteListItem(hid, listID, item.id) }
                }

            case let .deleteItem(id):
                guard let hid = hid() else { return .none }
                let listID = state.list.id
                state.items.removeAll { $0.id == id }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.deleteListItem(hid, listID, id)
                }

            case .clearCompleted:
                guard let hid = hid() else { return .none }
                let listID = state.list.id
                let toDelete = state.items.filter(\.isCompleted)
                state.items.removeAll(where: \.isCompleted)
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    for item in toDelete { try await persistence.deleteListItem(hid, listID, item.id) }
                }

            case .binding(\.newItemTitle):
                // Live grocery auto-tag + autocomplete while typing.
                guard state.list.isGrocery else { return .none }
                let text = state.newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                state.suggestedCategory = text.isEmpty ? nil : GroceryItemDB.categorize(text)
                state.autocompleteSuggestions = GroceryItemDB.suggestions(prefix: text)
                return .none

            case .binding:
                return .none
            }
        }
    }
}

public struct ListDetailView: View {
    @Bindable var store: StoreOf<ListDetailReducer>

    public init(store: StoreOf<ListDetailReducer>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.list.isGrocery {
                groceryList
            } else {
                standardList
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle(store.list.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.task) }
    }

    // MARK: - Standard (flat checklist)

    private var standardList: some View {
        List {
            Section {
                ForEach(store.items) { item in
                    itemRow(item)
                }
                .onDelete { store.send(.deleteItems($0)) }
            }
            .listRowBackground(Color.familySurface)

            Section {
                addItemField
            }
            .listRowBackground(Color.familySurface)
        }
    }

    // MARK: - Grocery (aisle-grouped)

    private var groceryList: some View {
        List {
            Section {
                addItemField
                if let category = store.suggestedCategory {
                    Label(category.displayName, systemImage: category.icon)
                        .font(.caption2)
                        .foregroundStyle(Color.inkSoft)
                        .transition(.opacity)
                }
            }
            .listRowBackground(Color.familySurface)

            if !store.autocompleteSuggestions.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.autocompleteSuggestions, id: \.self) { suggestion in
                                Button { store.send(.suggestionTapped(suggestion)) } label: {
                                    Text(suggestion)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.bacanGreen.opacity(0.14))
                                        .clipShape(Capsule())
                                        .foregroundStyle(Color.ink)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listRowBackground(Color.familySurface)
            }

            if store.items.isEmpty, !store.isLoading {
                Section {
                    ContentUnavailableView(
                        "Nothing on the list yet",
                        systemImage: "cart",
                        description: Text("Add items and we'll sort them by aisle so the store trip flows.")
                    )
                }
                .listRowBackground(Color.familySurface)
            }

            ForEach(store.groupedPendingItems, id: \.category) { group in
                Section {
                    ForEach(group.items) { item in
                        groceryRow(item)
                    }
                    .onDelete { indexSet in
                        for index in indexSet { store.send(.deleteItem(id: group.items[index].id)) }
                    }
                } header: {
                    Label(group.category.displayName, systemImage: group.category.icon)
                        .foregroundStyle(Color.inkSoft)
                }
                .listRowBackground(Color.familySurface)
            }

            if !store.completedItems.isEmpty {
                Section {
                    ForEach(store.completedItems) { item in
                        groceryRow(item)
                    }
                    .onDelete { indexSet in
                        for index in indexSet { store.send(.deleteItem(id: store.completedItems[index].id)) }
                    }
                } header: {
                    HStack {
                        Text("Done (\(store.completedCount))").foregroundStyle(Color.inkSoft)
                        Spacer()
                        Button("Clear") { store.send(.clearCompleted) }
                            .font(.caption)
                            .foregroundStyle(Color.bacanGreen)
                    }
                }
                .listRowBackground(Color.familySurface)
            }
        }
        .animation(.snappy(duration: 0.3), value: store.items.map(\.isCompleted))
    }

    // MARK: - Shared pieces

    private var addItemField: some View {
        HStack {
            TextField(store.list.isGrocery ? "Add a grocery…" : "Add an item…", text: $store.newItemTitle)
                .onSubmit { store.send(.addItem) }
                .accessibilityIdentifier("new-list-item-field")
            Button { store.send(.addItem) } label: {
                Image(systemName: "plus.circle.fill").appearBounce()
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Color.bacanGreen)
            .disabled(store.newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private func groceryRow(_ item: ListItem) -> some View {
        HStack(spacing: 12) {
            checkButton(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? Color.inkSoft : Color.ink)
                if let note = item.note, !note.isEmpty {
                    Text(note).font(.caption2).foregroundStyle(Color.inkSoft)
                }
            }
            Spacer()
            if let quantity = item.quantity {
                Text(quantityLabel(quantity, unit: item.unit))
                    .font(.caption).foregroundStyle(Color.inkSoft)
            }
            assigneeMenu(item)
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ListItem) -> some View {
        HStack(spacing: 12) {
            checkButton(item)
            Text(item.title)
                .strikethrough(item.isCompleted)
                .foregroundStyle(item.isCompleted ? Color.inkSoft : Color.ink)
            Spacer()
            assigneeMenu(item)
        }
    }

    private func checkButton(_ item: ListItem) -> some View {
        Button { store.send(.toggle(item)) } label: {
            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isCompleted ? Color.bacanGreen : Color.inkSoft)
                .stickerSlap(isOn: item.isCompleted, color: .bacanGreen)
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder
    private func assigneeMenu(_ item: ListItem) -> some View {
        Menu {
            Button("Unassigned") { store.send(.assign(item: item, memberID: nil)) }
            ForEach(store.members) { member in
                Button(member.name) { store.send(.assign(item: item, memberID: member.id)) }
            }
        } label: {
            if let assignee = store.members.first(where: { $0.id == item.assigneeID }) {
                let rgb = assignee.color.rgb
                Text(initials(assignee.name))
                    .font(.caption2).fontWeight(.bold)
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue)))
            } else {
                Image(systemName: "person.crop.circle.badge.plus")
                    .foregroundStyle(Color.inkSoft)
            }
        }
    }

    private func quantityLabel(_ quantity: Double, unit: String?) -> String {
        let qty = quantity.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(quantity))
            : String(quantity)
        if let unit, !unit.isEmpty { return "\(qty) \(unit)" }
        return qty
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }
}
