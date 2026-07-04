import AuthenticationDomain
import ComposableArchitecture
import FamilyDomain
import HomeKitClient
import HouseholdClient
import HubspaceClient
import HueClient
import LutronClient
import MenereUI
import MerossClient
import NestClient
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
        /// P25 — "Ideas for Bacán" wishlist capture sheet.
        @Presents var wishlist: WishlistReducer.State?

        // MARK: Smart home (Hue, P12-C3 — multi-bridge)
        /// The household's Hue config, or nil when never paired (→ the "Set up" row).
        var hueConfig: HueConfig?
        /// bridgeId → live reachability. A missing entry = still probing that bridge.
        var hueBridgeReachable: [String: Bool] = [:]
        /// bridgeId → live scenes (names the ritual bindings + feeds the rebind picker). Empty when
        /// that bridge is unreachable.
        var hueScenesByBridge: [String: [HueScene]] = [:]
        /// The (bound) ritual whose rebind scene-picker is open (nil = closed).
        var huePickerRitual: HueRitual?
        /// The bridge pending a Remove confirmation (nil = none).
        var removingBridge: HueBridgeConfig?
        /// True while the "Remove all Hue" confirmation dialog is up (forgets every bridge + ritual).
        var confirmingHueRemoveAll = false
        @Presents var huePairing: HuePairingReducer.State?

        // MARK: Smart home (Lutron shades, P15-C1)
        /// The household's Lutron config, or nil when never paired (→ the "Set up" row).
        var lutronConfig: LutronConfig?
        /// Live reachability of the Lutron bridge (nil = still probing).
        var lutronReachable: Bool?
        /// True while the Remove-Lutron confirmation dialog is up.
        var confirmingLutronRemove = false
        @Presents var lutronPairing: LutronPairingReducer.State?

        // MARK: Smart home (Nest thermostat, P15-C3)
        /// The household's Nest config, or nil when never set up (→ the "Set up Nest" row).
        var nestConfig: NestConfig?
        /// Thermostat count from the first fetch (nil = not yet fetched / not connected).
        var nestThermostatCount: Int?
        /// True while the Remove-Nest confirmation dialog is up.
        var confirmingNestRemove = false
        @Presents var nestSetup: NestSetupReducer.State?

        // MARK: Smart home (Hubspace water timer, P15-C4)
        /// The household's Hubspace config, or nil when never set up (→ the "Set up Hubspace" row).
        var hubspaceConfig: HubspaceConfig?
        /// Live spigot count once fetched (nil until probed / unreachable).
        var hubspaceSpigotCount: Int?
        /// True while the Remove-Hubspace confirmation dialog is up.
        var confirmingHubspaceRemove = false
        @Presents var hubspaceSetup: HubspaceSetupReducer.State?

        // MARK: Smart home (Meross/Refoss garage opener, P15-C5)
        /// The household's Meross config, or nil when never set up (→ the "Set up garage" row).
        var merossConfig: MerossConfig?
        /// Live garage door count once probed (nil until probed / unreachable).
        var merossDoorCount: Int?
        /// True while the Remove-garage confirmation dialog is up.
        var confirmingMerossRemove = false
        @Presents var merossSetup: MerossSetupReducer.State?

        // MARK: Smart home (Apple HomeKit, P15-C7)
        /// The app's HomeKit authorization — drives the row (Connect / denied+deep-link / Connected).
        var homekitAuth: HKAuthStatus = .notDetermined
        /// The primary Home's name once authorized (for the "Connected · {home}" line).
        var homekitHomeName: String?
        /// The accessory count once authorized.
        var homekitAccessoryCount: Int?
        /// The household's optional HomeKit config doc — its only live purpose here is the `mock` flag,
        /// which surfaces a demo-labeled, clearable row (Michael's TestFlight-11 feedback: no invisible
        /// mocks). Nil when absent (the normal live-HomeKit path).
        var homekitConfig: HomeKitConfig?
        /// True while the Clear-demo-data (HomeKit) confirmation dialog is up.
        var confirmingHomeKitRemove = false

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
        // P25 — Ideas for Bacán wishlist
        case ideasTapped
        case wishlist(PresentationAction<WishlistReducer.Action>)
        case binding(BindingAction<State>)

        // Smart home (Hue, multi-bridge)
        case hueConfigLoaded(HueConfig?)
        case hueBridgeProbed(bridgeId: String, reachable: Bool, scenes: [HueScene])
        case setupHueTapped
        case addBridgeTapped
        case rePairBridgeTapped(String)
        case removeBridgeTapped(HueBridgeConfig)
        case confirmRemoveBridge(String)
        case cancelRemoveBridge
        case removeAllHueTapped
        case confirmRemoveAllHue
        case cancelRemoveAllHue
        case hueRitualTapped(HueRitual?)
        case hueSceneChosen(ritual: HueRitual, scene: HueScene)
        case hueConfigResaved(HueConfig)
        case huePairing(PresentationAction<HuePairingReducer.Action>)

        // Smart home (Lutron shades)
        case lutronConfigLoaded(LutronConfig?)
        case lutronReachabilityProbed(Bool)
        case setupLutronTapped
        case rePairLutronTapped
        case removeLutronTapped
        case confirmRemoveLutron
        case cancelRemoveLutron
        case lutronPairing(PresentationAction<LutronPairingReducer.Action>)

        // Smart home (Nest thermostat)
        case nestConfigLoaded(NestConfig?)
        case nestThermostatsProbed(Int?)
        case setupNestTapped
        case reconnectNestTapped
        case removeNestTapped
        case confirmRemoveNest
        case cancelRemoveNest
        case nestSetup(PresentationAction<NestSetupReducer.Action>)

        // Smart home (Hubspace water timer)
        case hubspaceConfigLoaded(HubspaceConfig?)
        case hubspaceSpigotsProbed(Int?)
        case setupHubspaceTapped
        case reconnectHubspaceTapped
        case removeHubspaceTapped
        case confirmRemoveHubspace
        case cancelRemoveHubspace
        case hubspaceSetup(PresentationAction<HubspaceSetupReducer.Action>)

        // Smart home (Meross/Refoss garage opener)
        case merossConfigLoaded(MerossConfig?)
        case merossDoorsProbed(Int?)
        case setupMerossTapped
        case reconnectMerossTapped
        case removeMerossTapped
        case confirmRemoveMeross
        case cancelRemoveMeross
        case merossSetup(PresentationAction<MerossSetupReducer.Action>)

        // Smart home (Apple HomeKit)
        /// Load HomeKit auth + (if authorized) the home name/accessory count. The first live read creates
        /// `HMHomeManager` and surfaces the system permission prompt.
        case loadHomeKit
        case homekitStatusLoaded(HKAuthStatus)
        case homekitInventoryProbed(homeName: String?, count: Int?)
        /// The "Connect to HomeKit" button — (re)triggers the permission read/prompt.
        case connectHomeKitTapped
        /// The HomeKit config doc (mock flag) loaded from Firestore.
        case homekitConfigLoaded(HomeKitConfig?)
        case removeHomeKitTapped
        case confirmRemoveHomeKit
        case cancelRemoveHomeKit
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()

        // P25 — Ideas for Bacán wishlist. Kept in its own small reducer so the (already very large)
        // main switch below doesn't blow the Swift type-checker's time budget.
        Reduce { state, action in
            switch action {
            case .ideasTapped:
                state.wishlist = WishlistReducer.State()
                return .none
            case .wishlist:
                return .none
            default:
                return .none
            }
        }

        // Explicit closure signature: the main switch is large enough that letting Swift *infer*
        // the closure/return types blows the type-check time budget — spelling them out fixes it.
        Reduce { (state: inout State, action: Action) -> Effect<Action> in
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
                    // Lutron shades config (P15) — same load-then-probe pattern.
                    let lutron = try? await persistence.lutronConfig(hid)
                    await send(.lutronConfigLoaded(lutron ?? nil))
                    // Nest thermostat config (P15-C3) — load, then (if connected) probe the count.
                    let nest = try? await persistence.nestConfig(hid)
                    await send(.nestConfigLoaded(nest ?? nil))
                    // Hubspace water-timer config (P15-C4) — load, then (if connected) probe the count.
                    let hubspace = try? await persistence.hubspaceConfig(hid)
                    await send(.hubspaceConfigLoaded(hubspace ?? nil))
                    // Meross/Refoss garage config (P15-C5) — load, then (if connected) probe the count.
                    let meross = try? await persistence.merossConfig(hid)
                    await send(.merossConfigLoaded(meross ?? nil))
                    // HomeKit config (P15-C7) — only carries the `mock` flag; drives the demo-labeled row.
                    let homekit = try? await persistence.homekitConfig(hid)
                    await send(.homekitConfigLoaded(homekit ?? nil))
                }

            case let .hueConfigLoaded(config):
                state.hueConfig = config
                state.hueBridgeReachable = [:]
                state.hueScenesByBridge = [:]
                guard let config, !config.bridges.isEmpty else { return .none }
                // Probe every bridge concurrently — each row's dot resolves independently.
                return .merge(config.bridges.map { bridge in
                    .run { send in
                        @Dependency(\.hue) var hue
                        let reachable = (try? await hue.testConnection(bridge)) ?? false
                        let scenes = reachable ? ((try? await hue.scenes(bridge)) ?? []) : []
                        await send(.hueBridgeProbed(bridgeId: bridge.bridgeId, reachable: reachable, scenes: scenes))
                    }
                })

            case let .hueBridgeProbed(bridgeId, reachable, scenes):
                state.hueBridgeReachable[bridgeId] = reachable
                state.hueScenesByBridge[bridgeId] = scenes
                return .none

            case .setupHueTapped, .addBridgeTapped:
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                // Append to any existing config; first pairing starts from nil.
                state.huePairing = HuePairingReducer.State(hid: hid, existingConfig: state.hueConfig)
                return .none

            case let .rePairBridgeTapped(bridgeId):
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                state.huePairing = HuePairingReducer.State(
                    hid: hid, existingConfig: state.hueConfig, repairingBridgeId: bridgeId
                )
                return .none

            case let .removeBridgeTapped(bridge):
                state.removingBridge = bridge
                return .none

            case .cancelRemoveBridge:
                state.removingBridge = nil
                return .none

            case let .confirmRemoveBridge(bridgeId):
                state.removingBridge = nil
                guard var config = state.hueConfig else { return .none }
                // Drop the bridge AND everything scoped to it: its rituals + sensor maps.
                config.bridges.removeAll { $0.bridgeId == bridgeId }
                config.rituals.removeAll { $0.bridgeId == bridgeId }
                config.sensorLabels.removeValue(forKey: bridgeId)
                config.sensorNames?.removeValue(forKey: bridgeId)
                if config.sensorNames?.isEmpty == true { config.sensorNames = nil }
                state.hueBridgeReachable[bridgeId] = nil
                state.hueScenesByBridge[bridgeId] = nil
                @Shared(.user) var user
                guard let hid = user?.householdId else {
                    state.hueConfig = config
                    return .none
                }
                // Removing the LAST bridge clears the whole config doc (rather than persisting an empty
                // shell), returning the row to its "Set up" state.
                if config.bridges.isEmpty {
                    state.hueConfig = nil
                    return .run { _ in
                        @Dependency(\.persistence) var persistence
                        try? await persistence.deleteHueConfig(hid)
                    }
                }
                state.hueConfig = config
                return .run { [config] send in
                    @Dependency(\.persistence) var persistence
                    try? await persistence.saveHueConfig(hid, config)
                    await send(.hueConfigResaved(config))
                }

            case .removeAllHueTapped:
                state.confirmingHueRemoveAll = true
                return .none

            case .cancelRemoveAllHue:
                state.confirmingHueRemoveAll = false
                return .none

            case .confirmRemoveAllHue:
                state.confirmingHueRemoveAll = false
                state.hueConfig = nil
                state.hueBridgeReachable = [:]
                state.hueScenesByBridge = [:]
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try? await persistence.deleteHueConfig(hid)
                }

            case let .hueRitualTapped(ritual):
                state.huePickerRitual = ritual
                return .none

            case let .hueSceneChosen(ritual, scene):
                state.huePickerRitual = nil
                guard var config = state.hueConfig, let groupId = scene.groupId,
                      let i = config.rituals.firstIndex(where: { $0.key == ritual.key && $0.bridgeId == ritual.bridgeId })
                else { return .none }
                config.rituals[i] = HueRitual(
                    key: ritual.key, label: ritual.label, sceneId: scene.id, groupId: groupId, bridgeId: ritual.bridgeId
                )
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

            // MARK: Lutron shades (P15-C1)

            case let .lutronConfigLoaded(config):
                state.lutronConfig = config
                state.lutronReachable = nil
                guard let config else { return .none }
                return .run { send in
                    @Dependency(\.lutron) var lutron
                    let reachable = (try? await lutron.testConnection(config)) ?? false
                    await send(.lutronReachabilityProbed(reachable))
                }

            case let .lutronReachabilityProbed(reachable):
                state.lutronReachable = reachable
                return .none

            case .setupLutronTapped, .rePairLutronTapped:
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                state.lutronPairing = LutronPairingReducer.State(hid: hid, existingConfig: state.lutronConfig)
                return .none

            case .removeLutronTapped:
                state.confirmingLutronRemove = true
                return .none

            case .cancelRemoveLutron:
                state.confirmingLutronRemove = false
                return .none

            case .confirmRemoveLutron:
                state.confirmingLutronRemove = false
                state.lutronConfig = nil
                state.lutronReachable = nil
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try? await persistence.deleteLutronConfig(hid)
                }

            case let .lutronPairing(.presented(.delegate(.finished(config)))):
                state.lutronPairing = nil
                return .send(.lutronConfigLoaded(config))

            case .lutronPairing(.presented(.delegate(.cancelled))):
                state.lutronPairing = nil
                return .none

            case .lutronPairing:
                return .none

            // MARK: Nest thermostat (P15-C3)

            case let .nestConfigLoaded(config):
                state.nestConfig = config
                state.nestThermostatCount = nil
                guard let config, config.isConnected else { return .none }
                return .run { send in
                    @Dependency(\.nest) var nest
                    let thermostats = (try? await nest.thermostats(config)) ?? []
                    await send(.nestThermostatsProbed(thermostats.isEmpty ? nil : thermostats.count))
                }

            case let .nestThermostatsProbed(count):
                state.nestThermostatCount = count
                return .none

            case .setupNestTapped, .reconnectNestTapped:
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                state.nestSetup = NestSetupReducer.State(hid: hid, existingConfig: state.nestConfig)
                return .none

            case .removeNestTapped:
                state.confirmingNestRemove = true
                return .none

            case .cancelRemoveNest:
                state.confirmingNestRemove = false
                return .none

            case .confirmRemoveNest:
                state.confirmingNestRemove = false
                state.nestConfig = nil
                state.nestThermostatCount = nil
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try? await persistence.deleteNestConfig(hid)
                }

            case let .nestSetup(.presented(.delegate(.finished(config)))):
                state.nestSetup = nil
                return .send(.nestConfigLoaded(config))

            case .nestSetup(.presented(.delegate(.cancelled))):
                state.nestSetup = nil
                return .none

            case .nestSetup:
                return .none

            // MARK: Hubspace water timer (P15-C4)

            case let .hubspaceConfigLoaded(config):
                state.hubspaceConfig = config
                state.hubspaceSpigotCount = nil
                guard let config, config.isConnected else { return .none }
                return .run { send in
                    @Dependency(\.hubspace) var hubspace
                    let spigots = (try? await hubspace.spigots(config)) ?? []
                    await send(.hubspaceSpigotsProbed(spigots.isEmpty ? nil : spigots.count))
                }

            case let .hubspaceSpigotsProbed(count):
                state.hubspaceSpigotCount = count
                return .none

            case .setupHubspaceTapped, .reconnectHubspaceTapped:
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                state.hubspaceSetup = HubspaceSetupReducer.State(hid: hid, existingConfig: state.hubspaceConfig)
                return .none

            case .removeHubspaceTapped:
                state.confirmingHubspaceRemove = true
                return .none

            case .cancelRemoveHubspace:
                state.confirmingHubspaceRemove = false
                return .none

            case .confirmRemoveHubspace:
                state.confirmingHubspaceRemove = false
                state.hubspaceConfig = nil
                state.hubspaceSpigotCount = nil
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try? await persistence.deleteHubspaceConfig(hid)
                }

            case let .hubspaceSetup(.presented(.delegate(.finished(config)))):
                state.hubspaceSetup = nil
                return .send(.hubspaceConfigLoaded(config))

            case .hubspaceSetup(.presented(.delegate(.cancelled))):
                state.hubspaceSetup = nil
                return .none

            case .hubspaceSetup:
                return .none

            // MARK: Meross/Refoss garage opener (P15-C5)

            case let .merossConfigLoaded(config):
                state.merossConfig = config
                state.merossDoorCount = nil
                guard let config, config.isConnected else { return .none }
                return .run { send in
                    @Dependency(\.meross) var meross
                    let doors = (try? await meross.garageState(config)) ?? []
                    await send(.merossDoorsProbed(doors.isEmpty ? nil : doors.count))
                }

            case let .merossDoorsProbed(count):
                state.merossDoorCount = count
                return .none

            case .setupMerossTapped, .reconnectMerossTapped:
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                state.merossSetup = MerossSetupReducer.State(hid: hid, existingConfig: state.merossConfig)
                return .none

            case .removeMerossTapped:
                state.confirmingMerossRemove = true
                return .none

            case .cancelRemoveMeross:
                state.confirmingMerossRemove = false
                return .none

            case .confirmRemoveMeross:
                state.confirmingMerossRemove = false
                state.merossConfig = nil
                state.merossDoorCount = nil
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try? await persistence.deleteMerossConfig(hid)
                }

            case let .merossSetup(.presented(.delegate(.finished(config)))):
                state.merossSetup = nil
                return .send(.merossConfigLoaded(config))

            case .merossSetup(.presented(.delegate(.cancelled))):
                state.merossSetup = nil
                return .none

            case .merossSetup:
                return .none

            // MARK: Apple HomeKit (P15-C7)

            case .loadHomeKit:
                return .run { send in
                    @Dependency(\.homekit) var homekit
                    let status = await homekit.authorizationStatus()
                    await send(.homekitStatusLoaded(status))
                    guard status == .authorized else { return }
                    let inventory = await homekit.inventory(nil)
                    await send(.homekitInventoryProbed(homeName: inventory.homeName, count: inventory.accessories.count))
                }

            case let .homekitStatusLoaded(status):
                state.homekitAuth = status
                return .none

            case let .homekitInventoryProbed(homeName, count):
                state.homekitHomeName = homeName
                state.homekitAccessoryCount = count
                return .none

            case .connectHomeKitTapped:
                return .send(.loadHomeKit)

            case let .homekitConfigLoaded(config):
                state.homekitConfig = config
                return .none

            case .removeHomeKitTapped:
                state.confirmingHomeKitRemove = true
                return .none

            case .cancelRemoveHomeKit:
                state.confirmingHomeKitRemove = false
                return .none

            case .confirmRemoveHomeKit:
                state.confirmingHomeKitRemove = false
                state.homekitConfig = nil
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try? await persistence.deleteHomeKitConfig(hid)
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

            // P25 wishlist actions are handled in the dedicated Reduce above; default keeps this
            // (already very large) switch within the compiler's type-check budget.
            default:
                return .none
            }
        }
        .ifLet(\.$profileEdit, action: \.profileEdit) {
            ProfileEditReducer()
        }
        .ifLet(\.$wishlist, action: \.wishlist) {
            WishlistReducer()
        }
        .ifLet(\.$huePairing, action: \.huePairing) {
            HuePairingReducer()
        }
        .ifLet(\.$lutronPairing, action: \.lutronPairing) {
            LutronPairingReducer()
        }
        .ifLet(\.$nestSetup, action: \.nestSetup) {
            NestSetupReducer()
        }
        .ifLet(\.$hubspaceSetup, action: \.hubspaceSetup) {
            HubspaceSetupReducer()
        }
        .ifLet(\.$merossSetup, action: \.merossSetup) {
            MerossSetupReducer()
        }
    }
}

