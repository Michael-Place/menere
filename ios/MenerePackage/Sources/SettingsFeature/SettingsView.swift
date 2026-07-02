import AuthenticationDomain
import ComposableArchitecture
import FamilyDomain
import HouseholdClient
import HueClient
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

        // MARK: Smart home (Hue, P12-C2)
        /// The household's Hue config, or nil when never paired (→ the "Set up" row).
        var hueConfig: HueConfig?
        /// Live reachability of the paired bridge: nil = still probing, true/false = result.
        var hueReachable: Bool?
        /// Live scenes from the bridge (for the ritual-row names + the rebind picker). Empty when
        /// unreachable or not yet loaded.
        var hueScenes: [HueScene] = []
        /// The ritual key whose rebind scene-picker is open on the status view (nil = closed).
        var huePickerRitualKey: String?
        @Presents var huePairing: HuePairingReducer.State?

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

        // Smart home (Hue)
        case hueConfigLoaded(HueConfig?)
        case hueProbeLoaded(reachable: Bool, scenes: [HueScene])
        case setupHueTapped
        case rePairTapped
        case hueRitualTapped(String?)
        case hueSceneChosen(ritualKey: String, scene: HueScene)
        case hueConfigResaved(HueConfig)
        case huePairing(PresentationAction<HuePairingReducer.Action>)
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
                    // Smart home: load the config, then (if present) probe the bridge for the
                    // reachability dot + scenes that name the ritual bindings.
                    let config = try? await persistence.hueConfig(hid)
                    await send(.hueConfigLoaded(config ?? nil))
                }

            case let .hueConfigLoaded(config):
                state.hueConfig = config
                guard let config else {
                    state.hueReachable = nil
                    state.hueScenes = []
                    return .none
                }
                state.hueReachable = nil   // "probing…"
                return .run { send in
                    @Dependency(\.hue) var hue
                    let reachable = (try? await hue.testConnection(config)) ?? false
                    let scenes = reachable ? ((try? await hue.scenes(config)) ?? []) : []
                    await send(.hueProbeLoaded(reachable: reachable, scenes: scenes))
                }

            case let .hueProbeLoaded(reachable, scenes):
                state.hueReachable = reachable
                state.hueScenes = scenes
                return .none

            case .setupHueTapped, .rePairTapped:
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                state.huePairing = HuePairingReducer.State(hid: hid, existingConfig: state.hueConfig)
                return .none

            case let .hueRitualTapped(key):
                state.huePickerRitualKey = key
                return .none

            case let .hueSceneChosen(ritualKey, scene):
                state.huePickerRitualKey = nil
                guard var config = state.hueConfig, let groupId = scene.groupId else { return .none }
                let label = config.rituals.first(where: { $0.key == ritualKey })?.label
                    ?? HueBindingMatch.standardRituals.first(where: { $0.key == ritualKey })?.label
                    ?? ritualKey.capitalized
                let ritual = HueRitual(key: ritualKey, label: label, sceneId: scene.id, groupId: groupId)
                if let i = config.rituals.firstIndex(where: { $0.key == ritualKey }) {
                    config.rituals[i] = ritual
                } else {
                    config.rituals.append(ritual)
                }
                state.hueConfig = config
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                return .run { [config] send in
                    @Dependency(\.persistence) var persistence
                    try? await persistence.saveHueConfig(hid, config)
                    await send(.hueConfigResaved(config))
                }

            case let .hueConfigResaved(config):
                state.hueConfig = config
                return .none

            case let .huePairing(.presented(.delegate(.finished(config)))):
                state.huePairing = nil
                return .send(.hueConfigLoaded(config))

            case .huePairing(.presented(.delegate(.cancelled))):
                state.huePairing = nil
                return .none

            case .huePairing:
                return .none

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
        .ifLet(\.$huePairing, action: \.huePairing) {
            HuePairingReducer()
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

            Section {
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
            } header: {
                Text("Invite")
            } footer: {
                Text("Share this code and someone can join the family from their own phone.")
            }

            smartHomeSection

            Section {
                Button(role: .destructive) {
                    store.send(.signOutTapped)
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Sign out")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Sign out", isPresented: $store.showSignOutConfirmation) {
            Button("Cancel", role: .cancel) { store.send(.cancelSignOut) }
            Button("Sign out", role: .destructive) { store.send(.confirmSignOut) }
        } message: {
            Text("Leaving already? You'll need your phone number to sign back in.")
        }
        .sheet(isPresented: $store.showJoinSheet) {
            joinSheet
        }
        .sheet(item: $store.scope(state: \.profileEdit, action: \.profileEdit)) { editStore in
            ProfileEditView(store: editStore)
        }
        .sheet(item: $store.scope(state: \.huePairing, action: \.huePairing)) { pairingStore in
            HuePairingView(store: pairingStore)
        }
        .sheet(isPresented: Binding(
            get: { store.huePickerRitualKey != nil },
            set: { if !$0 { store.send(.hueRitualTapped(nil)) } }
        )) {
            hueScenePicker
        }
        .task { store.send(.task) }
    }

    // MARK: - Smart home (Hue, P12-C2)

    @ViewBuilder
    private var smartHomeSection: some View {
        Section {
            if let config = store.hueConfig {
                hueStatusRow(config)
                Button {
                    store.send(.rePairTapped)
                } label: {
                    Label("Re-pair bridge", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Color.ink)
                }
                .accessibilityIdentifier("hue-repair-row")
                ForEach(hueRitualStates(config), id: \.key) { ritual in
                    hueRitualRow(ritual)
                }
            } else {
                Button {
                    store.send(.setupHueTapped)
                } label: {
                    Label("Set up Philips Hue", systemImage: "lightbulb")
                        .foregroundStyle(Color.ink)
                }
                .accessibilityIdentifier("hue-setup-row")
            }
        } header: {
            Text("Smart home")
        } footer: {
            if store.hueConfig == nil {
                Text("Pair your Hue bridge to light up the house from Today.")
            }
        }
    }

    private func hueStatusRow(_ config: HueConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.router")
                .foregroundStyle(Color.bacanGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hue bridge").foregroundStyle(Color.ink)
                Text(config.bridgeId).font(.caption).foregroundStyle(Color.inkSoft)
            }
            Spacer()
            hueReachabilityDot
        }
        .accessibilityIdentifier("hue-status-row")
    }

    @ViewBuilder
    private var hueReachabilityDot: some View {
        switch store.hueReachable {
        case .some(true):
            HStack(spacing: 6) {
                Circle().fill(Color.bacanGreen).frame(width: 8, height: 8)
                Text("Reachable").font(.caption).foregroundStyle(Color.inkSoft)
            }
        case .some(false):
            HStack(spacing: 6) {
                Circle().fill(Color.inkSoft).frame(width: 8, height: 8)
                Text("Bridge unreachable — are you home?").font(.caption).foregroundStyle(Color.inkSoft)
            }
        case .none:
            ProgressView().controlSize(.mini)
        }
    }

    private func hueRitualRow(_ ritual: HueRitualStatus) -> some View {
        Button {
            store.send(.hueRitualTapped(ritual.key))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ritual.label).foregroundStyle(Color.ink)
                    if let sceneName = ritual.sceneName {
                        Text("→ \(sceneName)").font(.caption).foregroundStyle(Color.inkSoft)
                    } else {
                        Text("needs a scene").font(.caption).foregroundStyle(Color.terracotta)
                    }
                }
                Spacer()
                if !store.hueScenes.isEmpty {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(store.hueScenes.isEmpty)
    }

    private var hueScenePicker: some View {
        NavigationStack {
            List {
                ForEach(store.hueScenes) { scene in
                    Button {
                        if let key = store.huePickerRitualKey {
                            store.send(.hueSceneChosen(ritualKey: key, scene: scene))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scene.name).foregroundStyle(Color.ink)
                            if let groupId = scene.groupId {
                                Text("Room \(groupId)").font(.caption).foregroundStyle(Color.inkSoft)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Choose a scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.hueRitualTapped(nil)) }
                }
            }
        }
    }

    /// One ritual's display state on the status view.
    private struct HueRitualStatus: Equatable {
        let key: String
        let label: String
        /// The live scene name when bound + resolvable; nil → "needs a scene".
        let sceneName: String?
    }

    /// The rituals to list under a paired config: the two standards, unioned with any extra rituals
    /// the config already carries, each resolved to its live scene name when bound.
    private func hueRitualStates(_ config: HueConfig) -> [HueRitualStatus] {
        var keys: [(key: String, label: String)] = HueBindingMatch.standardRituals
        for ritual in config.rituals where !keys.contains(where: { $0.key == ritual.key }) {
            keys.append((ritual.key, ritual.label))
        }
        return keys.map { entry in
            if let bound = config.rituals.first(where: { $0.key == entry.key }) {
                let name = store.hueScenes.first(where: { $0.id == bound.sceneId })?.name
                return HueRitualStatus(key: entry.key, label: bound.label, sceneName: name ?? "scene set")
            } else {
                return HueRitualStatus(key: entry.key, label: entry.label, sceneName: nil)
            }
        }
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
            .navigationTitle("Join a family")
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
