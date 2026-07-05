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

        // Packing specialization (P30.5) — only used when `list.isPacking`.
        /// The bucket a newly-typed packing item lands in (chosen via the add-row menu).
        var newItemCategory: PackingCategory = .misc
        /// Whose bag we're filtered to (`nil` = everyone). Also becomes new items' `forMemberID`.
        var packingFilterMemberID: String?
        /// Drives the reusable-template picker sheet.
        var showTemplatePicker = false

        // Gift specialization (P30.5) — only used when `list.isGift`. Fields for the add-gift form.
        var newGiftRecipient = ""
        var newGiftOccasion = ""
        var newGiftPrice = ""
        var newGiftLink = ""

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

        // MARK: Packing groupings (P30.5)

        /// Packing items (optionally filtered to one person's bag) grouped by `PackingCategory`
        /// and ordered by `sortOrder`; packed items sink to the bottom of each section.
        var groupedPackingItems: [(category: PackingCategory, items: [ListItem])] {
            let scoped = packingFilterMemberID == nil
                ? items
                : items.filter { $0.forMemberID == packingFilterMemberID }
            return Dictionary(grouping: scoped, by: \.effectivePackingCategory)
                .map { key, value in
                    (category: key, items: value.sorted {
                        $0.isCompleted == $1.isCompleted
                            ? $0.sortOrder < $1.sortOrder
                            : (!$0.isCompleted && $1.isCompleted)
                    })
                }
                .sorted { $0.category.sortOrder < $1.category.sortOrder }
        }

        /// (packed, total) for the currently-scoped packing items — drives the progress caption.
        var packingProgress: (packed: Int, total: Int) {
            let scoped = packingFilterMemberID == nil
                ? items
                : items.filter { $0.forMemberID == packingFilterMemberID }
            return (scoped.filter(\.isCompleted).count, scoped.count)
        }

        // MARK: Gift groupings (P30.5)

        var giftItems: [ListItem] {
            items.sorted { $0.sortOrder < $1.sortOrder }
        }

        /// Sum of every idea's `price` — the list's total-spend line.
        var totalGiftSpend: Double {
            items.compactMap(\.price).reduce(0, +)
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case itemsLoaded([ListItem])
        case addItem
        case addGift
        case seedTemplate(PackingTemplate)
        case setPackingFilter(String?)
        case suggestionTapped(String)
        case toggle(ListItem)
        case assign(item: ListItem, memberID: String?)
        case assignPackingMember(item: ListItem, memberID: String?)
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
                // On packing lists, tag the chosen bucket + whose bag (the active filter).
                let packingCategory: PackingCategory? = state.list.isPacking ? state.newItemCategory : nil
                let forMemberID: String? = state.list.isPacking ? state.packingFilterMemberID : nil
                let item = ListItem(
                    title: title,
                    listID: state.list.id,
                    sortOrder: (state.items.map(\.sortOrder).max() ?? 0) + 1,
                    groceryCategory: category,
                    packingCategory: packingCategory,
                    forMemberID: forMemberID
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

            case .addGift:
                let title = state.newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let hid = hid() else { return .none }
                func cleaned(_ s: String) -> String? {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : t
                }
                let item = ListItem(
                    title: title,
                    listID: state.list.id,
                    sortOrder: (state.items.map(\.sortOrder).max() ?? 0) + 1,
                    recipient: cleaned(state.newGiftRecipient),
                    occasion: cleaned(state.newGiftOccasion),
                    price: Double(state.newGiftPrice.trimmingCharacters(in: .whitespaces)),
                    link: cleaned(state.newGiftLink)
                )
                state.items.append(item)
                state.newItemTitle = ""
                state.newGiftRecipient = ""
                state.newGiftOccasion = ""
                state.newGiftPrice = ""
                state.newGiftLink = ""
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveListItem(hid, item)
                }

            case let .seedTemplate(template):
                guard let hid = hid() else { return .none }
                state.showTemplatePicker = false
                let base = state.items.map(\.sortOrder).max() ?? 0
                let forMemberID = state.packingFilterMemberID
                let listID = state.list.id
                let newItems: [ListItem] = template.entries.enumerated().map { index, entry in
                    ListItem(
                        title: entry.title,
                        listID: listID,
                        sortOrder: base + index + 1,
                        packingCategory: entry.category,
                        forMemberID: forMemberID
                    )
                }
                state.items.append(contentsOf: newItems)
                @Dependency(\.analytics) var analytics
                analytics.log("packing_template_seeded")
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    for item in newItems { try await persistence.saveListItem(hid, item) }
                }

            case let .setPackingFilter(memberID):
                state.packingFilterMemberID = memberID
                return .none

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

            case let .assignPackingMember(item, memberID):
                guard let hid = hid(), let idx = state.items.firstIndex(where: { $0.id == item.id }) else { return .none }
                state.items[idx].forMemberID = memberID
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
            } else if store.list.isPacking {
                packingList
            } else if store.list.isGift {
                giftList
            } else {
                standardList
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle(store.list.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.list.isPacking {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { store.send(.setPackingFilter(nil)) } label: {
                            Label("Everyone", systemImage: store.packingFilterMemberID == nil ? "checkmark" : "person.2")
                        }
                        ForEach(store.members) { member in
                            Button { store.send(.setPackingFilter(member.id)) } label: {
                                Label(member.name, systemImage: store.packingFilterMemberID == member.id ? "checkmark" : "person")
                            }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityIdentifier("packing-filter-menu")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { store.showTemplatePicker = true } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .accessibilityIdentifier("packing-template-button")
                }
            }
        }
        .sheet(isPresented: $store.showTemplatePicker) {
            PackingTemplatePicker(store: store)
                .presentationDetents([.medium, .large])
        }
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

    // MARK: - Packing (per-person, category-grouped)

    private var packingList: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("Add something to pack…", text: $store.newItemTitle)
                        .onSubmit { store.send(.addItem) }
                        .accessibilityIdentifier("new-list-item-field")
                    Menu {
                        ForEach(PackingCategory.allCases, id: \.self) { category in
                            Button { store.newItemCategory = category } label: {
                                Label(category.displayName, systemImage: category.icon)
                            }
                        }
                    } label: {
                        Image(systemName: store.newItemCategory.icon)
                            .foregroundStyle(Color.inkSoft)
                    }
                    .accessibilityIdentifier("packing-category-menu")
                    Button { store.send(.addItem) } label: {
                        Image(systemName: "plus.circle.fill").appearBounce()
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(Color.bacanGreen)
                    .disabled(store.newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("Filing under \(store.newItemCategory.displayName)\(packingScopeSuffix).")
                    .font(.caption2)
                    .foregroundStyle(Color.inkSoft)
            }
            .listRowBackground(Color.familySurface)

            let progress = store.packingProgress
            if progress.total > 0 {
                Section {
                    Label("\(progress.packed) of \(progress.total) packed", systemImage: "suitcase.fill")
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                }
                .listRowBackground(Color.familySurface)
            }

            if store.items.isEmpty, !store.isLoading {
                Section {
                    VStack(spacing: 14) {
                        ContentUnavailableView(
                            "Nothing packed yet",
                            systemImage: "suitcase",
                            description: Text("Add items one by one, or start from a ready-made template.")
                        )
                        Button { store.showTemplatePicker = true } label: {
                            Label("Start from a template", systemImage: "square.grid.2x2")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Color.bacanGreen)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("packing-empty-template-button")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.familySurface)
            }

            ForEach(store.groupedPackingItems, id: \.category) { group in
                Section {
                    ForEach(group.items) { item in
                        packingRow(item)
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
        }
        .animation(.snappy(duration: 0.3), value: store.items.map(\.isCompleted))
    }

    /// " for Oliver" / "" depending on the active packing filter — for the add-row footer.
    private var packingScopeSuffix: String {
        guard let id = store.packingFilterMemberID,
              let member = store.members.first(where: { $0.id == id }) else { return "" }
        return " for \(member.name)"
    }

    @ViewBuilder
    private func packingRow(_ item: ListItem) -> some View {
        HStack(spacing: 12) {
            checkButton(item)
            Text(item.title)
                .strikethrough(item.isCompleted)
                .foregroundStyle(item.isCompleted ? Color.inkSoft : Color.ink)
            Spacer()
            packingMemberMenu(item)
        }
    }

    @ViewBuilder
    private func packingMemberMenu(_ item: ListItem) -> some View {
        Menu {
            Button("Shared") { store.send(.assignPackingMember(item: item, memberID: nil)) }
            ForEach(store.members) { member in
                Button(member.name) { store.send(.assignPackingMember(item: item, memberID: member.id)) }
            }
        } label: {
            if let member = store.members.first(where: { $0.id == item.forMemberID }) {
                let rgb = member.color.rgb
                Text(initials(member.name))
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

    // MARK: - Gift (recipient / occasion / price / link, bought-status)

    private var giftList: some View {
        List {
            Section {
                TextField("Gift idea…", text: $store.newItemTitle)
                    .accessibilityIdentifier("new-list-item-field")
                TextField("For whom", text: $store.newGiftRecipient)
                TextField("Occasion (Birthday, Christmas…)", text: $store.newGiftOccasion)
                HStack {
                    Text("$").foregroundStyle(Color.inkSoft)
                    TextField("Price", text: $store.newGiftPrice)
                        .keyboardType(.decimalPad)
                }
                TextField("Link", text: $store.newGiftLink)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button { store.send(.addGift) } label: {
                    Label("Add gift", systemImage: "gift")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.bacanGreen)
                }
                .buttonStyle(.pressable)
                .disabled(store.newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("add-gift-button")
            } header: {
                Text("Add a gift")
            }
            .listRowBackground(Color.familySurface)

            Section {
                Label(
                    "Gifts stay hidden from the person they're for — shop away without spoiling the surprise.",
                    systemImage: "eye.slash"
                )
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
            }
            .listRowBackground(Color.familySurface)

            if store.giftItems.isEmpty, !store.isLoading {
                Section {
                    ContentUnavailableView(
                        "No gift ideas yet",
                        systemImage: "gift",
                        description: Text("Jot down ideas as they strike — recipient, price, and a link to buy.")
                    )
                }
                .listRowBackground(Color.familySurface)
            } else {
                Section {
                    ForEach(store.giftItems) { item in
                        giftRow(item)
                    }
                    .onDelete { indexSet in
                        for index in indexSet { store.send(.deleteItem(id: store.giftItems[index].id)) }
                    }
                } header: {
                    HStack {
                        Text("Ideas").foregroundStyle(Color.inkSoft)
                        Spacer()
                        if store.totalGiftSpend > 0 {
                            Text("Total \(currency(store.totalGiftSpend))")
                                .foregroundStyle(Color.inkSoft)
                        }
                    }
                }
                .listRowBackground(Color.familySurface)
            }
        }
        .animation(.snappy(duration: 0.3), value: store.items.map(\.isCompleted))
    }

    @ViewBuilder
    private func giftRow(_ item: ListItem) -> some View {
        HStack(spacing: 12) {
            checkButton(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? Color.inkSoft : Color.ink)
                let subtitle = [item.recipient, item.occasion]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(Color.inkSoft)
                }
                if let link = item.link, let url = URL(string: normalizedURLString(link)) {
                    Link(destination: url) {
                        Label("Open link", systemImage: "link")
                            .font(.caption2)
                            .foregroundStyle(Color.sky)
                    }
                }
            }
            Spacer()
            if let price = item.price {
                Text(currency(price))
                    .font(.caption).foregroundStyle(Color.inkSoft)
            }
        }
    }

    private func currency(_ value: Double) -> String {
        let formatted = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2f", value)
        return "$\(formatted)"
    }

    /// Prepend `https://` when a link lacks a scheme so bare `store.com/x` still opens.
    private func normalizedURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return trimmed }
        return "https://\(trimmed)"
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

/// The reusable-template picker for packing lists (P30.5). Tapping a template seeds its
/// categorized items into the current list (respecting the active per-person filter).
private struct PackingTemplatePicker: View {
    @Bindable var store: StoreOf<ListDetailReducer>

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pick a starting point — we'll drop in the essentials, already sorted into categories. Tweak from there.")
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                }
                .listRowBackground(Color.familySurface)

                Section {
                    ForEach(PackingTemplate.all) { template in
                        Button {
                            store.send(.seedTemplate(template))
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: template.icon)
                                    .font(.title3)
                                    .foregroundStyle(Color.bacanGreen)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.ink)
                                    Text(template.blurb)
                                        .font(.caption)
                                        .foregroundStyle(Color.inkSoft)
                                    Text("\(template.entries.count) items")
                                        .font(.caption2)
                                        .foregroundStyle(Color.inkSoft)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Color.bacanGreen)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("packing-template-\(template.id)")
                    }
                }
                .listRowBackground(Color.familySurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Packing templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.showTemplatePicker = false }
                }
            }
        }
    }
}
