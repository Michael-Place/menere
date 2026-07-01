import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

@Reducer
public struct ListsReducer {
    @ObservableState
    public struct State: Equatable {
        var lists: [FamilyList] = []
        var members: [HouseholdMember] = []
        var isLoading = false
        var showAddSheet = false
        var newTitle = ""
        @Presents var detail: ListDetailReducer.State?

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case task
        case listsLoaded([FamilyList])
        case membersLoaded([HouseholdMember])
        case addTapped
        case createList
        case deleteLists(IndexSet)
        case listTapped(FamilyList)
        case detail(PresentationAction<ListDetailReducer.Action>)
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
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    async let lists = persistence.lists(hid)
                    async let members = persistence.members(hid)
                    await send(.listsLoaded((try? await lists) ?? []))
                    await send(.membersLoaded((try? await members) ?? []))
                }

            case let .listsLoaded(lists):
                state.isLoading = false
                state.lists = lists.sorted { $0.createdAt < $1.createdAt }
                return .none

            case let .membersLoaded(members):
                state.members = members
                return .none

            case .addTapped:
                state.newTitle = ""
                state.showAddSheet = true
                return .none

            case .createList:
                let title = state.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let hid = hid() else { return .none }
                let list = FamilyList(title: title)
                state.lists.append(list)
                state.showAddSheet = false
                state.newTitle = ""
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveList(hid, list)
                }

            case let .deleteLists(offsets):
                guard let hid = hid() else { return .none }
                let toDelete = offsets.map { state.lists[$0] }
                state.lists.remove(atOffsets: offsets)
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    for list in toDelete { try await persistence.deleteList(hid, list.id) }
                }

            case let .listTapped(list):
                state.detail = ListDetailReducer.State(list: list, members: state.members)
                return .none

            case .detail:
                return .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$detail, action: \.detail) {
            ListDetailReducer()
        }
    }
}

public struct ListsView: View {
    @Bindable var store: StoreOf<ListsReducer>

    public init(store: StoreOf<ListsReducer>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.lists.isEmpty, store.isLoading {
                ProgressView()
            } else if store.lists.isEmpty {
                ContentUnavailableView(
                    "No lists yet",
                    systemImage: "checklist",
                    description: Text("Tap + to start a shared family list.")
                )
            } else {
                List {
                    ForEach(store.lists) { list in
                        Button {
                            store.send(.listTapped(list))
                        } label: {
                            Label {
                                Text(list.title).foregroundStyle(Color.ink)
                            } icon: {
                                let rgb = list.color.rgb
                                Image(systemName: list.icon)
                                    .foregroundStyle(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                            }
                        }
                    }
                    .onDelete { store.send(.deleteLists($0)) }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.parchment)
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.send(.addTapped) } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("add-list-button")
            }
        }
        .task { store.send(.task) }
        .navigationDestination(
            item: $store.scope(state: \.detail, action: \.detail)
        ) { detailStore in
            ListDetailView(store: detailStore)
        }
        .alert("New List", isPresented: $store.showAddSheet) {
            TextField("List name", text: $store.newTitle)
            Button("Cancel", role: .cancel) { store.showAddSheet = false }
            Button("Create") { store.send(.createList) }
        }
    }
}
