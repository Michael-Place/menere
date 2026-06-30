import AuthenticationFeature
import ComposableArchitecture
import FirebaseFirestore
import MenereUI
import SwiftUI
import UserDomain

@Reducer
public struct OnboardingReducer {
    @ObservableState
    public struct State: Equatable {
        var displayName: String = ""
        var isLoading: Bool = false
        var errorMessage: String?
        var userId: String?
        var createAccount = CreateAccountReducer.State()

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case cancel
        case continueTapped
        case userOnboarded(UserDomain.User)
        case onboardingFailed(String)
        case createAccount(CreateAccountReducer.Action)
        case binding(BindingAction<State>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.createAccount, action: \.createAccount) {
            CreateAccountReducer()
        }
        Reduce { state, action in
            switch action {
            case .cancel:
                return .none
            case .continueTapped:
                guard let userId = state.userId else { return .none }
                state.isLoading = true
                let displayName = state.displayName.isEmpty ? "User" : state.displayName
                return .run { send in
                    do {
                        let user = User(id: userId, displayName: displayName)
                        try await user.save()
                        await send(.userOnboarded(user))
                    } catch {
                        await send(.onboardingFailed(error.localizedDescription))
                    }
                }
            case .userOnboarded:
                state.isLoading = false
                return .none
            case .onboardingFailed(let error):
                state.isLoading = false
                state.errorMessage = error
                return .none
            case .createAccount(.authenticationSuccessful(let userId)):
                state.userId = userId
                return .none
            case .createAccount, .binding:
                return .none
            }
        }
    }
}

public struct OnboardingView: View {
    @Bindable var store: StoreOf<OnboardingReducer>

    /// Bumped when the success ("You're Ready!") step appears so the check can bounce once on entry.
    @State private var readyAppeared = false

    public init(store: StoreOf<OnboardingReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            if store.userId == nil {
                CreateAccountView(
                    store: store.scope(state: \.createAccount, action: \.createAccount)
                )
                .navigationTitle("Create Account")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { store.send(.cancel) }
                    }
                }
            } else {
                profileSetupView
            }
        }
        // Fires once the moment onboarding reaches the ready step (userId becomes non-nil).
        .successHaptic(store.userId)
    }

    private var profileSetupView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(Color.drinkNow)
                .symbolEffect(.bounce, options: .nonRepeating, value: readyAppeared)
                .onAppear { readyAppeared = true }

            VStack(spacing: 12) {
                Text("You're Ready!")
                    .font(.largeTitle.bold())

                Text("Set up your profile to get started.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextField("Display Name", text: $store.displayName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 32)

            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(action: { store.send(.continueTapped) }) {
                if store.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .disabled(store.isLoading)

            Spacer()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { store.send(.cancel) }
            }
        }
    }
}