public struct SettingsView: View {
    @Bindable var store: StoreOf<SettingsReducer>

    /// Deep-links to the Settings app when HomeKit access was denied.
    @Environment(\.openURL) private var openURL

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

            // P25 — Ideas for Bacán: always-discoverable wishlist capture.
            Section {
                Button {
                    store.send(.ideasTapped)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(Color.marigold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ideas for Bacán").foregroundStyle(Color.ink)
                            Text("Got an idea? We're all ears.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("ideas-for-bacan-row")
            }

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
        .sheet(item: $store.scope(state: \.wishlist, action: \.wishlist)) { wishlistStore in
            WishlistView(store: wishlistStore)
        }
        .sheet(item: $store.scope(state: \.huePairing, action: \.huePairing)) { pairingStore in
            HuePairingView(store: pairingStore)
        }
        .modifier(LutronSettingsPresentations(store: store))
        .modifier(NestSettingsPresentations(store: store))
        .modifier(HubspaceSettingsPresentations(store: store))
        .modifier(MerossSettingsPresentations(store: store))
        .modifier(HueRemoveAllPresentation(store: store))
        .modifier(HomeKitRemovePresentation(store: store))
        .sheet(isPresented: Binding(
            get: { store.huePickerRitual != nil },
            set: { if !$0 { store.send(.hueRitualTapped(nil)) } }
        )) {
            hueScenePicker
        }
        .confirmationDialog(
            "Remove this bridge?",
            isPresented: Binding(
                get: { store.removingBridge != nil },
                set: { if !$0 { store.send(.cancelRemoveBridge) } }
            ),
            titleVisibility: .visible,
            presenting: store.removingBridge
        ) { bridge in
            Button(bridge.isMock ? "Clear demo data" : "Remove \(bridge.displayName)", role: .destructive) {
                store.send(.confirmRemoveBridge(bridge.bridgeId))
            }
            Button("Cancel", role: .cancel) { store.send(.cancelRemoveBridge) }
        } message: { _ in
            Text("Bacán forgets this bridge — its rituals and room thermometers go with it. Your other bridges and your actual Hue lights are untouched.")
        }
        .task { store.send(.task) }
        // HomeKit (P15-C7) loads on appear from the VIEW (not the `.task` reducer action) so it reflects
        // true authorization on every open — the first live read surfaces the system permission prompt.
        .task { store.send(.loadHomeKit) }
    }

    // MARK: - Smart home (P15-C8b — split into two cards)
    //
    // Two grouped cards so Hue no longer "bleeds" into the other integrations (Michael's screenshot
    // feedback): "Philips Hue" owns the bridge list, Add-a-bridge, the (Hue-scoped) rituals and the
    // Remove/Clear action; "More devices" carries one row per other integration. Layout only — every
    // action / accessibility id below is unchanged.

    @ViewBuilder
    private var smartHomeSection: some View {
        hueSection
        moreDevicesSection
    }

    /// The Philips Hue card: bridge list, Add a bridge, the Hue-scoped rituals (in their own labelled
    /// subsection), and the Remove-all / Clear-demo action. Its "Set up" state when never paired.
    @ViewBuilder
    private var hueSection: some View {
        Section {
            if let config = store.hueConfig, !config.bridges.isEmpty {
                ForEach(config.bridges) { bridge in
                    hueBridgeRow(bridge)
                }
                Button {
                    store.send(.addBridgeTapped)
                } label: {
                    Label("Add a bridge", systemImage: "plus.circle")
                        .foregroundStyle(Color.ink)
                }
                .accessibilityIdentifier("hue-add-bridge-row")
                // Rituals are Hue-scoped — set them apart with a small subsection divider row so they
                // read as "these belong to Hue" rather than free-floating in the card.
                Text("RITUALS")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.inkSoft)
                    .accessibilityIdentifier("hue-rituals-subheader")
                ForEach(hueRitualStates(config), id: \.id) { ritual in
                    hueRitualRow(ritual, showBridge: config.bridges.count > 1)
                }
                Button(role: .destructive) {
                    store.send(.removeAllHueTapped)
                } label: {
                    Label(config.isMock ? "Clear demo data" : "Remove all Hue", systemImage: "trash")
                        .foregroundStyle(Color.terracotta)
                }
                .accessibilityIdentifier("hue-remove-all-row")
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
            Text("Philips Hue").foregroundStyle(Color.inkSoft)
        } footer: {
            if store.hueConfig?.bridges.isEmpty ?? true {
                Text("Pair your Hue bridge to light up the house from Today.")
            }
        }
    }

    /// The "More devices" card: one row each for the non-Hue integrations, each rendering its own
    /// status / set-up state exactly as before.
    @ViewBuilder
    private var moreDevicesSection: some View {
        Section {
            // Lutron shades (P15-C1).
            lutronRow
            // Nest thermostat (P15-C3).
            nestRow
            // Hubspace water timer (P15-C4).
            hubspaceRow
            // Meross/Refoss garage opener (P15-C5).
            merossRow
            // Apple HomeKit (P15-C7) — local, keyless; pairing lives in Apple's Home app.
            homekitRow
        } header: {
            Text("More devices").foregroundStyle(Color.inkSoft)
        }
    }

    /// The Lutron shades row: paired → status + reachability dot with a Re-pair swipe action;
    /// unpaired → "Set up Lutron shades".
    @ViewBuilder
    private var lutronRow: some View {
        if let config = store.lutronConfig {
            HStack(spacing: 12) {
                Image(systemName: "blinds.horizontal.closed")
                    .foregroundStyle(Color.bacanGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.displayName).foregroundStyle(Color.ink)
                    Text("Lutron shades").font(.caption).foregroundStyle(Color.inkSoft)
                    if config.isMock { demoDataTag }
                }
                Spacer()
                lutronReachabilityDot
            }
            .accessibilityIdentifier("lutron-bridge-row")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    store.send(.removeLutronTapped)
                } label: {
                    Label(config.isMock ? "Clear demo data" : "Remove", systemImage: "trash")
                }
                Button {
                    store.send(.rePairLutronTapped)
                } label: {
                    Label("Re-pair", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(Color.bacanGreen)
            }
            .contextMenu {
                Button { store.send(.rePairLutronTapped) } label: {
                    Label("Re-pair", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) { store.send(.removeLutronTapped) } label: {
                    Label(config.isMock ? "Clear demo data" : "Remove", systemImage: "trash")
                }
            }
        } else {
            Button {
                store.send(.setupLutronTapped)
            } label: {
                Label("Set up Lutron shades", systemImage: "blinds.horizontal.closed")
                    .foregroundStyle(Color.ink)
            }
            .accessibilityIdentifier("lutron-setup-row")
        }
    }

    /// The explicit "(demo data)" marker rendered under any row whose config carries `mock == true`.
    /// Michael's TestFlight-11 feedback: no invisible mocks — a demo config must always announce itself.
    private var demoDataTag: some View {
        Text("(demo data)")
            .font(.caption2)
            .foregroundStyle(Color.inkSoft)
            .accessibilityIdentifier("demo-data-tag")
    }

    @ViewBuilder
    private var lutronReachabilityDot: some View {
        switch store.lutronReachable {
        case .some(true):
            HStack(spacing: 6) {
                Circle().fill(Color.bacanGreen).frame(width: 8, height: 8)
                Text("Reachable").font(.caption).foregroundStyle(Color.inkSoft)
            }
        case .some(false):
            HStack(spacing: 6) {
                Circle().fill(Color.inkSoft).frame(width: 8, height: 8)
                Text("Unreachable").font(.caption).foregroundStyle(Color.inkSoft)
            }
        case .none:
            ProgressView().controlSize(.mini)
        }
    }

    /// The Nest thermostat row (P15-C3): connected → status + thermostat count with Reconnect/Remove
    /// swipe actions; not set up → "Set up Nest".
    @ViewBuilder
    private var nestRow: some View {
        if let config = store.nestConfig, config.isConnected {
            HStack(spacing: 12) {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(Color.bacanGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nest thermostat").foregroundStyle(Color.ink)
                    Text(nestStatusLine).font(.caption).foregroundStyle(Color.inkSoft)
                    if config.isMock { demoDataTag }
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.bacanGreen).frame(width: 8, height: 8)
                    Text("Connected").font(.caption).foregroundStyle(Color.inkSoft)
                }
            }
            .accessibilityIdentifier("nest-status-row")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    store.send(.removeNestTapped)
                } label: {
                    Label(config.isMock ? "Clear demo data" : "Remove", systemImage: "trash")
                }
                Button {
                    store.send(.reconnectNestTapped)
                } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(Color.bacanGreen)
            }
            .contextMenu {
                Button { store.send(.reconnectNestTapped) } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) { store.send(.removeNestTapped) } label: {
                    Label(config.isMock ? "Clear demo data" : "Remove", systemImage: "trash")
                }
            }
        } else {
            Button {
                store.send(.setupNestTapped)
            } label: {
                Label("Set up Nest", systemImage: "thermometer.medium")
                    .foregroundStyle(Color.ink)
            }
            .accessibilityIdentifier("nest-setup-row")
        }
    }

    /// The Nest status subtitle: the thermostat count once fetched, else a neutral "Connected".
    private var nestStatusLine: String {
        switch store.nestThermostatCount {
        case let .some(count):
            return "\(count) thermostat\(count == 1 ? "" : "s")"
        case .none:
            return "Connected"
        }
    }

    /// The Hubspace water-timer row (P15-C4): connected → "Connected · {email}" (+ spigot count) with
    /// Reconnect/Remove actions; not set up → "Set up Hubspace (spigot)".
    @ViewBuilder
    private var hubspaceRow: some View {
        if let config = store.hubspaceConfig, config.isConnected {
            HStack(spacing: 12) {
                Image(systemName: "drop.fill")
                    .foregroundStyle(Color.bacanGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hubspace spigot").foregroundStyle(Color.ink)
                    Text(hubspaceStatusLine).font(.caption).foregroundStyle(Color.inkSoft)
                    if config.isMock { demoDataTag }
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.bacanGreen).frame(width: 8, height: 8)
                    Text("Connected").font(.caption).foregroundStyle(Color.inkSoft)
                }
            }
            .accessibilityIdentifier("hubspace-status-row")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    store.send(.removeHubspaceTapped)
                } label: {
                    Label(config.isMock ? "Clear demo data" : "Remove", systemImage: "trash")
                }
                Button {
                    store.send(.reconnectHubspaceTapped)
                } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(Color.bacanGreen)
            }
            .contextMenu {
                Button { store.send(.reconnectHubspaceTapped) } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) { store.send(.removeHubspaceTapped) } label: {
                    Label(config.isMock ? "Clear demo data" : "Remove", systemImage: "trash")
                }
            }
        } else {
            Button {
                store.send(.setupHubspaceTapped)
            } label: {
                Label("Set up Hubspace (spigot)", systemImage: "drop")
                    .foregroundStyle(Color.ink)
            }
            .accessibilityIdentifier("hubspace-setup-row")
        }
    }

    /// The Hubspace status subtitle: "Connected · {email}", plus the spigot count once fetched.
    private var hubspaceStatusLine: String {
        let email = store.hubspaceConfig?.email
        let base = email.map { "Connected · \($0)" } ?? "Connected"
        if let count = store.hubspaceSpigotCount {
            return "\(base) · \(count) spigot\(count == 1 ? "" : "s")"
        }
        return base
    }

    /// The Meross/Refoss garage row (P15-C5): connected → "Connected · {name}" (+ door count) with
    /// Reconnect/Remove actions; not set up → "Set up garage (Refoss)".
    @ViewBuilder
    private var merossRow: some View {
        if let config = store.merossConfig, config.isConnected {
            HStack(spacing: 12) {
                Image(systemName: "door.garage.closed")
                    .foregroundStyle(Color.bacanGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Garage (Refoss)").foregroundStyle(Color.ink)
                    Text(merossStatusLine).font(.caption).foregroundStyle(Color.inkSoft)
                    if config.isMock { demoDataTag }
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.bacanGreen).frame(width: 8, height: 8)
                    Text("Connected").font(.caption).foregroundStyle(Color.inkSoft)
                }
            }
            .accessibilityIdentifier("meross-status-row")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    store.send(.removeMerossTapped)
                } label: {
                    Label(config.isMock ? "Clear demo data" : "Remove", systemImage: "trash")
                }
                Button {
                    store.send(.reconnectMerossTapped)
                } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(Color.bacanGreen)
            }
            .contextMenu {
                Button { store.send(.reconnectMerossTapped) } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(role: .destructive) { store.send(.removeMerossTapped) } label: {
                    Label(config.isMock ? "Clear demo data" : "Remove", systemImage: "trash")
                }
            }
        } else {
            Button {
                store.send(.setupMerossTapped)
            } label: {
                Label("Set up garage (Refoss)", systemImage: "door.garage.closed")
                    .foregroundStyle(Color.ink)
            }
            .accessibilityIdentifier("meross-setup-row")
        }
    }

    /// The HomeKit row (P15-C7): not-determined → "Connect to HomeKit"; denied/restricted → explain +
    /// deep-link to the Settings app; authorized → "Connected · {home} · N accessories". There is NO
    /// pairing flow — HomeKit pairing lives in Apple's Home app.
    @ViewBuilder
    private var homekitRow: some View {
        // A mock config doc overrides the live auth path entirely — it exists only to carry the demo
        // Home, so it presents as a demo-labeled, clearable "Connected" row (no invisible mocks).
        if store.homekitConfig?.isMock == true {
            HStack(spacing: 12) {
                Image(systemName: "homekit")
                    .foregroundStyle(Color.bacanGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple HomeKit").foregroundStyle(Color.ink)
                    Text("Connected").font(.caption).foregroundStyle(Color.inkSoft)
                    demoDataTag
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.bacanGreen).frame(width: 8, height: 8)
                    Text("Connected").font(.caption).foregroundStyle(Color.inkSoft)
                }
            }
            .accessibilityIdentifier("homekit-status-row")
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    store.send(.removeHomeKitTapped)
                } label: {
                    Label("Clear demo data", systemImage: "trash")
                }
            }
            .contextMenu {
                Button(role: .destructive) { store.send(.removeHomeKitTapped) } label: {
                    Label("Clear demo data", systemImage: "trash")
                }
            }
        } else {
            liveHomeKitRow
        }
    }

    @ViewBuilder
    private var liveHomeKitRow: some View {
        switch store.homekitAuth {
        case .authorized:
            HStack(spacing: 12) {
                Image(systemName: "homekit")
                    .foregroundStyle(Color.bacanGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple HomeKit").foregroundStyle(Color.ink)
                    Text(homekitStatusLine).font(.caption).foregroundStyle(Color.inkSoft)
                    Text("Pair new accessories in Apple's Home app — they show up here.")
                        .font(.caption2).foregroundStyle(Color.inkSoft)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.bacanGreen).frame(width: 8, height: 8)
                    Text("Connected").font(.caption).foregroundStyle(Color.inkSoft)
                }
            }
            .accessibilityIdentifier("homekit-status-row")
        case .denied, .restricted:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "homekit").foregroundStyle(Color.terracotta)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HomeKit access is off").foregroundStyle(Color.ink)
                        Text("Turn on HomeKit for Bacán in Settings to control your Home.")
                            .font(.caption).foregroundStyle(Color.inkSoft)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square").foregroundStyle(Color.inkSoft)
                }
            }
            .accessibilityIdentifier("homekit-denied-row")
        case .notDetermined:
            Button {
                store.send(.connectHomeKitTapped)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Connect to HomeKit", systemImage: "homekit")
                        .foregroundStyle(Color.ink)
                    Text("Pair new accessories in Apple's Home app — they show up here.")
                        .font(.caption2).foregroundStyle(Color.inkSoft)
                }
            }
            .accessibilityIdentifier("homekit-connect-row")
        }
    }

    /// The HomeKit status subtitle: "Connected · {home}", plus the accessory count once probed.
    private var homekitStatusLine: String {
        let base = store.homekitHomeName.map { "Connected · \($0)" } ?? "Connected"
        if let count = store.homekitAccessoryCount {
            return "\(base) · \(count) accessor\(count == 1 ? "y" : "ies")"
        }
        return base
    }

    /// The Meross status subtitle: "Connected · {name}", plus the door count once fetched.
    private var merossStatusLine: String {
        let name = store.merossConfig?.name
        let base = name.map { "Connected · \($0)" } ?? "Connected"
        if let count = store.merossDoorCount {
            return "\(base) · \(count) door\(count == 1 ? "" : "s")"
        }
        return base
    }

    /// One bridge row: name (+ id) + reachability dot, with swipe/context Re-pair + Remove actions.
    private func hueBridgeRow(_ bridge: HueBridgeConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.router")
                .foregroundStyle(Color.bacanGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(bridge.displayName).foregroundStyle(Color.ink)
                Text(bridge.bridgeId).font(.caption).foregroundStyle(Color.inkSoft)
                if bridge.isMock { demoDataTag }
            }
            Spacer()
            hueReachabilityDot(bridge.bridgeId)
        }
        .accessibilityIdentifier("hue-bridge-row-\(bridge.bridgeId)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.send(.removeBridgeTapped(bridge))
            } label: {
                Label(bridge.isMock ? "Clear demo data" : "Remove", systemImage: "trash")
            }
            Button {
                store.send(.rePairBridgeTapped(bridge.bridgeId))
            } label: {
                Label("Re-pair", systemImage: "arrow.triangle.2.circlepath")
            }
            .tint(Color.bacanGreen)
        }
        .contextMenu {
            Button { store.send(.rePairBridgeTapped(bridge.bridgeId)) } label: {
                Label("Re-pair", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive) { store.send(.removeBridgeTapped(bridge)) } label: {
                Label(bridge.isMock ? "Clear demo data" : "Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func hueReachabilityDot(_ bridgeId: String) -> some View {
        switch store.hueBridgeReachable[bridgeId] {
        case .some(true):
            HStack(spacing: 6) {
                Circle().fill(Color.bacanGreen).frame(width: 8, height: 8)
                Text("Reachable").font(.caption).foregroundStyle(Color.inkSoft)
            }
        case .some(false):
            HStack(spacing: 6) {
                Circle().fill(Color.inkSoft).frame(width: 8, height: 8)
                Text("Unreachable").font(.caption).foregroundStyle(Color.inkSoft)
            }
        case .none:
            ProgressView().controlSize(.mini)
        }
    }

    private func hueRitualRow(_ ritual: HueRitualStatus, showBridge: Bool) -> some View {
        let scenes = ritual.bridgeId.map { store.hueScenesByBridge[$0] ?? [] } ?? []
        return Button {
            if let bound = ritual.ritual { store.send(.hueRitualTapped(bound)) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ritual.label).foregroundStyle(Color.ink)
                    if let sceneName = ritual.sceneName {
                        Text(showBridge ? "→ \(sceneName) · \(ritual.bridgeName ?? "")" : "→ \(sceneName)")
                            .font(.caption).foregroundStyle(Color.inkSoft)
                    } else {
                        Text("needs a scene — pair a bridge").font(.caption).foregroundStyle(Color.terracotta)
                    }
                }
                Spacer()
                if ritual.ritual != nil, !scenes.isEmpty {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        // Only bound rituals on a reachable bridge (scenes loaded) can be rebound here.
        .disabled(ritual.ritual == nil || scenes.isEmpty)
        .accessibilityIdentifier("hue-ritual-row-\(ritual.key)")
    }

    private var hueScenePicker: some View {
        let ritual = store.huePickerRitual
        let scenes = ritual.map { store.hueScenesByBridge[$0.bridgeId] ?? [] } ?? []
        return NavigationStack {
            List {
                ForEach(scenes) { scene in
                    Button {
                        if let ritual { store.send(.hueSceneChosen(ritual: ritual, scene: scene)) }
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

    /// One ritual's display state on the settings list.
    private struct HueRitualStatus: Equatable {
        let key: String
        let label: String
        /// The bound ritual (nil → unbound / "needs a scene"). Carries its bridgeId for the picker.
        let ritual: HueRitual?
        /// The live scene name when bound + resolvable; nil → "needs a scene".
        let sceneName: String?
        /// The owning bridge id (bound rituals only).
        var bridgeId: String? { ritual?.bridgeId }
        /// The owning bridge's display name (for the ">1 bridge" annotation).
        let bridgeName: String?
        var id: String { ritual?.id ?? key }
    }

    /// The rituals to list under a paired config: the two standards, unioned with any extra rituals
    /// the config carries, each resolved to its live scene name + owning bridge when bound.
    private func hueRitualStates(_ config: HueConfig) -> [HueRitualStatus] {
        var keys: [(key: String, label: String)] = HueBindingMatch.standardRituals
        for ritual in config.rituals where !keys.contains(where: { $0.key == ritual.key }) {
            keys.append((ritual.key, ritual.label))
        }
        return keys.map { entry in
            if let bound = config.rituals.first(where: { $0.key == entry.key }) {
                let name = (store.hueScenesByBridge[bound.bridgeId] ?? []).first(where: { $0.id == bound.sceneId })?.name
                let bridgeName = config.bridge(bound.bridgeId)?.displayName
                return HueRitualStatus(
                    key: entry.key, label: bound.label, ritual: bound,
                    sceneName: name ?? "scene set", bridgeName: bridgeName
                )
            } else {
                return HueRitualStatus(key: entry.key, label: entry.label, ritual: nil, sceneName: nil, bridgeName: nil)
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

/// The Nest setup sheet + Remove confirmation, bundled into a modifier so they don't deepen the main
/// `body` modifier chain (which the type-checker was struggling to solve within its budget).
private struct NestSettingsPresentations: ViewModifier {
    @Bindable var store: StoreOf<SettingsReducer>

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.scope(state: \.nestSetup, action: \.nestSetup)) { setupStore in
                NestSetupView(store: setupStore)
            }
            .confirmationDialog(
                store.nestConfig?.isMock == true ? "Clear demo data?" : "Remove Nest?",
                isPresented: Binding(
                    get: { store.confirmingNestRemove },
                    set: { if !$0 { store.send(.cancelRemoveNest) } }
                ),
                titleVisibility: .visible
            ) {
                Button(store.nestConfig?.isMock == true ? "Clear demo data" : "Remove Nest", role: .destructive) {
                    store.send(.confirmRemoveNest)
                }
                Button("Cancel", role: .cancel) { store.send(.cancelRemoveNest) }
            } message: {
                Text("The thermostat drops off the house screen. Your Google registration stays put — reconnect any time.")
            }
    }
}

/// The Hubspace setup sheet + Remove confirmation, bundled into a modifier so they don't deepen the main
/// `body` modifier chain (the type-checker's budget again).
private struct HubspaceSettingsPresentations: ViewModifier {
    @Bindable var store: StoreOf<SettingsReducer>

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.scope(state: \.hubspaceSetup, action: \.hubspaceSetup)) { setupStore in
                HubspaceSetupView(store: setupStore)
            }
            .confirmationDialog(
                store.hubspaceConfig?.isMock == true ? "Clear demo data?" : "Remove Hubspace?",
                isPresented: Binding(
                    get: { store.confirmingHubspaceRemove },
                    set: { if !$0 { store.send(.cancelRemoveHubspace) } }
                ),
                titleVisibility: .visible
            ) {
                Button(store.hubspaceConfig?.isMock == true ? "Clear demo data" : "Remove Hubspace", role: .destructive) {
                    store.send(.confirmRemoveHubspace)
                }
                Button("Cancel", role: .cancel) { store.send(.cancelRemoveHubspace) }
            } message: {
                Text("The spigot drops off the house screen. Sign in again any time to reconnect.")
            }
    }
}

/// The Meross/Refoss garage setup sheet + Remove confirmation, bundled into a modifier so they don't
/// deepen the main `body` modifier chain (the type-checker's budget again).
private struct MerossSettingsPresentations: ViewModifier {
    @Bindable var store: StoreOf<SettingsReducer>

    func body(content: Content) -> some View {
        content
            .sheet(item: $store.scope(state: \.merossSetup, action: \.merossSetup)) { setupStore in
                MerossSetupView(store: setupStore)
            }
            .confirmationDialog(
                store.merossConfig?.isMock == true ? "Clear demo data?" : "Remove garage?",
                isPresented: Binding(
                    get: { store.confirmingMerossRemove },
                    set: { if !$0 { store.send(.cancelRemoveMeross) } }
                ),
                titleVisibility: .visible
            ) {
                Button(store.merossConfig?.isMock == true ? "Clear demo data" : "Remove garage", role: .destructive) {
                    store.send(.confirmRemoveMeross)
                }
                Button("Cancel", role: .cancel) { store.send(.cancelRemoveMeross) }
            } message: {
                Text("The garage drops off the house screen. Set it up again any time.")
            }
    }
}

/// The Lutron shades setup sheet + Remove confirmation, bundled into a modifier (P15-C8) so they don't
/// deepen the main `body` modifier chain (the type-checker's budget).
private struct LutronSettingsPresentations: ViewModifier {
    @Bindable var store: StoreOf<SettingsReducer>

    func body(content: Content) -> some View {
        let isMock = store.lutronConfig?.isMock == true
        return content
            .sheet(item: $store.scope(state: \.lutronPairing, action: \.lutronPairing)) { pairingStore in
                LutronPairingView(store: pairingStore)
            }
            .confirmationDialog(
                isMock ? "Clear demo data?" : "Remove Lutron shades?",
                isPresented: Binding(
                    get: { store.confirmingLutronRemove },
                    set: { if !$0 { store.send(.cancelRemoveLutron) } }
                ),
                titleVisibility: .visible
            ) {
                Button(isMock ? "Clear demo data" : "Remove", role: .destructive) {
                    store.send(.confirmRemoveLutron)
                }
                Button("Cancel", role: .cancel) { store.send(.cancelRemoveLutron) }
            } message: {
                Text("Bacán forgets this bridge; your shades are untouched. Pair again any time.")
            }
    }
}

/// The "Remove all Hue" confirmation (P15-C8) — forgets every paired bridge and all rituals at once.
private struct HueRemoveAllPresentation: ViewModifier {
    @Bindable var store: StoreOf<SettingsReducer>

    func body(content: Content) -> some View {
        let isMock = store.hueConfig?.isMock == true
        return content
            .confirmationDialog(
                isMock ? "Clear demo data?" : "Remove all Hue bridges?",
                isPresented: Binding(
                    get: { store.confirmingHueRemoveAll },
                    set: { if !$0 { store.send(.cancelRemoveAllHue) } }
                ),
                titleVisibility: .visible
            ) {
                Button(isMock ? "Clear demo data" : "Remove everything", role: .destructive) {
                    store.send(.confirmRemoveAllHue)
                }
                Button("Cancel", role: .cancel) { store.send(.cancelRemoveAllHue) }
            } message: {
                Text("Bacán forgets ALL your bridges and every ritual (Bedtime, Dinner…). Your actual Hue lights are untouched — you can pair again any time.")
            }
    }
}

/// The HomeKit "Clear demo data" confirmation (P15-C8) — deletes the mock config doc. The live local
/// Home is never stored here, so it's untouched.
private struct HomeKitRemovePresentation: ViewModifier {
    @Bindable var store: StoreOf<SettingsReducer>

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Clear demo data?",
                isPresented: Binding(
                    get: { store.confirmingHomeKitRemove },
                    set: { if !$0 { store.send(.cancelRemoveHomeKit) } }
                ),
                titleVisibility: .visible
            ) {
                Button("Clear demo data", role: .destructive) { store.send(.confirmRemoveHomeKit) }
                Button("Cancel", role: .cancel) { store.send(.cancelRemoveHomeKit) }
            } message: {
                Text("Removes the demo HomeKit devices. Your real Home in Apple's Home app is untouched.")
            }
    }
}
