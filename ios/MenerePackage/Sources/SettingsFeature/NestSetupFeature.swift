import ComposableArchitecture
import FamilyDomain
import MenereUI
import NestClient
import PersistenceClient
import SwiftUI

// MARK: - Reducer

/// The Nest thermostat setup state machine (P15-C3). Unlike the LAN ecosystems (Hue/Lutron pair on the
/// local network with a button press), Nest is **cloud + OAuth**: the family pastes in the three
/// identity values produced by Michael's one-time Google Device Access registration (Project ID, OAuth
/// Client ID, Client Secret), then taps **Connect Google account** to run the authorization-code flow.
/// A successful link yields a long-lived refresh token, saved into the shared `NestConfig`.
///
/// Flow: `form → connecting (ASWebAuthenticationSession consent + token exchange) → done | failed`.
@Reducer
public struct NestSetupReducer {
    @ObservableState
    public struct State: Equatable {
        /// Household id the config is written under.
        public var hid: String
        /// The current Nest config, present when reconnecting (its refresh token is replaced on save).
        public var existingConfig: NestConfig?

        // Paste-in identity fields (prefilled from `existingConfig` on reconnect).
        var projectId: String = ""
        var oauthClientId: String = ""
        var oauthClientSecret: String = ""

        var step: Step = .form
        var errorMessage: String?

        public init(hid: String, existingConfig: NestConfig? = nil) {
            self.hid = hid
            self.existingConfig = existingConfig
            if let existing = existingConfig {
                projectId = existing.projectId
                oauthClientId = existing.oauthClientId
                oauthClientSecret = existing.oauthClientSecret ?? ""
            }
        }

        public enum Step: Equatable {
            case form
            case connecting
            case done
            case failed
        }

        /// The two required fields are present → the Connect button enables.
        var canConnect: Bool {
            !projectId.trimmingCharacters(in: .whitespaces).isEmpty
                && !oauthClientId.trimmingCharacters(in: .whitespaces).isEmpty
        }

        /// A `NestConfig` assembled from the current fields (no refresh token yet).
        func draftConfig() -> NestConfig {
            let secret = oauthClientSecret.trimmingCharacters(in: .whitespaces)
            return NestConfig(
                projectId: projectId.trimmingCharacters(in: .whitespaces),
                oauthClientId: oauthClientId.trimmingCharacters(in: .whitespaces),
                oauthClientSecret: secret.isEmpty ? nil : secret,
                refreshToken: nil,
                mock: nil
            )
        }
    }

    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case connectTapped
        case connected(NestConfig)
        case connectFailed(String)
        case retryTapped
        case cancelTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// The config that was written — the parent updates its status row from this.
            case finished(NestConfig)
            case cancelled
        }
    }

    @Dependency(\.nest) var nest
    @Dependency(\.persistence) var persistence
    @Dependency(\.continuousClock) var clock

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .connectTapped:
                guard state.canConnect else { return .none }
                state.step = .connecting
                state.errorMessage = nil
                let config = state.draftConfig()
                return .run { [hid = state.hid] send in
                    // Present consent + exchange the code for a refresh token, then persist it.
                    let refreshToken = try await nest.authorize(config)
                    var connected = config
                    connected.refreshToken = refreshToken
                    try await persistence.saveNestConfig(hid, connected)
                    await send(.connected(connected))
                } catch: { error, send in
                    if let nestError = error as? NestError, nestError == .userCancelled {
                        await send(.connectFailed("Connection cancelled. Tap Connect to try again."))
                    } else {
                        await send(.connectFailed("Couldn't link your Google account. Double-check the three values and try again."))
                    }
                }

            case let .connected(config):
                state.step = .done
                return .run { send in
                    try? await clock.sleep(for: .seconds(1.2))
                    await send(.delegate(.finished(config)))
                }

            case let .connectFailed(message):
                state.step = .failed
                state.errorMessage = message
                return .none

            case .retryTapped:
                state.step = .form
                state.errorMessage = nil
                return .none

            case .cancelTapped:
                return .send(.delegate(.cancelled))

            case .binding, .delegate:
                return .none
            }
        }
    }
}

// MARK: - View

public struct NestSetupView: View {
    @Bindable var store: StoreOf<NestSetupReducer>

    public init(store: StoreOf<NestSetupReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch store.step {
                case .form: form
                case .connecting: connecting
                case .done: done
                case .failed: failed
                }
            }
            .background(Color.familyCanvas)
            .navigationTitle("Nest thermostat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if store.step != .done {
                        Button("Cancel") { store.send(.cancelTapped) }
                    }
                }
            }
        }
    }

    // MARK: Steps

    private var form: some View {
        Form {
            Section {
                Text("Needs a one-time Google Device Access registration — the runbook lives with Claude.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSoft)
            } header: {
                Text("One-time Google setup")
            } footer: {
                Text("Michael registers a Device Access project ($5) and an OAuth client once, then pastes the three values below. After that, connecting is a single tap.")
            }

            Section {
                LabeledContent("Project ID") {
                    TextField("GUID", text: $store.projectId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("nest-project-id-field")
                }
                LabeledContent("OAuth Client ID") {
                    TextField("…apps.googleusercontent.com", text: $store.oauthClientId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("nest-client-id-field")
                }
                LabeledContent("Client Secret") {
                    TextField("Optional", text: $store.oauthClientSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("nest-client-secret-field")
                }
            } header: {
                Text("Credentials")
            }

            Section {
                Button {
                    store.send(.connectTapped)
                } label: {
                    HStack {
                        Image(systemName: "link")
                        Text("Connect Google account")
                    }
                }
                .disabled(!store.canConnect)
                .accessibilityIdentifier("nest-connect-button")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
    }

    private var connecting: some View {
        centered {
            ProgressView().controlSize(.large)
            Text("Linking your Google account…")
                .font(.headline).foregroundStyle(Color.ink)
            Text("Approve the thermostat in the Google window.")
                .font(.subheadline).foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
        }
    }

    private var done: some View {
        centered {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(Color.bacanGreen)
            Text("Nest is connected.")
                .font(.title3.bold()).foregroundStyle(Color.ink)
        }
    }

    private var failed: some View {
        centered {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48)).foregroundStyle(Color.terracotta)
            Text(store.errorMessage ?? "Something went sideways.")
                .font(.subheadline).foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
            Button {
                store.send(.retryTapped)
            } label: {
                Text("Back").frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.bacanGreen)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
