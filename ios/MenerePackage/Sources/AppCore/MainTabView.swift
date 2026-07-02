import CalendarFeature
import ChoresFeature
import ComposableArchitecture
import ListsFeature
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
        var today = TodayReducer.State()
        var lists = ListsReducer.State()
        var calendar = CalendarReducer.State()
        var chores = ChoresReducer.State()
        var recipes = RecipesReducer.State()
        var settings = SettingsReducer.State()

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case today(TodayReducer.Action)
        case lists(ListsReducer.Action)
        case calendar(CalendarReducer.Action)
        case chores(ChoresReducer.Action)
        case recipes(RecipesReducer.Action)
        case settings(SettingsReducer.Action)
        case tabSelected(TabItem)
        case binding(BindingAction<State>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Scope(state: \.today, action: \.today, child: TodayReducer.init)
        Scope(state: \.lists, action: \.lists, child: ListsReducer.init)
        Scope(state: \.calendar, action: \.calendar, child: CalendarReducer.init)
        Scope(state: \.chores, action: \.chores, child: ChoresReducer.init)
        Scope(state: \.recipes, action: \.recipes, child: RecipesReducer.init)
        Scope(state: \.settings, action: \.settings, child: SettingsReducer.init)

        Reduce { state, action in
            switch action {
            case .tabSelected(let tab):
                state.selectedTab = tab
                // Re-selecting Today re-aggregates its cards (cheap one-shot fetches).
                return tab == .today ? .send(.today(.task)) : .none

            // Today quick-action deep links → switch to the target tab.
            case .today(.delegate(.openCalendar)):
                state.selectedTab = .calendar
                return .none
            case .today(.delegate(.openLists)):
                state.selectedTab = .lists
                return .none
            case .today(.delegate(.openKitchen)):
                state.selectedTab = .recipes
                // "Plan dinner" lands on Kitchen's Meal Plan segment (current week).
                return .send(.recipes(.showMealPlan))

            case .today, .lists, .calendar, .chores, .recipes, .settings, .binding:
                return .none
            }
        }
    }
}

public enum TabItem: Int, CaseIterable, Equatable {
    case today
    case calendar
    case lists
    case chores
    case recipes

    var title: String {
        switch self {
        case .today: "Today"
        case .calendar: "Calendar"
        case .lists: "Lists"
        case .chores: "Chores"
        case .recipes: "Kitchen"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .calendar: "calendar"
        case .lists: "checklist"
        case .chores: "checkmark.seal"
        case .recipes: "fork.knife"
        }
    }
}

public struct MainTabView: View {
    @Bindable var store: StoreOf<MainTabReducer>

    public init(store: StoreOf<MainTabReducer>) {
        self.store = store
    }

    public var body: some View {
        TabView(selection: $store.selectedTab.sending(\.tabSelected)) {
            Tab(TabItem.today.title, systemImage: TabItem.today.systemImage, value: TabItem.today) {
                NavigationStack {
                    TodayView(store: store.scope(state: \.today, action: \.today))
                        .toolbar { familyToolbar }
                }
            }

            Tab(TabItem.calendar.title, systemImage: TabItem.calendar.systemImage, value: TabItem.calendar) {
                NavigationStack {
                    CalendarView(store: store.scope(state: \.calendar, action: \.calendar))
                        .toolbar { familyToolbar }
                }
            }

            Tab(TabItem.lists.title, systemImage: TabItem.lists.systemImage, value: TabItem.lists) {
                NavigationStack {
                    ListsView(store: store.scope(state: \.lists, action: \.lists))
                        .toolbar { familyToolbar }
                }
            }

            Tab(TabItem.chores.title, systemImage: TabItem.chores.systemImage, value: TabItem.chores) {
                NavigationStack {
                    ChoresView(store: store.scope(state: \.chores, action: \.chores))
                        .toolbar { familyToolbar }
                }
            }

            Tab(TabItem.recipes.title, systemImage: TabItem.recipes.systemImage, value: TabItem.recipes) {
                NavigationStack {
                    RecipesView(store: store.scope(state: \.recipes, action: \.recipes))
                        .toolbar { familyToolbar }
                }
            }
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
    }
}
