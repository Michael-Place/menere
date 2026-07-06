import ComposableArchitecture
import FirebaseFunctions
import Foundation
import MenereUI
import SwiftUI

/// Phone-side of the Apple TV device-pairing flow (P27-T2-C1).
///
/// The living-room tvOS app shows a 6-character code; a family member types it here and taps
/// **Link**, which calls the `pairAppleTV` Cloud Function. That function mints a Firebase custom
/// token for the TV and lets it into the household — so the TV can sign in and start showing the
/// family's world on the big screen.
@Reducer
public struct AppleTVPairingReducer {
    @ObservableState
    public struct State: Equatable {
        public var code: String = ""
        public var isLinking = false
        public var linked = false
        public var errorMessage: String?

        public init() {}

        /// The code the function accepts (4+ chars); the TV always shows 6.
        var canLink: Bool { code.trimmingCharacters(in: .whitespaces).count >= 4 && !isLinking }
    }

    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case linkTapped
        case linkSucceeded
        case linkFailed(String)
        case doneTapped
    }

    public init() {}

    @Dependency(\.dismiss) var dismiss

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .linkTapped:
                let code = state.code.trimmingCharacters(in: .whitespaces).uppercased()
                guard code.count >= 4 else { return .none }
                state.isLinking = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        let callable = Functions.functions(region: "us-central1")
                            .httpsCallable("pairAppleTV")
                        _ = try await callable.call(["code": code])
                        await send(.linkSucceeded)
                    } catch {
                        await send(.linkFailed(Self.friendlyMessage(for: error)))
                    }
                }

            case .linkSucceeded:
                state.isLinking = false
                state.linked = true
                return .none

            case let .linkFailed(message):
                state.isLinking = false
                state.errorMessage = message
                return .none

            case .doneTapped:
                return .run { _ in await dismiss() }
            }
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        // FirebaseFunctions surfaces the function's HttpsError message in the localized description.
        if !ns.localizedDescription.isEmpty { return ns.localizedDescription }
        return "Something went wrong linking your TV. Give it another go."
    }
}

public struct AppleTVPairingView: View {
    @Bindable var store: StoreOf<AppleTVPairingReducer>

    public init(store: StoreOf<AppleTVPairingReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.familyCanvas.ignoresSafeArea()
                if store.linked {
                    successView
                } else {
                    formView
                }
            }
            .navigationTitle("Link Apple TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { store.send(.doneTapped) }
                }
            }
        }
    }

    private var formView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "tv.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.sky)
                Text("Open ¡Bacán! on your Apple TV and type the 6-character code it shows.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.ink)
            }
            .padding(.top, 24)

            TextField("Code", text: $store.code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(.white))
                .accessibilityIdentifier("apple-tv-code-field")

            if let error = store.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                store.send(.linkTapped)
            } label: {
                HStack {
                    if store.isLinking { ProgressView().tint(.white) }
                    Text(store.isLinking ? "Linking…" : "Link")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.bacanGreen)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .disabled(!store.canLink)
            .opacity(store.canLink ? 1 : 0.5)
            .accessibilityIdentifier("apple-tv-link-button")

            Spacer()
        }
        .padding(24)
    }

    private var successView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.bacanGreen)
            Text("Apple TV linked ✓")
                .font(.title.bold())
                .foregroundStyle(Color.ink)
            Text("Your TV is signing in now — the family will show up on the big screen in a moment.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            Button("Done") { store.send(.doneTapped) }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.bacanGreen)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding(24)
    }
}
