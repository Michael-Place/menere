import CalendarFeature
import CellarFeature
import ChoresFeature
import ComposableArchitecture
import ListsFeature
import MenereUI
import RecipesFeature
import ScanFeature
import SettingsFeature
import SwiftUI
import WineDomain

@Reducer
public struct MainTabReducer {
    @ObservableState
    public struct State: Equatable {
        var selectedTab: TabItem = .calendar
        /// Scan is presented modally over the Wine tab rather than living in its own tab.
        var showScan = false
        var scan = ScanReducer.State()
        var cellar = CellarReducer.State()
        var lists = ListsReducer.State()
        var calendar = CalendarReducer.State()
        var chores = ChoresReducer.State()
        var recipes = RecipesReducer.State()
        var settings = SettingsReducer.State()

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case scan(ScanReducer.Action)
        case cellar(CellarReducer.Action)
        case lists(ListsReducer.Action)
        case calendar(CalendarReducer.Action)
        case chores(ChoresReducer.Action)
        case recipes(RecipesReducer.Action)
        case settings(SettingsReducer.Action)
        case tabSelected(TabItem)
        case scanRequested
        case scanDismissed
        case binding(BindingAction<State>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Scope(state: \.scan, action: \.scan, child: ScanReducer.init)
        Scope(state: \.cellar, action: \.cellar, child: CellarReducer.init)
        Scope(state: \.lists, action: \.lists, child: ListsReducer.init)
        Scope(state: \.calendar, action: \.calendar, child: CalendarReducer.init)
        Scope(state: \.chores, action: \.chores, child: ChoresReducer.init)
        Scope(state: \.recipes, action: \.recipes, child: RecipesReducer.init)
        Scope(state: \.settings, action: \.settings, child: SettingsReducer.init)

        Reduce { state, action in
            switch action {
            case .tabSelected(let tab):
                state.selectedTab = tab
                return .none
            case .scanRequested, .cellar(.delegate(.requestScan)):
                state.showScan = true
                return .none
            case .scanDismissed:
                state.showScan = false
                // Refresh the cellar so a just-scanned bottle appears.
                return .send(.cellar(.task))
            case .scan, .cellar, .lists, .calendar, .chores, .recipes, .settings, .binding:
                return .none
            }
        }
    }
}

public enum TabItem: Int, CaseIterable, Equatable {
    case calendar
    case lists
    case chores
    case settings
    case recipes
    case wine

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .lists: "Lists"
        case .chores: "Chores"
        case .settings: "Family"
        case .recipes: "Kitchen"
        case .wine: "Wine"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .lists: "checklist"
        case .chores: "checkmark.seal"
        case .settings: "person.2"
        case .recipes: "fork.knife"
        case .wine: "wineglass"
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
            Tab(TabItem.calendar.title, systemImage: TabItem.calendar.systemImage, value: TabItem.calendar) {
                NavigationStack {
                    CalendarView(store: store.scope(state: \.calendar, action: \.calendar))
                }
            }

            Tab(TabItem.lists.title, systemImage: TabItem.lists.systemImage, value: TabItem.lists) {
                NavigationStack {
                    ListsView(store: store.scope(state: \.lists, action: \.lists))
                }
            }

            Tab(TabItem.chores.title, systemImage: TabItem.chores.systemImage, value: TabItem.chores) {
                NavigationStack {
                    ChoresView(store: store.scope(state: \.chores, action: \.chores))
                }
            }

            Tab(TabItem.settings.title, systemImage: TabItem.settings.systemImage, value: TabItem.settings) {
                NavigationStack {
                    SettingsView(store: store.scope(state: \.settings, action: \.settings))
                }
            }

            Tab(TabItem.recipes.title, systemImage: TabItem.recipes.systemImage, value: TabItem.recipes) {
                NavigationStack {
                    RecipesView(store: store.scope(state: \.recipes, action: \.recipes))
                }
            }

            Tab(TabItem.wine.title, systemImage: TabItem.wine.systemImage, value: TabItem.wine) {
                WineTabView(store: store)
            }
        }
        .tint(.wine)
        .selectionHaptic(store.selectedTab)
    }
}

/// The consolidated Wine tab: the Cellar is home, and Scan is presented as a full-screen modal
/// (camera toolbar button, or the Cellar empty-state "Scan a wine" delegate). Keeps all of the
/// original single-purpose Menere UI behind one tab.
struct WineTabView: View {
    @Bindable var store: StoreOf<MainTabReducer>

    var body: some View {
        NavigationStack {
            CellarView(store: store.scope(state: \.cellar, action: \.cellar))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { store.send(.scanRequested) } label: {
                            Image(systemName: "camera.viewfinder")
                        }
                        .accessibilityIdentifier("scan-wine-button")
                    }
                }
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
    }
}
