import CellarFeature
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import ScanFeature
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

        // Wine cellar is re-homed here as a pinned "collection" entry. Pushing the Cellar
        // presents the full wine stack; Scan is a full-screen modal over it (as before).
        @Presents var cellar: CellarReducer.State?
        var showScan = false
        var scan = ScanReducer.State()

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
        case cellarTapped
        case cellar(PresentationAction<CellarReducer.Action>)
        case scan(ScanReducer.Action)
        case scanRequested
        case scanDismissed
        case binding(BindingAction<State>)
    }

    public init() {}

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.scan, action: \.scan, child: ScanReducer.init)
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

            case .cellarTapped:
                state.cellar = CellarReducer.State()
                return .none

            case .cellar(.presented(.delegate(.requestScan))), .scanRequested:
                state.showScan = true
                return .none

            case .cellar:
                return .none

            case .scanDismissed:
                state.showScan = false
                // Refresh the cellar so a just-scanned bottle appears.
                return .send(.cellar(.presented(.task)))

            case .scan:
                return .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$detail, action: \.detail) {
            ListDetailReducer()
        }
        .ifLet(\.$cellar, action: \.cellar) {
            CellarReducer()
        }
    }
}

public struct ListsView: View {
    @Bindable var store: StoreOf<ListsReducer>

    public init(store: StoreOf<ListsReducer>) {
        self.store = store
    }

    public var body: some View {
        List {
            // Pinned collection: the wine cellar lives here as a specialized "list".
            Section {
                Button {
                    store.send(.cellarTapped)
                } label: {
                    HStack {
                        Label {
                            Text("Cellar").foregroundStyle(Color.ink)
                        } icon: {
                            Image(systemName: "wineglass").foregroundStyle(Color.wine)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("cellar-row")
                .listRowBackground(Color.familySurface)
            }

            Section("Lists") {
                if store.lists.isEmpty {
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Text("No lists yet. Groceries, Costco, house projects — tap + and share the load.")
                            .foregroundStyle(.secondary)
                    }
                } else {
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
            }
            .listRowBackground(Color.familySurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
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
        .navigationDestination(
            item: $store.scope(state: \.cellar, action: \.cellar)
        ) { cellarStore in
            // The seam: the wine stack keeps its parchment + wine "Cellar & Candlelight" chrome.
            // Stepping from the cream Lists screen into the Cellar is meant to feel like walking
            // into a wine cellar.
            CellarView(store: cellarStore)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { store.send(.scanRequested) } label: {
                            Image(systemName: "camera.viewfinder")
                        }
                        .accessibilityIdentifier("scan-wine-button")
                    }
                }
                .wineChrome()
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { store.showScan },
                set: { if !$0 { store.send(.scanDismissed) } }
            )
        ) {
            NavigationStack {
                ScanView(store: store.scope(state: \.scan, action: \.scan))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { store.send(.scanDismissed) }
                        }
                    }
            }
        }
        .alert("New list", isPresented: $store.showAddSheet) {
            TextField("Groceries, Costco, projects…", text: $store.newTitle)
            Button("Cancel", role: .cancel) { store.showAddSheet = false }
            Button("Create") { store.send(.createList) }
        }
    }
}
