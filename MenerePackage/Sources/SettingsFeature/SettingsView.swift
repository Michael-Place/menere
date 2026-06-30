import AuthenticationDomain
import ComposableArchitecture
import HouseholdClient
import PersistenceClient
import SwiftUI
import UserDomain
import WineDomain

@Reducer
public struct SettingsReducer {
    @ObservableState
    public struct State: Equatable {
        var showSignOutConfirmation = false
        var household: Household?
        var isLoadingHousehold = false
        var showJoinSheet = false
        var joinCode = ""
        var isJoining = false
        var joinError: String?

        public init() {}
    }

    public enum JoinResult: Equatable {
        case success(String)
        case failure(String)
    }

    public enum Action: Equatable, BindableAction {
        case signOutTapped
        case confirmSignOut
        case cancelSignOut
        case task
        case householdLoaded(Household?)
        case joinHouseholdTapped
        case submitJoinTapped
        case joinResponse(JoinResult)
        case dismissJoinSheet
        case binding(BindingAction<State>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .signOutTapped:
                state.showSignOutConfirmation = true
                return .none

            case .confirmSignOut:
                state.showSignOutConfirmation = false
                return .run { _ in
                    @Dependency(\.authentication) var authentication
                    try authentication.signOut()
                }

            case .cancelSignOut:
                state.showSignOutConfirmation = false
                return .none

            case .task:
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                state.isLoadingHousehold = true
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let h = try? await persistence.household(hid)
                    await send(.householdLoaded(h))
                }

            case let .householdLoaded(h):
                state.isLoadingHousehold = false
                state.household = h
                return .none

            case .joinHouseholdTapped:
                state.joinCode = ""
                state.joinError = nil
                state.showJoinSheet = true
                return .none

            case .dismissJoinSheet:
                state.showJoinSheet = false
                return .none

            case .submitJoinTapped:
                guard !state.isJoining,
                      !state.joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return .none }
                state.isJoining = true
                state.joinError = nil
                return .run { [code = state.joinCode] send in
                    @Dependency(\.household) var household
                    do {
                        let hid = try await household.join(code)
                        await send(.joinResponse(.success(hid)))
                    } catch {
                        await send(.joinResponse(.failure(error.localizedDescription)))
                    }
                }

            case let .joinResponse(.success(hid)):
                state.isJoining = false
                @Shared(.user) var user
                $user.withLock { $0?.householdId = hid }
                state.showJoinSheet = false
                return .send(.task)

            case let .joinResponse(.failure(message)):
                state.isJoining = false
                state.joinError = message
                return .none

            case .binding:
                return .none
            }
        }
    }
}

public struct SettingsView: View {
    @Bindable var store: StoreOf<SettingsReducer>

    public init(store: StoreOf<SettingsReducer>) {
        self.store = store
    }

    public var body: some View {
        List {
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Household") {
                if let household = store.household {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Invite code")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(household.inviteCode)
                                .font(.system(.title2, design: .monospaced))
                                .fontWeight(.bold)
                                .accessibilityIdentifier("household-invite-code")
                            Spacer()
                            Button {
                                UIPasteboard.general.string = household.inviteCode
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("copy-invite-code-button")
                        }
                        Text("\(household.members.count) member\(household.members.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if store.isLoadingHousehold {
                    ProgressView()
                }

                Button {
                    store.send(.joinHouseholdTapped)
                } label: {
                    HStack {
                        Image(systemName: "person.badge.plus")
                        Text("Join a household")
                    }
                }
                .accessibilityIdentifier("join-household-button")
            }

            Section {
                Button(role: .destructive) {
                    store.send(.signOutTapped)
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Sign Out")
                    }
                }
            }
        }
        .navigationTitle("Profile")
        .alert("Sign Out", isPresented: $store.showSignOutConfirmation) {
            Button("Cancel", role: .cancel) { store.send(.cancelSignOut) }
            Button("Sign Out", role: .destructive) { store.send(.confirmSignOut) }
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .sheet(isPresented: $store.showJoinSheet) {
            joinSheet
        }
        .task { store.send(.task) }
    }

    private var joinSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invite code", text: $store.joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("join-code-field")
                } footer: {
                    if let error = store.joinError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        store.send(.submitJoinTapped)
                    } label: {
                        if store.isJoining {
                            ProgressView()
                        } else {
                            Text("Join")
                        }
                    }
                    .disabled(store.isJoining || store.joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("submit-join-button")
                }
            }
            .navigationTitle("Join a Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.dismissJoinSheet) }
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
