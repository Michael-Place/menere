import ComposableArchitecture
import FirebaseAuth
import SwiftUI

@Reducer
public struct OtpVerificationReducer {
    @ObservableState
    public struct State: Equatable {
        let phoneNumber: String
        let verificationId: String
        var otpCode: String = ""
        var errorMessage: String?
        var otpSubmitted: Bool = false
    }

    public enum Action: Equatable, BindableAction {
        case otpVerificationFailed(String)
        case otpCodeEntryCompleted(String)
        case binding(BindingAction<State>)
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.otpCode):
                guard state.otpCode.count == 6, state.otpSubmitted == false else {
                    return .none
                }

                state.otpSubmitted = true

                let credential = PhoneAuthProvider.provider().credential(
                    withVerificationID: state.verificationId,
                    verificationCode: state.otpCode
                )

                return .run { send in
                    do {
                        let response = try await Auth.auth().signIn(with: credential)
                        await send(.otpCodeEntryCompleted(response.user.uid))
                    } catch {
                        await send(.otpVerificationFailed(error.localizedDescription))
                    }
                }
            case .otpVerificationFailed(let error):
                state.errorMessage = error
                state.otpSubmitted = false
                return .none
            case .binding, .otpCodeEntryCompleted:
                return .none
            }
        }
    }
}

struct OtpVerificationView: View {
    @Bindable var store: StoreOf<OtpVerificationReducer>
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("6 digit code")
                        .font(.title.bold())

                    Text("Please enter the code we've sent to\n\(store.phoneNumber)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                TextField("000000", text: $store.otpCode)
                    .keyboardType(.numberPad)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .focused($isFocused)

                if let errorMessage = store.errorMessage {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.large)
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                    }
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { isFocused = true }
    }
}
