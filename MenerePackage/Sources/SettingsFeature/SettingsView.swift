import AuthenticationDomain
import ComposableArchitecture
import SwiftUI
import UserDomain

@Reducer
public struct SettingsReducer {
    @ObservableState
    public struct State: Equatable {
        var showSignOutConfirmation = false

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case signOutTapped
        case confirmSignOut
        case cancelSignOut
        case binding(BindingAction<State>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .signOutTapped:
                state.showSignOutConfirmation = true
                return .none
            case .confirmSignOut:
                state.showSignOutConfirmation = false
                return .run { _ in
                    @Dependency(\.authentication) var authentication
                    try authentication.signOut()
                }
            case .cancelSignOut:
                state.showSignOutConfirmation = false
                return .none
            case .binding:
                return .none
            }
        }
    }
}

public struct SettingsView: View {
    @Bindable var store: StoreOf<SettingsReducer>

    public init(store: StoreOf<SettingsReducer>) {
        self.store = store
    }

    public var body: some View {
        List {
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    store.send(.signOutTapped)
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Sign Out")
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .alert("Sign Out", isPresented: $store.showSignOutConfirmation) {
            Button("Cancel", role: .cancel) { store.send(.cancelSignOut) }
            Button("Sign Out", role: .destructive) { store.send(.confirmSignOut) }
        } message: {
            Text("Are you sure you want to sign out?")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
