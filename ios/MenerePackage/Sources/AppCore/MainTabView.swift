import AnalyticsClient
import AssistantFeature
import CalendarFeature
import ChoresFeature
import ComposableArchitecture
import DocsFeature
import ListsFeature
import MemoriesFeature
import MenereUI
import RecipesFeature
import SettingsFeature
import SwiftUI
import TodayFeature

@Reducer
public struct MainTabReducer {
    @ObservableState
    public struct State: Equatable {
        var selectedTab: TabItem = .today
        /// Family/profile is presented as a sheet from the tab-bar toolbar rather than a tab.
        var showSettings = false
        /// Family-Brain search is presented as a sheet from the shared toolbar on every tab.
        var showSearch = false
        /// The Bacán assistant chat, presented as a sheet from the Today tab's sparkles button.
        var showAssistant = false
        /// P28 — the full calendar is now a drill-in pushed from Today (Calendar is no longer a tab).
        /// Bound to a `navigationDestination` on the Today tab's stack; the `calendar` child stays alive
        /// so its EventKit two-way sync keeps running independently of the buried screen.
        var showFullCalendar = false
        var search = BrainSearchReducer.State()
        var assistant = AssistantReducer.State()
        var today = TodayReducer.State()
        var memories = MemoriesReducer.State()
        var lists = ListsReducer.State()
        var calendar = CalendarReducer.State()
        var chores = ChoresReducer.State()
        var recipes = RecipesReducer.State()
        var settings = SettingsReducer.State()

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case today(TodayReducer.Action)
        case memories(MemoriesReducer.Action)
        case lists(ListsReducer.Action)
        case calendar(CalendarReducer.Action)
        case chores(ChoresReducer.Action)
        case recipes(RecipesReducer.Action)
        case settings(SettingsReducer.Action)
        case search(BrainSearchReducer.Action)
        case assistant(AssistantReducer.Action)
        case tabSelected(TabItem)
        /// V5-Siri — an open-app App Intent (Log a Memory / Quick Capture) asked the app to land
        /// somewhere. Drained from `IntentRouter` by `MainTabView` on foreground.
        case openIntentDestination(IntentDestination)
        case binding(BindingAction<State>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Scope(state: \.today, action: \.today, child: TodayReducer.init)
        Scope(state: \.memories, action: \.memories, child: MemoriesReducer.init)
        Scope(state: \.lists, action: \.lists, child: ListsReducer.init)
        Scope(state: \.calendar, action: \.calendar, child: CalendarReducer.init)
        Scope(state: \.chores, action: \.chores, child: ChoresReducer.init)
        Scope(state: \.recipes, action: \.recipes, child: RecipesReducer.init)
        Scope(state: \.settings, action: \.settings, child: SettingsReducer.init)
        Scope(state: \.search, action: \.search, child: BrainSearchReducer.init)
        Scope(state: \.assistant, action: \.assistant, child: AssistantReducer.init)

        Reduce { state, action in
            @Dependency(\.analytics) var analytics   // P25 telemetry (fire-and-forget)
            switch action {
            case .tabSelected(let tab):
                state.selectedTab = tab
                analytics.log("tab_selected", ["tab": tab.eventName])
                // Re-selecting Today re-aggregates its cards (cheap one-shot fetches). `.today(.task)`
                // also drives the Apple-Calendar sync below (P28), so this covers tab reselection too.
                return tab == .today ? .send(.today(.task)) : .none

            // P28 — Calendar is no longer a tab, so keep EventKit two-way sync fresh by piggybacking on
            // every Today load/appear. `CalendarReducer.task` is internally guarded by the P2.2 trust
            // logic (setup complete + enabled + access granted), so this is a cheap no-op otherwise and
            // never fires a destructive reconcile without a live, granted EventKit session.
            case .today(.task):
                return .send(.calendar(.task))

            case .binding(\.showAssistant):
                if state.showAssistant { analytics.log("assistant_opened") }
                return .none

            case .binding(\.showSearch):
                if state.showSearch { analytics.log("search_opened") }
                return .none

            // P28 — "Open full calendar" pushes the full CalendarFeature as a drill-in on the Today
            // stack (Calendar is no longer a tab). The `calendar` child is already alive + synced.
            case .today(.delegate(.openCalendar)):
                state.showFullCalendar = true
                return .none
            case .today(.delegate(.openLists)):
                state.selectedTab = .lists
                return .none
            case .today(.delegate(.openKitchen)):
                state.selectedTab = .recipes
                // "Plan dinner" lands on Kitchen's Meal Plan segment (current week).
                return .send(.recipes(.showMealPlan))
            // P28-C2 — "Capture a moment" from Today jumps to the Memories tab and opens the editor.
            case .today(.delegate(.openMemories)):
                state.selectedTab = .memories
                return .send(.memories(.captureMomentTapped))

            // V5-Siri — route an open-app intent to its surface once the app is foregrounded.
            case .openIntentDestination(let destination):
                switch destination {
                case .logMemory:
                    state.selectedTab = .memories
                    analytics.log("intent_open", ["destination": "log_memory"])
                    return .send(.memories(.captureMomentTapped))
                case .capture:
                    state.showAssistant = true
                    analytics.log("intent_open", ["destination": "capture"])
                    return .none
                }

            case .search(.closeTapped):
                state.showSearch = false
                return .none

            case .assistant(.dismissTapped):
                state.showAssistant = false
                return .none

            case .today, .memories, .lists, .calendar, .chores, .recipes, .settings, .search, .assistant, .binding:
                return .none
            }
        }
    }
}

public enum TabItem: Int, CaseIterable, Equatable {
    case today
    case memories                      // P28: took the old Calendar slot (Calendar folded into Today).
    case lists
    case chores
    case recipes

