import ComposableArchitecture
import FamilyDomain
import HubspaceClient
import MenereUI
import PersistenceClient
import SwiftUI

// MARK: - Reducer

/// The Hubspace water-timer setup state machine (P15-C4). Hubspace has no official API, so instead of a
/// LAN pairing (Hue/Lutron) or a Google OAuth consent (Nest), the family signs in with the **Hubspace
/// email + password** directly. Bacán runs the Keycloak login, captures the long-lived refresh token +
/// account id, and saves ONLY those — the **password is never stored**.
///
/// Flow: `form → connecting (login + token capture) → done | failed`.
@Reducer
public struct HubspaceSetupReducer {
    @ObservableState
    public struct State: Equatable {
        /// Household id the config is written under.
        public var hid: String
        /// The current Hubspace config, present when reconnecting (its tokens are replaced on save).
        public var existingConfig: HubspaceConfig?

        // Sign-in fields (email prefilled from `existingConfig` on reconnect; password is never stored,
        // so it always starts empty).
        var email: String = ""
        var password: String = ""

        var step: Step = .form
        var errorMessage: String?
        /// A non-fatal note shown on the success screen when login+save succeeded but the *post-login*
        /// spigot probe couldn't reach Hubspace (e.g. a cloud hiccup, or a firewall still settling). We
        /// are connected — the token is saved — so this is a soft heads-up, NOT a failure.
        var softNote: String?

        public init(hid: String, existingConfig: HubspaceConfig? = nil) {
            self.hid = hid
            self.existingConfig = existingConfig
            if let existing = existingConfig { email = existing.email ?? "" }
        }

        public enum Step: Equatable {
            case form
            case connecting
            case done
            case failed
        }

        /// Both fields present → the Connect button enables.
        var canConnect: Bool {
            !email.trimmingCharacters(in: .whitespaces).isEmpty
                && !password.isEmpty
        }
    }

    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case connectTapped
        /// Login + save succeeded → connected. The `String?` is an optional soft note (a post-login
        /// probe hiccup); nil means the spigot was reached cleanly.
        case connected(HubspaceConfig, String?)
        case connectFailed(String)
        case retryTapped
        case cancelTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// The config that was written — the parent updates its status row from this.
            case finished(HubspaceConfig)
            case cancelled
        }
    }

    @Dependency(\.hubspace) var hubspace
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
                let email = state.email.trimmingCharacters(in: .whitespaces)
                let password = state.password
                return .run { [hid = state.hid] send in
                    // Sign in, then persist ONLY the refresh token + account id + email (never the
                    // password). Once the config is SAVED we are connected — that's the source of truth.
                    let tokens = try await hubspace.login(email, password)
                    let config = HubspaceConfig(
                        refreshToken: tokens.refreshToken,
                        accountId: tokens.accountId,
                        email: email,
                        mock: nil
                    )
                    try await persistence.saveHubspaceConfig(hid, config)

                    // POST-LOGIN probe (the fix for "failed-but-connected"): try one device read so we can
                    // warn if the spigot can't be reached right now. A probe failure is NOT a login
                    // failure — the token is already saved — so it degrades to a soft note, never the
                    // failure screen. (The original bug: a post-login fetch throwing was caught by the
                    // same handler as a bad password, so a saved-and-connected account reported failure —
                    // exactly what happened while Little Snitch was still blocking the sim's cloud calls.)
                    var note: String?
                    do {
                        _ = try await hubspace.spigots(config)
                    } catch {
                        note = "Signed in — but Bacán couldn't reach your spigot just now. It'll show up on Today once it's back online."
                    }
                    await send(.connected(config, note))
                } catch: { error, send in
                    // Surface the *reason* — a genuine bad password reads very differently from an OTP
                    // wall or a flow/network break, and conflating them (the old behavior) is exactly
                    // what made a real auth bug masquerade as "wrong password".
                    let message: String
                    switch error as? HubspaceError {
                    case .invalidCredentials:
                        message = "Couldn't sign in to Hubspace. Double-check your email and password and try again."
                    case .otpRequired:
                        message = "Your Hubspace account requires a verification code, which Bacán can't enter yet. Turn off two-step verification in the Hubspace app, then try again."
                    case .loginFailed, .invalidTokenResponse, .requestFailed, .noAccountId, .notConfigured, .none:
                        message = "Couldn't reach Hubspace to sign in. Check your connection and try again."
                    }
                    await send(.connectFailed(message))
                }

            case let .connected(config, note):
                state.step = .done
                state.softNote = note
                state.password = ""   // never keep it around
                return .run { send in
                    // Linger a touch longer when there's a note so it can be read.
                    try? await clock.sleep(for: .seconds(note == nil ? 1.2 : 2.4))
                    await send(.delegate(.finished(config)))
                }

            case let .connectFailed(message):
                state.step = .failed
                state.password = ""
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

public struct HubspaceSetupView: View {
    @Bindable var store: StoreOf<HubspaceSetupReducer>

    public init(store: StoreOf<HubspaceSetupReducer>) {
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
            .navigationTitle("Hubspace spigot")
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
                Text("Bacán signs into Hubspace directly — the password isn't stored, only the session token.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSoft)
            } header: {
                Text("Sign in to Hubspace")
            } footer: {
                Text("Use the same email + password you use in the Hubspace app. Bacán keeps only a refresh token so both of you can open the spigot from Today.")
            }

            Section {
                LabeledContent("Email") {
                    TextField("you@example.com", text: $store.email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("hubspace-email-field")
                }
                LabeledContent("Password") {
                    SecureField("Required", text: $store.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("hubspace-password-field")
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
                        Text("Connect")
                    }
                }
                .disabled(!store.canConnect)
                .accessibilityIdentifier("hubspace-connect-button")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
    }

    private var connecting: some View {
        centered {
            ProgressView().controlSize(.large)
            Text("Signing in to Hubspace…")
                .font(.headline).foregroundStyle(Color.ink)
            Text("This takes a moment.")
                .font(.subheadline).foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
        }
    }

    private var done: some View {
        centered {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(Color.bacanGreen)
            Text("Hubspace is connected.")
                .font(.title3.bold()).foregroundStyle(Color.ink)
            if let note = store.softNote {
                Text(note)
                    .font(.subheadline).foregroundStyle(Color.inkSoft)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("hubspace-soft-note")
            }
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
