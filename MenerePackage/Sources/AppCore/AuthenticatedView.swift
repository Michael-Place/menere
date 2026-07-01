import ComposableArchitecture
import PersistenceClient
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
                return .run { _ in
                    @Shared(.user) var user
                    guard let uid = user?.id else { return }
                    let displayName = user?.displayName ?? ""
                    @Dependency(\.persistence) var persistence
                    do {
                        let hid = try await persistence.ensureHousehold(uid)
                        $user.withLock { $0?.householdId = hid }
                        // Seed this user's family member profile (idempotent).
                        _ = try await persistence.ensureMember(hid, uid, displayName)
                    } catch {}   // non-fatal; features guard nil householdId
                }
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