    var title: String {
        switch self {
        case .today: "Today"
        case .memories: "Memories"
        case .lists: "Lists"
        case .chores: "Home"           // P8: the Chores tab became the Home care hub (enum case
                                       // kept `chores` to avoid churn — display-only rename).
        case .recipes: "Kitchen"
        }
    }

    /// Stable snake_case name for analytics (`chores` = the Home tab).
    var eventName: String {
        switch self {
        case .today: "today"
        case .memories: "memories"
        case .lists: "lists"
        case .chores: "home"
        case .recipes: "kitchen"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .memories: "book.closed"  // auto-fills to book.closed.fill when the tab is selected
        case .lists: "checklist"
        case .chores: "house"          // auto-fills to house.fill when the tab is selected
        case .recipes: "fork.knife"
        }
    }
}

public struct MainTabView: View {
    @Bindable var store: StoreOf<MainTabReducer>

    /// V5-Siri — drain any pending open-app-intent navigation when the app foregrounds.
    @Environment(\.scenePhase) private var scenePhase

    /// Motion & Delight — a monotonic entrance token per tab. It advances each time a tab becomes
    /// selected (and `.tabEntrance` fires once on cold-launch via its `initial:` reveal), so every
    /// tab replays its signature staggered load-in when navigated to. See ``TabEntrance``.
    @State private var entranceTokens: [TabItem: Int] = [:]

    public init(store: StoreOf<MainTabReducer>) {
        self.store = store
    }

    private func entranceToken(_ tab: TabItem) -> Int { entranceTokens[tab, default: 0] }

