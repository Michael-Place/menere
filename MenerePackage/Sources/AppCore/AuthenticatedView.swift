import ComposableArchitecture
import Sharing
import SwiftUI
import UserDomain

@Reducer
public struct AuthenticatedReducer {
    @ObservableState
    public struct State: Equatable {
        public let user: UserDomain.User
        var mainTab = MainTabReducer.State()

        public init(user: UserDomain.User) {
            @Shared(.user) var sharedUser
            $sharedUser.withLock { $0 = user }
            self.user = user
        }
    }

    public enum Action: Equatable {
        case task
        case mainTab(MainTabReducer.Action)
    }

    public var body: some ReducerOf<Self> {
        Scope(state: \.mainTab, action: \.mainTab) {
            MainTabReducer()
        }

        Reduce { state, action in
            switch action {
            case .task:
                return .none
            case .mainTab:
                return .none
            }
        }
    }
}

public struct AuthenticatedView: View {
    let store: StoreOf<AuthenticatedReducer>

    public init(store: StoreOf<AuthenticatedReducer>) {
        self.store = store
    }

    public var body: some View {
        MainTabView(store: store.scope(state: \.mainTab, action: \.mainTab))
            .task { store.send(.task) }
    }
}
