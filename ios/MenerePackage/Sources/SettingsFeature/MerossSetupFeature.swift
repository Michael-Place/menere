import ComposableArchitecture
import FamilyDomain
import MenereUI
import MerossClient
import PersistenceClient
import SwiftUI

// MARK: - Reducer

/// The Refoss/Meross garage-opener setup state machine (P15-C5). Unlike Hue/Lutron (LAN pairing) or
/// Nest/Hubspace (a cloud sign-in), a Meross device is reached directly on the LAN — so setup is two
/// fields: the opener's **IP address** and the Meross/Refoss **device key** (which signs every message).
/// We deliberately do NOT do UDP-broadcast discovery (it needs the restricted iOS multicast entitlement);
/// a manual IP is one honest field, and the opener has a stable DHCP-reserved address anyway.
///
/// Flow: `form → connecting (validate via Appliance.System.All) → done | failed`. On success we capture
/// the device uuid + name from `System.All` and persist the full config.
@Reducer
public struct MerossSetupReducer {
    @ObservableState
    public struct State: Equatable {
        /// Household id the config is written under.
        public var hid: String
        /// The current Meross config, present when reconnecting (its IP/key are replaced on save).
        public var existingConfig: MerossConfig?

        // Setup fields (prefilled from `existingConfig` on reconnect).
        var deviceIP: String = ""
        var deviceKey: String = ""

        var step: Step = .form
        var errorMessage: String?

        public init(hid: String, existingConfig: MerossConfig? = nil) {
            self.hid = hid
            self.existingConfig = existingConfig
            if let existing = existingConfig {
                deviceIP = existing.deviceIP ?? ""
                deviceKey = existing.deviceKey ?? ""
            }
        }

        public enum Step: Equatable {
            case form
            case connecting
            case done
            case failed
        }

        /// The IP is required (the key may be empty for a keyless device) → the Connect button enables.
        var canConnect: Bool {
            !deviceIP.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case connectTapped
        /// Validation + save succeeded → connected, carrying the saved config.
        case connected(MerossConfig)
        case connectFailed(String)
        case retryTapped
        case cancelTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// The config that was written — the parent updates its status row from this.
            case finished(MerossConfig)
            case cancelled
        }
    }

    @Dependency(\.meross) var meross
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
                let ip = state.deviceIP.trimmingCharacters(in: .whitespaces)
                let key = state.deviceKey   // keep as typed (may legitimately be empty)
                return .run { [hid = state.hid] send in
                    // Validate by fetching System.All: proves the IP is reachable AND the key signs
                    // acceptably (a wrong key is rejected → a bad response → throw). Capture uuid + name.
                    let info = try await meross.deviceInfo(ip, key)
                    let config = MerossConfig(
                        deviceIP: ip,
                        deviceKey: key,
                        uuid: info.uuid,
                        name: info.name ?? info.channels.first?.displayName ?? "Garage",
                        mock: nil
                    )
                    try await persistence.saveMerossConfig(hid, config)
                    await send(.connected(config))
                } catch: { _, send in
                    await send(.connectFailed("Couldn't reach the opener. Check the IP address and device key, and that your phone is on the home Wi-Fi."))
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

public struct MerossSetupView: View {
    @Bindable var store: StoreOf<MerossSetupReducer>

    public init(store: StoreOf<MerossSetupReducer>) {
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
            .navigationTitle("Garage (Refoss)")
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
                Text("Your Refoss garage opener is a Meross device — Bacán talks to it directly on your home Wi-Fi (no cloud).")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSoft)
            } header: {
                Text("Set up the garage")
            } footer: {
                Text("Find the opener's IP in your router or DHCP client list (reserve it so it doesn't change).")
            }

            Section {
                LabeledContent("IP address") {
                    TextField("192.168.1.42", text: $store.deviceIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("meross-ip-field")
                }
                LabeledContent("Device key") {
                    SecureField("Meross/Refoss key", text: $store.deviceKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("meross-key-field")
                }
            } header: {
                Text("Device")
            } footer: {
                Text("The device key is your Meross/Refoss account key — ask Claude to fetch it, or use a key-grabber tool. Some devices accept an empty key.")
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
                .accessibilityIdentifier("meross-connect-button")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
    }

    private var connecting: some View {
        centered {
            ProgressView().controlSize(.large)
            Text("Reaching the opener…")
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
            Text("Garage is connected.")
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
