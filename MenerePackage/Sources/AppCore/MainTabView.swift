import ComposableArchitecture
import HomeFeature
import SettingsFeature
import SwiftUI

@Reducer
public struct MainTabReducer {
    @ObservableState
    public struct State: Equatable {
        var selectedTab: TabItem = .home
        var home = HomeReducer.State()
        var settings = SettingsReducer.State()

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case home(HomeReducer.Action)
        case settings(SettingsReducer.Action)
        case tabSelected(TabItem)
        case binding(BindingAction<State>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Scope(state: \.home, action: \.home, child: HomeReducer.init)
        Scope(state: \.settings, action: \.settings, child: SettingsReducer.init)

        Reduce { state, action in
            switch action {
            case .tabSelected(let tab):
                state.selectedTab = tab
                return .none
            case .home, .settings, .binding:
                return .none
            }
        }
    }
}

public enum TabItem: Int, CaseIterable, Equatable {
    case home
    case settings

    var title: String {
        switch self {
        case .home: "Home"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .settings: "gearshape"
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
            Tab(TabItem.home.title, systemImage: TabItem.home.systemImage, value: TabItem.home) {
                NavigationStack {
                    HomeView(store: store.scope(state: \.home, action: \.home))
                }
            }

            Tab(TabItem.settings.title, systemImage: TabItem.settings.systemImage, value: TabItem.settings) {
                NavigationStack {
                    SettingsView(store: store.scope(state: \.settings, action: \.settings))
                }
            }
        }
    }
}