    public var body: some View {
        TabView(selection: $store.selectedTab.sending(\.tabSelected)) {
            Tab(TabItem.today.title, systemImage: TabItem.today.systemImage, value: TabItem.today) {
                NavigationStack {
                    TodayView(store: store.scope(state: \.today, action: \.today))
                        // P28 — the full calendar (month grid + agenda + recurrence + Apple sync) is now
                        // a drill-in pushed from Today's "Open full calendar" row.
                        .navigationDestination(isPresented: $store.showFullCalendar) {
                            CalendarView(store: store.scope(state: \.calendar, action: \.calendar))
                        }
                        .toolbar {
                            familyToolbar
                            // Bacán assistant — Today only, alongside the shared search/family icons.
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { store.showAssistant = true } label: {
                                    Image(systemName: "sparkles")
                                }
                                .accessibilityLabel("Ask Bacán")
                                .accessibilityIdentifier("assistant-button")
                            }
                        }
                }
                .tabEntranceTrigger(entranceToken(.today))
            }

            Tab(TabItem.memories.title, systemImage: TabItem.memories.systemImage, value: TabItem.memories) {
                NavigationStack {
                    MemoriesView(store: store.scope(state: \.memories, action: \.memories))
                        .toolbar { familyToolbar }
                }
                .tabEntranceTrigger(entranceToken(.memories))
            }

            Tab(TabItem.lists.title, systemImage: TabItem.lists.systemImage, value: TabItem.lists) {
                NavigationStack {
                    ListsView(store: store.scope(state: \.lists, action: \.lists))
                        .toolbar { familyToolbar }
                }
                .tabEntranceTrigger(entranceToken(.lists))
            }

            Tab(TabItem.chores.title, systemImage: TabItem.chores.systemImage, value: TabItem.chores) {
                NavigationStack {
                    ChoresView(store: store.scope(state: \.chores, action: \.chores))
                        .toolbar { familyToolbar }
                }
                .tabEntranceTrigger(entranceToken(.chores))
            }

            Tab(TabItem.recipes.title, systemImage: TabItem.recipes.systemImage, value: TabItem.recipes) {
                NavigationStack {
                    RecipesView(store: store.scope(state: \.recipes, action: \.recipes))
                        .toolbar { familyToolbar }
                }
                .tabEntranceTrigger(entranceToken(.recipes))
            }
        }
        // Motion & Delight — replay the newly-selected tab's signature entrance on each switch.
        // (Cold launch is covered by `.tabEntrance`'s own `initial:` reveal for the default tab.)
        .onChange(of: store.selectedTab) { _, tab in
            entranceTokens[tab, default: 0] += 1
        }
        .tint(.bacanGreen)
        .selectionHaptic(store.selectedTab)
        .sheet(isPresented: $store.showSettings) {
            NavigationStack {
                SettingsView(store: store.scope(state: \.settings, action: \.settings))
            }
            // Sheets don't inherit the TabView tint — re-apply the family accent explicitly.
            .tint(.bacanGreen)
        }
        .sheet(isPresented: $store.showSearch) {
            // BrainSearchView owns its own NavigationStack (results push the document detail).
            BrainSearchView(store: store.scope(state: \.search, action: \.search))
        }
        .sheet(isPresented: $store.showAssistant) {
            // AssistantView owns its own NavigationStack (sparkles header + Done).
            AssistantView(store: store.scope(state: \.assistant, action: \.assistant))
        }
        // V5-Siri — an open-app App Intent (Log a Memory / Quick Capture) parks its destination in
        // `IntentRouter`; drain it on first appearance and on every foreground so the app lands there.
        .onAppear { consumePendingIntent() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { consumePendingIntent() }
        }
    }

    /// Read-and-clear any pending open-app-intent destination and route to it (exactly once).
    private func consumePendingIntent() {
        if let destination = IntentRouter.shared.consume() {
            store.send(.openIntentDestination(destination))
        }
    }

    /// Persistent "Family" entry point, shown top-leading on every primary tab. Opens the
    /// member roster / My Profile editor as a sheet instead of consuming a tab-bar slot.
    @ToolbarContentBuilder
    private var familyToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { store.showSettings = true } label: {
                Image(systemName: "person.crop.circle")
            }
            .accessibilityLabel("Family")
            .accessibilityIdentifier("family-button")
        }
        // Family-Brain search — present on every tab, coexisting with each tab's own trailing "+".
        ToolbarItem(placement: .topBarTrailing) {
            Button { store.showSearch = true } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search the family brain")
            .accessibilityIdentifier("brain-search-button")
        }
    }
}
