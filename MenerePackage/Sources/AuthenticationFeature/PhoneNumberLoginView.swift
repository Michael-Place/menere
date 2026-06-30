import AuthenticationDomain
import ComposableArchitecture
import FirebaseAuth
import MenereUI
import SwiftUI

@Reducer
public struct PhoneNumberLoginReducer {
    @ObservableState
    public struct State: Equatable {
        let authenticationMode: AuthenticationMode
        var credential: Credential
        var errorMessage: String?

        public enum AuthenticationMode: Equatable {
            case signIn
            case createAccount
        }

        @Presents var destination: Destination.State?

        init(authenticationMode: AuthenticationMode = .signIn, errorMessage: String? = nil) {
            @Dependency(\.phoneNumberUtility) var phoneNumberUtility
            self.credential = .init(countryCode: phoneNumberUtility.deviceCountryCode())
            self.authenticationMode = authenticationMode
            self.errorMessage = errorMessage
        }

        var formattedPhoneNumber: String {
            "+\(credential.countryCode.callingCode)\(credential.phoneNumber)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        struct Credential: Equatable {
            var countryCode: CountryCode
            var phoneNumber: String = ""
        }
    }

    public enum Action: Equatable, BindableAction {
        case signInWithPhoneNumberTapped
        case countryCodeFieldTapped
        case destination(PresentationAction<Destination.Action>)
        case verifyPhoneNumberResponseReceived(PhoneNumberVerificationResponse)
        case binding(BindingAction<State>)
    }

    @Reducer(state: .equatable, action: .equatable)
    public enum Destination {
        case countryCodeSelection(CountryCodeSelectionReducer)
        case otpVerification(OtpVerificationReducer)
    }

    public enum PhoneNumberVerificationResponse: Equatable {
        case error(String)
        case verificationId(String)
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .countryCodeFieldTapped:
                state.destination = .countryCodeSelection(.init())
                return .none
            case .destination(.presented(.countryCodeSelection(.countryCodeSelected(let countryCode)))):
                state.credential.countryCode = countryCode
                return .none
            case .signInWithPhoneNumberTapped:
                Auth.auth().settings?.isAppVerificationDisabledForTesting = false
                Auth.auth().useAppLanguage()

                return .run { [state] send in
                    do {
                        let verificationID = try await PhoneAuthProvider.provider()
                            .verifyPhoneNumber(state.formattedPhoneNumber, uiDelegate: nil)
                        await send(.verifyPhoneNumberResponseReceived(.verificationId(verificationID)))
                    } catch {
                        await send(.verifyPhoneNumberResponseReceived(.error(error.localizedDescription)))
                    }
                }
            case .verifyPhoneNumberResponseReceived(let response):
                switch response {
                case .error(let error):
                    state.errorMessage = error
                case .verificationId(let verificationId):
                    state.errorMessage = nil
                    state.destination = .otpVerification(.init(
                        phoneNumber: state.credential.phoneNumber,
                        verificationId: verificationId
                    ))
                }
                return .none
            // OTP succeeded: dismiss the pushed OTP destination so the onboarding
            // NavigationStack can swap its root to the profile-setup step. Without this
            // the OTP screen stays orphaned on top after sign-in. The completion action
            // still bubbles up to CreateAccountReducer in the same dispatch.
            case .destination(.presented(.otpVerification(.otpCodeEntryCompleted))):
                state.destination = nil
                return .none
            case .binding, .destination:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }
}

struct PhoneNumberLoginView: View {
    @Bindable var store: StoreOf<PhoneNumberLoginReducer>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: { store.send(.countryCodeFieldTapped) }) {
                    HStack {
                        Text("\(store.credential.countryCode.flagUnicode) \(store.credential.countryCode.countryName) (+\(store.credential.countryCode.callingCode))")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                }

                TextField("Enter your phone number", text: $store.credential.phoneNumber)
                    .keyboardType(.phonePad)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                Text("We will text to confirm your number. Standard message and data rates apply.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 20) {
                Button(action: { store.send(.signInWithPhoneNumberTapped) }) {
                    Text(store.authenticationMode == .signIn ? "Sign In" : "Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let errorMessage = store.errorMessage {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.large)
                            .foregroundStyle(.red)
                            .symbolEffect(.wiggle, options: .nonRepeating, value: store.errorMessage)
                        Text(errorMessage)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .errorHaptic(store.errorMessage)
        .sheet(
            item: $store.scope(state: \.destination?.countryCodeSelection, action: \.destination.countryCodeSelection)
        ) { store in
            NavigationStack {
                CountryCodeSelectionView(store: store)
                    .navigationTitle("Country Code")
            }
        }
        .navigationDestination(
            item: $store.scope(state: \.destination?.otpVerification, action: \.destination.otpVerification)
        ) { store in
            OtpVerificationView(store: store)
        }
    }
}
