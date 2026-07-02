import AuthenticationDomain
import ComposableArchitecture
import FamilyDomain
import HouseholdClient
import MenereUI
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
        var members: [HouseholdMember] = []
        var isLoadingHousehold = false
        var showJoinSheet = false
        var joinCode = ""
        var isJoining = false
        var joinError: String?
        @Presents var profileEdit: ProfileEditReducer.State?

        public init() {}

        /// The signed-in user's own member profile, if loaded.
        var myMember: HouseholdMember? {
            @Shared(.user) var user
            guard let uid = user?.id else { return nil }
            return members.first { $0.id == uid }
        }
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
        case membersLoaded([HouseholdMember])
        case joinHouseholdTapped
        case submitJoinTapped
        case joinResponse(JoinResult)
        case dismissJoinSheet
        case editProfileTapped
        case profileEdit(PresentationAction<ProfileEditReducer.Action>)
        case binding(BindingAction<State>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .editProfileTapped:
                guard let me = state.myMember else { return .none }
                state.profileEdit = ProfileEditReducer.State(member: me)
                return .none

            case let .profileEdit(.presented(.delegate(.saved(member)))):
                if let i = state.members.firstIndex(where: { $0.id == member.id }) {
                    state.members[i] = member
                } else {
                    state.members.append(member)
                }
                return .none

            case .profileEdit:
                return .none

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
                    let members = (try? await persistence.members(hid)) ?? []
                    await send(.membersLoaded(members))
                }

            case let .householdLoaded(h):
                state.isLoadingHousehold = false
                state.household = h
                return .none

            case let .membersLoaded(members):
                state.members = members.sorted { $0.joinedAt < $1.joinedAt }
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
                let uid = user?.id
                let name = user?.displayName ?? ""
                return .run { send in
                    if let uid {
                        @Dependency(\.persistence) var persistence
                        _ = try? await persistence.ensureMember(hid, uid, name)
                    }
                    await send(.task)
                }

            case let .joinResponse(.failure(message)):
                state.isJoining = false
                state.joinError = message
                return .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$profileEdit, action: \.profileEdit) {
            ProfileEditReducer()
        }
    }
}

public struct SettingsView: View {
    @Bindable var store: StoreOf<SettingsReducer>

    /// Drives the copy-button glyph swap (doc → checkmark) for ~1.5s after a copy.
    @State private var copied = false
    /// Bumped on each copy so a success haptic fires only on copy (not on the reset).
    @State private var copyTick = 0

    public init(store: StoreOf<SettingsReducer>) {
        self.store = store
    }

    public var body: some View {
        List {
            if let me = store.myMember {
                Section("My Profile") {
                    Button {
                        store.send(.editProfileTapped)
                    } label: {
                        HStack(spacing: 12) {
                            let rgb = me.color.rgb
                            Image(systemName: me.avatarSystemName)
                                .font(.largeTitle)
                                .foregroundStyle(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(me.name).font(.headline).foregroundStyle(Color.ink)
                                Text("Edit name, color, avatar")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("edit-profile-row")
                }
            }

            Section("Family") {
                if store.members.isEmpty, store.isLoadingHousehold {
                    ProgressView()
                } else {
                    ForEach(store.members) { member in
                        memberRow(member)
                    }
                }
            }

            Section("Invite") {
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
                                copyTick += 1
                                copied = true
                                Task {
                                    try? await Task.sleep(for: .seconds(1.5))
                                    copied = false
                                }
                            } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .contentTransition(.symbolEffect(.replace))
                                    .foregroundStyle(copied ? Color.marigold : Color.bacanGreen)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("copy-invite-code-button")
                            .successHaptic(copyTick)
                        }
                        Text("\(household.members.count) member\(household.members.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
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
                        Text("Join a family")
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
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Sign Out", isPresented: $store.showSignOutConfirmation) {
            Button("Cancel", role: .cancel) { store.send(.cancelSignOut) }
            Button("Sign Out", role: .destructive) { store.send(.confirmSignOut) }
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .sheet(isPresented: $store.showJoinSheet) {
            joinSheet
        }
        .sheet(item: $store.scope(state: \.profileEdit, action: \.profileEdit)) { editStore in
            ProfileEditView(store: editStore)
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
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Join a Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.dismissJoinSheet) }
                }
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: HouseholdMember) -> some View {
        HStack(spacing: 12) {
            let rgb = member.color.rgb
            Image(systemName: member.avatarSystemName)
                .font(.title2)
                .foregroundStyle(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                .accessibilityHidden(true)
            Text(member.name)
            Spacer()
            if member.role != .member {
                Text(member.role.rawValue.capitalized)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
