import CellarFeature
import ComposableArchitecture
import HomeFeature
import ScanFeature
import SettingsFeature
import SwiftUI
import WineDomain

@Reducer
public struct MainTabReducer {
    @ObservableState
    public struct State: Equatable {
        var selectedTab: TabItem = .home
        var home = HomeReducer.State()
        var scan = ScanReducer.State()
        var cellar = CellarReducer.State()
        var settings = SettingsReducer.State()

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case home(HomeReducer.Action)
        case scan(ScanReducer.Action)
        case cellar(CellarReducer.Action)
        case settings(SettingsReducer.Action)
        case tabSelected(TabItem)
        case binding(BindingAction<State>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        Scope(state: \.home, action: \.home, child: HomeReducer.init)
        Scope(state: \.scan, action: \.scan, child: ScanReducer.init)
        Scope(state: \.cellar, action: \.cellar, child: CellarReducer.init)
        Scope(state: \.settings, action: \.settings, child: SettingsReducer.init)

        Reduce { state, action in
            switch action {
            case .tabSelected(let tab):
                state.selectedTab = tab
                return .none
            case .home(.delegate(.requestScan)), .cellar(.delegate(.requestScan)):
                state.selectedTab = .scan
                return .none
            case let .home(.delegate(.openCellar(target))):
                state.selectedTab = .cellar
                let (segment, statusFilter) = Self.preset(for: target)
                return .send(.cellar(.applyPreset(segment: segment, statusFilter: statusFilter)))
            case .home, .scan, .cellar, .settings, .binding:
                return .none
            }
        }
    }

    static func preset(for target: HomeReducer.StatTarget) -> (segment: CellarReducer.State.Segment, statusFilter: BottleStatus?) {
        switch target {
        case .cellared: (.cellar, .cellared)
        case .wines:    (.cellar, nil)
        case .tastings: (.history, nil)
        case .wishlist: (.cellar, .wishlist)
        }
    }
}

public enum TabItem: Int, CaseIterable, Equatable {
    case home
    case scan
    case cellar
    case settings

    var title: String {
        switch self {
        case .home: "Home"
        case .scan: "Scan"
        case .cellar: "Cellar"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .scan: "camera.viewfinder"
        case .cellar: "square.stack.3d.up"
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

            Tab(TabItem.scan.title, systemImage: TabItem.scan.systemImage, value: TabItem.scan) {
                NavigationStack {
                    ScanView(store: store.scope(state: \.scan, action: \.scan))
                }
            }

            Tab(TabItem.cellar.title, systemImage: TabItem.cellar.systemImage, value: TabItem.cellar) {
                NavigationStack {
                    CellarView(store: store.scope(state: \.cellar, action: \.cellar))
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
