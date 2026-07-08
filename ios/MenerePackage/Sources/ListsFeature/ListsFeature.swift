import AnalyticsClient
import CellarFeature
import ComposableArchitecture
import DocsFeature
import FamilyDomain
import LocalCache
import MenereUI
import MoneyFeature
import PersistenceClient
import ProjectsFeature
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

        // Projects (family initiative workspaces) is the fourth pinned row; pushing it presents the
        // ProjectsFeature list. State lives here, mirroring the Cellar / Docs / Money wiring.
        @Presents var projects: ProjectsReducer.State?

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case task
        /// `lists == nil` means the Firestore read FAILED (offline) — keep the cache-painted lists and
        /// skip the write-through. A non-nil (even empty) result is authoritative.
        case listsLoaded([FamilyList]?)
        case listsCacheHydrated([FamilyList])   // H2-ext — instant/reactive paint from the SQLite mirror
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
        case projectsTapped
        case projects(PresentationAction<ProjectsReducer.Action>)
        case scan(ScanReducer.Action)
        case scanRequested
        case scanDismissed
        case binding(BindingAction<State>)
    }

    public init() {}

    private enum CancelID { case observeListsCache }

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
                // H2-ext — OFFLINE-FIRST INSTANT PAINT: seed the list rows from the SQLite mirror THIS
                // FRAME (no await), keep them live via the observation stream, and refresh + write through
                // from the one-shot Firestore read below. Guarded so fresh in-memory data isn't clobbered.
                @Dependency(\.localCache) var localCache
                localCache.bootstrap()
                if state.lists.isEmpty {
                    let cached = localCache.lists(hid)
                    if !cached.isEmpty { state.lists = cached.sorted { $0.createdAt < $1.createdAt } }
                }
                return .merge(
                    .run { send in
                        @Dependency(\.localCache) var localCache
                        for await lists in localCache.observeLists(hid) {
                            await send(.listsCacheHydrated(lists))
                        }
                    }
                    .cancellable(id: CancelID.observeListsCache, cancelInFlight: true),
                    .run { send in
                        @Dependency(\.persistence) var persistence
                        // nil = the Firestore read FAILED (offline): keep the cache, skip write-through.
                        async let lists = try? await persistence.lists(hid)
                        async let members = persistence.members(hid)
                        await send(.listsLoaded(await lists))
                        await send(.membersLoaded((try? await members) ?? []))
                    }
                )

            case let .listsCacheHydrated(lists):
                // H2-ext — instant/reactive paint from the SQLite mirror (oldest-first, matching the
                // screen's order). Idempotent after the Firestore write-through re-emits the same rows.
                state.lists = lists.sorted { $0.createdAt < $1.createdAt }
                return .none

            case let .listsLoaded(lists):
                state.isLoading = false
                // H2-ext — Firestore is authoritative only when it answered (lists != nil). When nil
                // (offline) the observation stream keeps driving the cache-painted rows.
                guard let lists else { return .none }
                state.lists = lists.sorted { $0.createdAt < $1.createdAt }
                guard let hid = hid() else { return .none }
                return .run { [lists] _ in
                    @Dependency(\.localCache) var localCache
                    localCache.upsertLists(hid, lists)
                }

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
                case .project:
                    list = FamilyList(title: title, icon: "hammer.fill", color: .marigold, listType: .project)
                case .wishlist:
                    list = FamilyList(title: title, icon: "star.fill", color: .sky, listType: .wishlist)
                case .standard:
                    list = FamilyList(title: title)
                }
                @Dependency(\.analytics) var analytics
                switch state.newListType {
                case .packing: analytics.log("packing_list_created")
                case .gift: analytics.log("gift_list_created")
                case .project: analytics.log("project_list_created")
                case .wishlist: analytics.log("wishlist_created")
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

            case .projectsTapped:
                @Dependency(\.analytics) var analytics
                analytics.log("projects_opened")
                state.projects = ProjectsReducer.State()
                return .none

            case .projects:
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
        .ifLet(\.$projects, action: \.projects) {
            ProjectsReducer()
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
                            Image(systemName: "wineglass").foregroundStyle(Color.terracotta)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("cellar-row")
                // Motion & Delight — Lists' signature: rows SLIDE in from the leading edge, staggered,
                // like a checklist writing itself. Replays on every (re)selection.
                .tabEntrance(.slideLeading, index: 0)

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
                .tabEntrance(.slideLeading, index: 1)

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
                .tabEntrance(.slideLeading, index: 2)

                // Sibling pinned row: Projects — family initiative workspaces.
                Button {
                    store.send(.projectsTapped)
                } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Projects").foregroundStyle(Color.ink)
                                Text("Pool, school & big undertakings")
                                    .font(.caption)
                                    .foregroundStyle(Color.inkSoft)
                            }
                        } icon: {
                            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.marigold)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("projects-row")
                .tabEntrance(.slideLeading, index: 3)
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
                    ForEach(Array(store.lists.enumerated()), id: \.element.id) { index, list in
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
                        .tabEntrance(.slideLeading, index: 4 + index)
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
            // The wine stack now shares the Bacán family chrome via `.wineChrome()` (familyCanvas +
            // bacanGreen), so the Cellar reads as the same app as the rest of Lists rather than a
            // separate parchment world.
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
        .navigationDestination(
            item: $store.scope(state: \.projects, action: \.projects)
        ) { projectsStore in
            ProjectsView(store: projectsStore)
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
            // The Scan modal is part of the wine stack: pin the family tint so the "Done" button
            // (added here, outside ScanView's own `.wineChrome()` tint scope) matches bacanGreen.
            .tint(.bacanGreen)
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
        case .project: "Home projects"
        case .wishlist: "Wishlist"
        }
    }

    /// The set of all preset default titles — used to know when a title is still "untouched".
    private let presetTitles: Set<String> = ["Groceries", "Packing list", "Gift ideas", "Home projects", "Wishlist"]

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
                        Label("Home Projects", systemImage: "hammer.fill").tag(ListType.project)
                        Label("Wishlist", systemImage: "star.fill").tag(ListType.wishlist)
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
                    case .project:
                        presetHint("Honey-do & home projects: status (planning → in-progress → done), budget, notes, and linked Brain docs — grouped by status.")
                    case .wishlist:
                        presetHint("Non-grocery wants: price, store, priority, and a link — with a bought toggle and running totals.")
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
