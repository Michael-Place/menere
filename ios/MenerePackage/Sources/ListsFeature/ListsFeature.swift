import AnalyticsClient
import CellarFeature
import ComposableArchitecture
import DocsFeature
import FamilyDomain
import MenereUI
import MoneyFeature
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
        /// Which specialization the about-to-be-created list should take (P30 grocery preset).
        var newListType: ListType = .standard
        @Presents var detail: ListDetailReducer.State?

        // Wine cellar is re-homed here as a pinned "collection" entry. Pushing the Cellar
        // presents the full wine stack; Scan is a full-screen modal over it (as before).
        @Presents var cellar: CellarReducer.State?
        var showScan = false
        var scan = ScanReducer.State()

        // Family Brain (document vault) is a sibling pinned row under Cellar; pushing it presents
        // the DocsFeature library. State lives here, mirroring the Cellar wiring.
        @Presents var docs: DocsReducer.State?

        // Money (expenses & budgets) is the third pinned row, under Family Brain; pushing it presents
        // the MoneyFeature screen. State lives here, mirroring the Cellar / Docs wiring.
        @Presents var money: MoneyReducer.State?

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
        case docsTapped
        case docs(PresentationAction<DocsReducer.Action>)
        case moneyTapped
        case money(PresentationAction<MoneyReducer.Action>)
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
                state.newListType = .standard
                state.showAddSheet = true
                return .none

            case .createList:
                let title = state.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let hid = hid() else { return .none }
                // Each preset flips the list into its specialized detail experience + a fitting icon.
                let list: FamilyList
                switch state.newListType {
                case .grocery:
                    list = FamilyList(title: title, icon: "cart", color: .sage, listType: .grocery)
                case .packing:
                    list = FamilyList(title: title, icon: "suitcase", color: .sky, listType: .packing)
                case .gift:
                    list = FamilyList(title: title, icon: "gift", color: .terracotta, listType: .gift)
                case .standard:
                    list = FamilyList(title: title)
                }
                @Dependency(\.analytics) var analytics
                switch state.newListType {
                case .packing: analytics.log("packing_list_created")
                case .gift: analytics.log("gift_list_created")
                default: break
                }
                state.lists.append(list)
                state.showAddSheet = false
                state.newTitle = ""
                state.newListType = .standard
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

            case .docsTapped:
                @Dependency(\.analytics) var analytics
                analytics.log("family_brain_opened")   // P25 telemetry (fire-and-forget)
                state.docs = DocsReducer.State()
                return .none

            case .docs:
                return .none

            case .moneyTapped:
                state.money = MoneyReducer.State()
                return .none

            case .money:
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
        .ifLet(\.$docs, action: \.docs) {
            DocsReducer()
        }
        .ifLet(\.$money, action: \.money) {
            MoneyReducer()
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

                // Sibling pinned row: the Family Brain document vault.
                Button {
                    store.send(.docsTapped)
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Family Brain").foregroundStyle(Color.ink)
                                Text("Documents & paperwork")
                                    .font(.caption)
                                    .foregroundStyle(Color.inkSoft)
                            }
                        } icon: {
                            Image(systemName: "brain").foregroundStyle(Color.sky)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("docs-row")

                // Sibling pinned row: Money — expenses & budgets.
                Button {
                    store.send(.moneyTapped)
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Money").foregroundStyle(Color.ink)
                                Text("Spending & budgets")
                                    .font(.caption)
                                    .foregroundStyle(Color.inkSoft)
                            }
                        } icon: {
                            Image(systemName: "dollarsign.circle").foregroundStyle(Color.sage)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("money-row")
            }
            .listRowBackground(Color.familySurface)

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
                Button { store.send(.addTapped) } label: { Image(systemName: "plus").appearBounce() }
                    .buttonStyle(.pressable)
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
        .navigationDestination(
            item: $store.scope(state: \.docs, action: \.docs)
        ) { docsStore in
            DocsLibraryView(store: docsStore)
        }
        .navigationDestination(
            item: $store.scope(state: \.money, action: \.money)
        ) { moneyStore in
            MoneyView(store: moneyStore)
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
            // The Scan modal is part of the wine stack: pin the wine tint so the "Done" button (added
            // here, outside ScanView's own `.wineChrome()` tint scope) doesn't stay bacanGreen.
            .tint(.wine)
        }
        .sheet(isPresented: $store.showAddSheet) {
            NewListSheet(store: store)
                .presentationDetents([.medium])
        }
    }
}

/// The "New list" form. Offers a grocery preset (P30) that flips the new list into the
/// aisle-grouped grocery experience with a cart icon.
private struct NewListSheet: View {
    @Bindable var store: StoreOf<ListsReducer>

    /// The sensible default title we'd suggest for a given preset (empty for a plain checklist).
    private func defaultTitle(for type: ListType) -> String {
        switch type {
        case .standard: ""
        case .grocery: "Groceries"
        case .packing: "Packing list"
        case .gift: "Gift ideas"
        }
    }

    /// The set of all preset default titles — used to know when a title is still "untouched".
    private let presetTitles: Set<String> = ["Groceries", "Packing list", "Gift ideas"]

    @ViewBuilder
    private func presetHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.inkSoft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Groceries, Costco, projects…", text: $store.newTitle)
                        .accessibilityIdentifier("new-list-title-field")
                }
                .listRowBackground(Color.familySurface)

                Section("Type") {
                    Picker("List type", selection: $store.newListType) {
                        Label("Checklist", systemImage: "checklist").tag(ListType.standard)
                        Label("Grocery List", systemImage: "cart").tag(ListType.grocery)
                        Label("Packing List", systemImage: "suitcase").tag(ListType.packing)
                        Label("Gift List", systemImage: "gift").tag(ListType.gift)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    switch store.newListType {
                    case .grocery:
                        presetHint("We'll sort items by aisle and auto-tag categories as you type.")
                    case .packing:
                        presetHint("Group by person and category — and seed it from a beach / weekend / flight-with-baby template.")
                    case .gift:
                        presetHint("Track ideas per recipient with price, link, and a bought toggle — hidden from whoever it's for.")
                    case .standard:
                        EmptyView()
                    }
                }
                .listRowBackground(Color.familySurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .onChange(of: store.newListType) { _, newType in
                // Auto-suggest a title when the field is still empty or holding another preset's
                // default, so picking "Packing List" fills "Packing list" — but never clobber a
                // title the user actually typed.
                let current = store.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if current.isEmpty || presetTitles.contains(current) {
                    store.newTitle = defaultTitle(for: newType)
                }
            }
            .navigationTitle("New list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.showAddSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { store.send(.createList) }
                        .disabled(store.newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("create-list-button")
                }
            }
        }
    }
}
