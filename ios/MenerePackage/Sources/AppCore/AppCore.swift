import AnalyticsClient
import AuthenticationDomain
import AuthenticationFeature
import ComposableArchitecture
import MenereUI
import OnboardingFeature
import Sharing
import SwiftUI
import UserDomain

@Reducer
public struct AppReducer {
    @ObservableState
    public struct State: Equatable {
        var authentication: AuthenticationReducer.State?
        var isUsingCachedAuth: Bool = false

        public init() {
            @Dependency(\.authentication) var authentication

            let cachedState = authentication.cachedAuthState()

            switch cachedState {
            case .hasCachedUser(let user):
                self.authentication = .authenticated(AuthenticatedReducer.State(user: user))
                self.isUsingCachedAuth = true

            case .noSession:
                self.authentication = .unauthenticated(WelcomeReducer.State())
                self.isUsingCachedAuth = false

            case .hasFirebaseSession, .unknown:
                self.authentication = nil
                self.isUsingCachedAuth = false
            }
        }
    }

    public enum Action: Equatable {
        case task
        case scenePhaseChanged(ScenePhase)
        case authenticationDidChange(AuthenticationState)
        case authentication(AuthenticationReducer.Action)
    }

    public init() {}

    enum Cancel {
        case authenticationListener
    }

    public var body: some ReducerOf<AppReducer> {
        Reduce { state, action in
            switch action {
            case .scenePhaseChanged(let phase):
                // P25 telemetry: app came to the foreground (a "session"). No-ops until a household
                // is resolved. Fire-and-forget.
                if phase == .active {
                    @Dependency(\.analytics) var analytics
                    analytics.log("session_start")
                }
                return .none

            case .task:
                return .run { send in
                    @Dependency(\.authentication) var authentication
                    for await event in authentication.didChange() {
                        await send(.authenticationDidChange(event))
                    }
                }
                .cancellable(id: Cancel.authenticationListener, cancelInFlight: true)

            case let .authenticationDidChange(authState):
                switch (state.authentication, authState) {
                // Cached auth invalidated
                case (.authenticated, .unauthenticated) where state.isUsingCachedAuth:
                    state.authentication = .unauthenticated(.init())
                    state.isUsingCachedAuth = false
                    return .none

                // Cached auth confirmed - update user data silently if changed
                case (.authenticated(let currentState), .authenticated(let serverUser)) where state.isUsingCachedAuth:
                    state.isUsingCachedAuth = false
                    if currentState.user != serverUser {
                        state.authentication = .authenticated(AuthenticatedReducer.State(user: serverUser))
                    }
                    return .none

                // App launch unauthenticated
                case (nil, .unauthenticated):
                    state.authentication = .unauthenticated(.init())
                    state.isUsingCachedAuth = false
                    return .none

                // Log out
                case (.authenticated, .unauthenticated):
                    state.authentication = .unauthenticated(.init())
                    state.isUsingCachedAuth = false
                    return .none

                // App launch authenticated
                case (nil, .authenticated(let user)):
                    state.authentication = .authenticated(.init(user: user))
                    state.isUsingCachedAuth = false
                    return .none

                // Sign in from unauthenticated
                case (.unauthenticated, .authenticated(let user)):
                    state.authentication = .authenticated(.init(user: user))
                    state.isUsingCachedAuth = false
                    return .none

                // App launched into authenticating state - sign out
                case (nil, .authenticating):
                    do {
                        @Dependency(\.authentication) var authentication
                        try authentication.signOut()
                    } catch {}
                    state.authentication = .unauthenticated(.init())
                    state.isUsingCachedAuth = false
                    return .none

                default:
                    return .none
                }

            // Get Started → onboarding
            case .authentication(.unauthenticated(.getStartedTapped)):
                state.authentication = .authenticating(.init())
                return .none

            // Onboarding cancelled
            case .authentication(.authenticating(.cancel)):
                state.authentication = .unauthenticated(.init())
                return .none

            // Onboarding completed
            case .authentication(.authenticating(.userOnboarded(let user))):
                state.authentication = .authenticated(.init(user: user))
                return .none

            case .authentication:
                return .none
            }
        }
        .ifLet(\.authentication, action: \.authentication) {
            AuthenticationReducer.body
        }
    }
}

// MARK: - AppView

public struct AppView: View {
    @Bindable var store: StoreOf<AppReducer>

    public init(store: StoreOf<AppReducer>) {
        self.store = store
        // Apply the family brand chrome (cream nav bar, rounded ink titles) once at launch so no
        // default white nav/status-bar seam shows above the canvas on any screen. The wine stack
        // pins its parchment chrome back per-screen.
        MenereAppearance.apply()
    }

    public var body: some View {
        if let store = store.scope(state: \.authentication, action: \.authentication) {
            ZStack {
                switch store.case {
                case .unauthenticated(let store):
                    NavigationStack {
                        WelcomeView(store: store)
                            .toolbarVisibility(.hidden, for: .navigationBar)
                    }
                    .transition(.opacity)
                case .authenticated(let store):
                    AuthenticatedView(store: store)
                        .transition(.opacity)
                case .authenticating(let store):
                    OnboardingView(store: store)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: store.state)
        } else {
            ZStack {
                Color.familyCanvas
                    .ignoresSafeArea()
                ProgressView()
                    .controlSize(.large)
                    .tint(.bacanGreen)
            }
        }
    }
}

// MARK: - AuthenticationReducer

@Reducer(state: .equatable, action: .equatable)
public enum AuthenticationReducer {
    case authenticated(AuthenticatedReducer)
    case unauthenticated(WelcomeReducer)
    case authenticating(OnboardingReducer)
}
