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

        public init(list: FamilyList, members: [HouseholdMember]) {
            self.list = list
            self.members = members
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case itemsLoaded([ListItem])
        case addItem
        case toggle(ListItem)
        case assign(item: ListItem, memberID: String?)
        case deleteItems(IndexSet)
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
                let item = ListItem(
                    title: title,
                    listID: state.list.id,
                    sortOrder: (state.items.map(\.sortOrder).max() ?? 0) + 1
                )
                state.items.append(item)
                state.newItemTitle = ""
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveListItem(hid, item)
                }

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
        List {
            Section {
                ForEach(store.items) { item in
                    itemRow(item)
                }
                .onDelete { store.send(.deleteItems($0)) }
            }
            .listRowBackground(Color.familySurface)

            Section {
                HStack {
                    TextField("Add an item…", text: $store.newItemTitle)
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
            .listRowBackground(Color.familySurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle(store.list.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.task) }
    }

    @ViewBuilder
    private func itemRow(_ item: ListItem) -> some View {
        HStack(spacing: 12) {
            Button { store.send(.toggle(item)) } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isCompleted ? Color.bacanGreen : Color.inkSoft)
                    .stickerSlap(isOn: item.isCompleted, color: .bacanGreen)
            }
            .buttonStyle(.pressable)

            Text(item.title)
                .strikethrough(item.isCompleted)
                .foregroundStyle(item.isCompleted ? Color.inkSoft : Color.ink)

            Spacer()

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
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }
}
