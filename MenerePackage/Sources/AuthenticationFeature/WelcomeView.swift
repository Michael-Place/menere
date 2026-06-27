import ComposableArchitecture
import SwiftUI

@Reducer
public struct WelcomeReducer {
    @ObservableState
    public struct State: Equatable {
        @Presents var destination: Destination.State?

        public init() {}
    }

    public enum Action: Equatable {
        case getStartedTapped
        case logInTapped
        case destination(PresentationAction<Destination.Action>)
    }

    public init() {}

    @Reducer(state: .equatable, action: .equatable)
    public enum Destination {
        case login(LoginReducer)
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .getStartedTapped:
                return .none
            case .logInTapped:
                state.destination = .login(.init())
                return .none
            case .destination:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }
}

public struct WelcomeView: View {
    @Bindable public var store: StoreOf<WelcomeReducer>

    public init(store: StoreOf<WelcomeReducer>) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [.blue.opacity(0.8), .purple.opacity(0.6), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 32) {
                    Image(systemName: "app.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.white.opacity(0.9))

                    VStack(spacing: 16) {
                        Text("Menere")
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Your tagline here")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }
                }

                Spacer()

                VStack(spacing: 16) {
                    Button(action: { store.send(.getStartedTapped) }) {
                        VStack(spacing: 4) {
                            Text("Get Started")
                                .font(.headline)
                            Text("Create your free account")
                                .font(.caption)
                                .opacity(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(action: { store.send(.logInTapped) }) {
                        Text("Already have an account? Sign In")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 48)
                .padding(.horizontal, 24)
            }
        }
        .navigationDestination(
            item: $store.scope(state: \.destination?.login, action: \.destination.login)
        ) { store in
            LoginView(store: store)
        }
    }
}

#Preview {
    NavigationStack {
        WelcomeView(
            store: Store(initialState: WelcomeReducer.State()) {
                WelcomeReducer()
            }
        )
    }
}
