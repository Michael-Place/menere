import AuthenticationDomain
import AuthenticationServices
import ComposableArchitecture
import FirebaseAuth
import Foundation
import MenereUI
import SwiftUI

@Reducer
public struct LoginReducer {
    @Dependency(\.firebaseAppleAuth.signIn) var signIn

    @ObservableState
    public struct State: Equatable {
        var phoneNumber = PhoneNumberLoginReducer.State()
        let nonce: NonceGenerator.Nonce
        let requestedScopes: [ASAuthorization.Scope] = [.email, .fullName]
        var isLoading: Bool = false

        public init() {
            @Dependency(\.nonceGenerator) var nonceGenerator
            self.nonce = nonceGenerator.nonce()
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case signInWithAppleTapped
        case authenticationDidChange(AuthenticationState)
        case didCompleteAuth(ASAuthorization)
        case authenticationSuccessful(String)
        case binding(BindingAction<State>)
        case phoneNumber(PhoneNumberLoginReducer.Action)
    }

    enum Cancel {
        case authenticationListener
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.phoneNumber, action: \.phoneNumber) {
            PhoneNumberLoginReducer()
        }
        Reduce { state, action in
            switch action {
            case .task:
                return .run { send in
                    @Dependency(\.authentication) var authentication
                    for await event in authentication.didChange() {
                        await send(.authenticationDidChange(event))
                    }
                }
                .cancellable(id: Cancel.authenticationListener, cancelInFlight: true)
            case .signInWithAppleTapped:
                return .none
            case .authenticationDidChange:
                return .none
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
            case .binding, .phoneNumber, .authenticationSuccessful:
                return .none
            }
        }
    }
}

public struct LoginView: View {
    @Bindable var store: StoreOf<LoginReducer>

    public init(store: StoreOf<LoginReducer>) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Welcome back")
                        .font(.title2.bold())

                    PhoneNumberLoginView(
                        store: store.scope(state: \.phoneNumber, action: \.phoneNumber)
                    )
                }

                AuthDivider()

                VStack(spacing: 16) {
                    SignInWithAppleButton { request in
                        store.send(.signInWithAppleTapped)
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
        .task { store.send(.task) }
        .navigationTitle("Sign In")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.familyCanvas.ignoresSafeArea())
    }
}

struct AuthDivider: View {
    var body: some View {
        HStack(spacing: 4) {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.secondary.opacity(0.3))
            Spacer()
            Text("or")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.secondary.opacity(0.3))
        }
    }
}
