import AuthenticationDomain
import AuthenticationServices
import ComposableArchitecture
import SwiftUI

@Reducer
public struct CreateAccountReducer {
    @Dependency(\.firebaseAppleAuth.signIn) var signIn

    @ObservableState
    public struct State: Equatable {
        var phoneNumber = PhoneNumberLoginReducer.State(
            authenticationMode: .createAccount
        )
        let nonce: NonceGenerator.Nonce
        let requestedScopes: [ASAuthorization.Scope] = [.email, .fullName]

        public init() {
            @Dependency(\.nonceGenerator) var nonceGenerator
            self.nonce = nonceGenerator.nonce()
        }
    }

    public enum Action: Equatable, BindableAction {
        case didCompleteAuth(ASAuthorization)
        case authenticationSuccessful(String)
        case binding(BindingAction<State>)
        case phoneNumber(PhoneNumberLoginReducer.Action)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.phoneNumber, action: \.phoneNumber) {
            PhoneNumberLoginReducer()
        }
        Reduce { state, action in
            switch action {
            case let .didCompleteAuth(success):
                return .run { [nonce = state.nonce.raw] send in
                    do {
                        let response = try await signIn(success, nonce)
                        await send(.authenticationSuccessful(response.user.uid))
                    } catch {
                        print("Apple sign-in failed: \(error.localizedDescription)")
                    }
                }
            case .phoneNumber(.destination(.presented(.otpVerification(.otpCodeEntryCompleted(let userId))))):
                return .send(.authenticationSuccessful(userId))
            case .authenticationSuccessful:
                return .none
            case .binding, .phoneNumber:
                return .none
            }
        }
    }
}

public struct CreateAccountView: View {
    @Bindable var store: StoreOf<CreateAccountReducer>

    public init(store: StoreOf<CreateAccountReducer>) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Create Your Account")
                        .font(.title2.bold())

                    PhoneNumberLoginView(
                        store: store.scope(state: \.phoneNumber, action: \.phoneNumber)
                    )
                }

                AuthDivider()

                VStack(spacing: 16) {
                    SignInWithAppleButton(.continue) { request in
                        request.nonce = store.nonce.encrypted
                        request.requestedScopes = store.requestedScopes
                    } onCompletion: { result in
                        if case let .success(success) = result {
                            store.send(.didCompleteAuth(success))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }

                Spacer()
            }
            .padding(.top, 30)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
