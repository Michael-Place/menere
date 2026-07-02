import ComposableArchitecture
import FamilyDomain
import Foundation
import HueClient
import LutronClient
import NestClient
import SonosClient

/// The granular House control surface (P12-C4) — the SUBSTRATE future family experiences (and the
/// planned P14 agent tools) compose on. Where the Today "house" card is a read-only summary + ritual
/// buttons, this reducer drives full per-room / per-light control: power toggles, brightness sliders,
/// and scene recall, multi-bridge, with `roomOwners` avatars.
///
/// **Optimistic everywhere, degrade silently.** Every write flips local state immediately; on failure
/// the effect quietly re-reads truth (`.refresh`) instead of surfacing an error — the same
/// degrade-silently contract as the card. Sliders **debounce** their PUTs (≥150ms of quiescence)
/// because Hue bridges dislike >10 req/s; the debounce is a `continuousClock` sleep guarded by a
/// per-target `cancellable(cancelInFlight:)`.
///
/// The reducer is intentionally decoupled from `TodayReducer`: `HouseView` owns its own store, seeded
/// from the already-loaded snapshot. The control verbs it calls (`hue.setGroupState` /
/// `hue.setLightState` / `hue.recallScene`) are the same ones the P14 agent harness will wrap.
@Reducer
public struct HouseReducer {
    @ObservableState
    public struct State: Equatable {
        /// Identity + mappings (bridges, roomOwners). Stable for the screen's lifetime.
        public var config: HueConfig
        /// Roster, for resolving a room owner's member color dot.
        public var members: [HouseholdMember]
        /// Live per-bridge state, mutated optimistically and re-synced on refresh. Only reachable
        /// bridges appear (sorted by bridge id).
        public var bridges: [BridgeSnapshot]
        public var isRefreshing = false
        /// The scene id whose recall just succeeded — drives the room-detail success haptic.
        public var recalledScene: String?

        // MARK: Lutron shades (P15-C1)
        /// The household's Lutron config (nil = no shades). Stable for the screen's lifetime.
        public var lutronConfig: LutronConfig?
        /// Live shade state, mutated optimistically and re-synced on refresh. Loaded on `.task`.
        public var shades: [LutronShade] = []

        // MARK: Sonos speakers (P15-C2)
        /// The household's OPTIONAL Sonos config (nil still discovers live — Sonos needs no pairing).
        /// Stable for the screen's lifetime; only forces the mock or carries a cosmetic room order.
        public var sonosConfig: SonosConfig?
        /// Live Sonos state, one row per group (coordinator), with now-playing + volume. Mutated
        /// optimistically and re-synced on refresh. Discovered on `.task`; empty = no speakers / not home.
        public var sonosGroups: [SonosGroup] = []

        // MARK: Nest thermostat (P15-C3)
        /// The household's Nest config (nil = not set up). Stable for the screen's lifetime.
        public var nestConfig: NestConfig?
        /// Live thermostat state, mutated optimistically and re-synced on refresh. Loaded on `.task`;
        /// empty = not set up / unreachable (silent degrade).
        public var thermostats: [NestThermostat] = []

        public init(
            config: HueConfig, members: [HouseholdMember] = [], bridges: [BridgeSnapshot] = [],
            lutronConfig: LutronConfig? = nil, shades: [LutronShade] = [],
            sonosConfig: SonosConfig? = nil, sonosGroups: [SonosGroup] = [],
            nestConfig: NestConfig? = nil, thermostats: [NestThermostat] = []
        ) {
            self.config = config
            self.members = members
            self.bridges = bridges
            self.lutronConfig = lutronConfig
            self.shades = shades
            self.sonosConfig = sonosConfig
            self.sonosGroups = sonosGroups
            self.nestConfig = nestConfig
            self.thermostats = thermostats
        }

        /// Shades grouped by area/room name, each group's shades sorted by name — the House "Shades"
        /// sections. Areas are alphabetical for a stable layout.
        public var shadesByArea: [(area: String, shades: [LutronShade])] {
            Dictionary(grouping: shades, by: \.areaName)
                .map { (area: $0.key, shades: $0.value.sorted { $0.name < $1.name }) }
                .sorted { $0.area < $1.area }
        }

        /// True once more than one bridge is reachable — the view then groups sections by bridge name.
        public var isMultiBridge: Bool { bridges.count > 1 }

        /// The member who "owns" a group id (via `roomOwners`), if mapped and still in the roster.
        public func owner(ofRoom roomId: String) -> HouseholdMember? {
            guard let uid = config.roomOwners?[roomId] else { return nil }
            return members.first { $0.id == uid }
        }

        /// A bridge snapshot by id.
        public func snapshot(_ bridgeId: String) -> BridgeSnapshot? {
            bridges.first { $0.bridge.bridgeId == bridgeId }
        }

        /// A room within a bridge (live, so it reflects optimistic edits).
        public func room(bridgeId: String, roomId: String) -> HueRoom? {
            snapshot(bridgeId)?.rooms.first { $0.id == roomId }
        }

        /// A room's member lights, in the bridge's sorted order.
        public func lights(inRoom roomId: String, bridgeId: String) -> [HueLight] {
            guard let snap = snapshot(bridgeId), let room = snap.rooms.first(where: { $0.id == roomId }) else { return [] }
            let ids = Set(room.lightIds)
            return snap.lights.filter { ids.contains($0.id) }
        }

        /// Group scenes targeting a room (matched on the scene's `groupId`), by name.
        public func scenes(forRoom roomId: String, bridgeId: String) -> [HueScene] {
            (snapshot(bridgeId)?.scenes ?? [])
                .filter { $0.groupId == roomId }
                .sorted { $0.name < $1.name }
        }
    }

    public enum Action: Equatable {
        case task
        case refresh
        case houseReloaded([BridgeSnapshot])
        case toggleRoom(bridgeId: String, roomId: String)
        case toggleLight(bridgeId: String, lightId: String)
        /// Slider moved (0–100%). Updates optimistically + schedules a debounced commit.
        case roomBrightnessChanged(bridgeId: String, roomId: String, percent: Double)
        case lightBrightnessChanged(bridgeId: String, lightId: String, percent: Double)
        /// The debounced write, fired only after ≥150ms of slider quiescence.
        case commitRoomBrightness(bridgeId: String, roomId: String, bri: Int)
        case commitLightBrightness(bridgeId: String, lightId: String, bri: Int)
        case recallScene(bridgeId: String, groupId: String, sceneId: String)
        case sceneRecalled(sceneId: String)
        case clearSceneSuccess(sceneId: String)

        // Lutron shades (P15-C1)
        case shadesReloaded([LutronShade])
        /// Shade slider moved (0–100). Optimistic + debounced commit.
        case shadeLevelChanged(zoneId: String, level: Int)
        case commitShadeLevel(zoneId: String, level: Int)
        case raiseShade(zoneId: String)
        case lowerShade(zoneId: String)
        case stopShade(zoneId: String)

        // Sonos speakers (P15-C2)
        case sonosReloaded([SonosGroup])
        /// Play/pause the group's coordinator (optimistic).
        case toggleSonosPlayback(groupId: String)
        /// Volume slider moved (0–100). Optimistic + debounced commit (same ≥150ms floor as sliders).
        case sonosVolumeChanged(groupId: String, volume: Int)
        case commitSonosVolume(groupId: String, volume: Int)

        // Nest thermostat (P15-C3)
        case nestReloaded([NestThermostat])
        /// A −/+ stepper tap on a thermostat setpoint (±1 °F). Optimistic + debounced commit (≥300ms).
        case nestSetpointStepped(deviceName: String, kind: NestSetpointKind, deltaF: Int)
        /// The debounced commit, fired ≥300ms after the last stepper tap.
        case commitNestSetpoint(deviceName: String)
        /// Change a thermostat's mode (optimistic; commits immediately). P14 seam over `setMode`.
        case setNestMode(deviceName: String, mode: NestMode)
    }

    public init() {}

    @Dependency(\.hue) var hue
    @Dependency(\.lutron) var lutron
    @Dependency(\.sonos) var sonos
    @Dependency(\.nest) var nest
    @Dependency(\.continuousClock) var clock

    /// ≥150ms between slider PUTs (the required floor). One quiescent tick, then one write.
    static let sliderDebounce: Duration = .milliseconds(150)
    /// ≥300ms after the last thermostat stepper tap before a single SDM command lands (SDM is a cloud
    /// call — a coarser debounce than the LAN sliders so a −−−+ flurry collapses to one write).
    static let stepperDebounce: Duration = .milliseconds(300)

    private enum CancelID: Hashable {
        case refresh
        case sceneSuccess(String)
        case roomBrightness(String)
        case lightBrightness(String)
        case shadeLevel(String)
        case sonosRefresh
        case sonosVolume(String)
        case nestRefresh
        case nestSetpoint(String)
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task, .refresh:
                state.isRefreshing = true
                let bridges = state.config.bridges
                let lutronConfig = state.lutronConfig
                let sonosConfig = state.sonosConfig
                let nestConfig = state.nestConfig
                return .merge(
                    .run { send in
                        let snapshots = await hue.readHouse(bridges)
                        await send(.houseReloaded(snapshots))
                    }
                    .cancellable(id: CancelID.refresh, cancelInFlight: true),
                    // Shades load independently — a Lutron hiccup never blocks the lights.
                    .run { send in
                        guard let lutronConfig else { return }
                        let shades = (try? await lutron.shades(lutronConfig)) ?? []
                        await send(.shadesReloaded(shades))
                    },
                    // Speakers discover independently (Sonos needs no config — nil still discovers).
                    // One topology read + a now-playing/volume read per group; empty = silent degrade.
                    .run { send in
                        let speakers = (try? await sonos.discover(sonosConfig)) ?? []
                        guard !speakers.isEmpty else { return }
                        var groups: [SonosGroup] = []
                        for row in SonosGroup.assemble(from: speakers, order: sonosConfig?.roomOrder) {
                            let np = (try? await sonos.nowPlaying(sonosConfig, row.coordinator)) ?? SonosNowPlaying(state: .stopped)
                            let vol = (try? await sonos.volume(sonosConfig, row.coordinator)) ?? 0
                            groups.append(SonosGroup(coordinator: row.coordinator, members: row.members, nowPlaying: np, volume: vol))
                        }
                        await send(.sonosReloaded(groups))
                    }
                    .cancellable(id: CancelID.sonosRefresh, cancelInFlight: true),
                    // Thermostats load independently (P15-C3) — a Nest cloud hiccup never blocks the
                    // lights/shades/speakers. Nil config or an error → empty → the Climate section hides.
                    .run { send in
                        guard let nestConfig, nestConfig.isConnected else { return }
                        let thermostats = (try? await nest.thermostats(nestConfig)) ?? []
                        await send(.nestReloaded(thermostats))
                    }
                    .cancellable(id: CancelID.nestRefresh, cancelInFlight: true)
                )

            case let .houseReloaded(snapshots):
                state.isRefreshing = false
                state.bridges = snapshots
                return .none

            case let .shadesReloaded(shades):
                state.shades = shades
                return .none

            case let .shadeLevelChanged(zoneId, level):
                guard state.lutronConfig != nil,
                      let i = state.shades.firstIndex(where: { $0.zoneId == zoneId }) else { return .none }
                let clamped = LutronLevel.clamp(level)
                state.shades[i].level = clamped   // optimistic
                return .run { send in
                    try await clock.sleep(for: Self.sliderDebounce)
                    await send(.commitShadeLevel(zoneId: zoneId, level: clamped))
                }
                .cancellable(id: CancelID.shadeLevel(zoneId), cancelInFlight: true)

            case let .commitShadeLevel(zoneId, level):
                guard let config = state.lutronConfig else { return .none }
                return .run { _ in
                    try? await lutron.setShadeLevel(config, zoneId, level)
                }

            case let .raiseShade(zoneId):
                guard let config = state.lutronConfig,
                      let i = state.shades.firstIndex(where: { $0.zoneId == zoneId }) else { return .none }
                state.shades[i].level = LutronLevel.max   // optimistic: fully open
                return .run { _ in try? await lutron.raise(config, zoneId) }

            case let .lowerShade(zoneId):
                guard let config = state.lutronConfig,
                      let i = state.shades.firstIndex(where: { $0.zoneId == zoneId }) else { return .none }
                state.shades[i].level = LutronLevel.min   // optimistic: fully closed
                return .run { _ in try? await lutron.lower(config, zoneId) }

            case let .stopShade(zoneId):
                guard let config = state.lutronConfig else { return .none }
                // Stop leaves the shade wherever it is; re-read to sync the true resting level.
                return .run { send in
                    try? await lutron.stop(config, zoneId)
                    let shades = (try? await lutron.shades(config)) ?? []
                    await send(.shadesReloaded(shades))
                }

            // MARK: Sonos speakers (P15-C2)

            case let .sonosReloaded(groups):
                state.sonosGroups = groups
                return .none

            case let .toggleSonosPlayback(groupId):
                guard let gi = state.sonosGroups.firstIndex(where: { $0.id == groupId }) else { return .none }
                let coordinator = state.sonosGroups[gi].coordinator
                let wasPlaying = state.sonosGroups[gi].nowPlaying.state == .playing
                state.sonosGroups[gi].nowPlaying.state = wasPlaying ? .paused : .playing   // optimistic
                let config = state.sonosConfig
                return .run { _ in
                    // Control the group coordinator (SoCo pattern). Best-effort — the section never
                    // surfaces an error; a failed write just leaves the optimistic state to be corrected
                    // on the next refresh.
                    if wasPlaying { try? await sonos.pause(config, coordinator) }
                    else { try? await sonos.play(config, coordinator) }
                }

            case let .sonosVolumeChanged(groupId, volume):
                guard let gi = state.sonosGroups.firstIndex(where: { $0.id == groupId }) else { return .none }
                let clamped = SonosVolume.clamp(volume)
                state.sonosGroups[gi].volume = clamped   // optimistic
                return .run { send in
                    try await clock.sleep(for: Self.sliderDebounce)
                    await send(.commitSonosVolume(groupId: groupId, volume: clamped))
                }
                .cancellable(id: CancelID.sonosVolume(groupId), cancelInFlight: true)

            case let .commitSonosVolume(groupId, volume):
                guard let group = state.sonosGroups.first(where: { $0.id == groupId }) else { return .none }
                let coordinator = group.coordinator
                let config = state.sonosConfig
                return .run { _ in try? await sonos.setVolume(config, coordinator, volume) }

            // MARK: Nest thermostat (P15-C3)

            case let .nestReloaded(thermostats):
                state.thermostats = thermostats
                return .none

            case let .nestSetpointStepped(deviceName, kind, deltaF):
                guard state.nestConfig != nil,
                      let i = state.thermostats.firstIndex(where: { $0.id == deviceName }),
                      let current = state.thermostats[i].setpointF(kind) else { return .none }
                // Optimistic: nudge the setpoint locally, then debounce the single SDM command.
                state.thermostats[i] = state.thermostats[i].settingSetpointF(kind, to: current + deltaF)
                return .run { send in
                    try await clock.sleep(for: Self.stepperDebounce)
                    await send(.commitNestSetpoint(deviceName: deviceName))
                }
                .cancellable(id: CancelID.nestSetpoint(deviceName), cancelInFlight: true)

            case let .commitNestSetpoint(deviceName):
                guard let config = state.nestConfig,
                      let thermostat = state.thermostats.first(where: { $0.id == deviceName }),
                      let setpoint = thermostat.commitSetpoint() else { return .none }
                return .run { _ in
                    // Best-effort — the section never surfaces an error; a failed write leaves the
                    // optimistic value to be corrected on the next refresh.
                    try? await nest.setTemperatureF(config, deviceName, setpoint)
                }

            case let .setNestMode(deviceName, mode):
                guard let config = state.nestConfig,
                      let i = state.thermostats.firstIndex(where: { $0.id == deviceName }) else { return .none }
                state.thermostats[i] = state.thermostats[i].settingMode(mode)   // optimistic
                return .run { _ in try? await nest.setMode(config, deviceName, mode) }

            case let .toggleRoom(bridgeId, roomId):
                guard let bi = state.bridges.firstIndex(where: { $0.bridge.bridgeId == bridgeId }),
                      let ri = state.bridges[bi].rooms.firstIndex(where: { $0.id == roomId }),
                      let bridge = state.config.bridge(bridgeId) else { return .none }
                let newOn = !state.bridges[bi].rooms[ri].anyOn
                state.bridges[bi].rooms[ri].anyOn = newOn
                let memberIds = Set(state.bridges[bi].rooms[ri].lightIds)
                for li in state.bridges[bi].lights.indices
                where memberIds.contains(state.bridges[bi].lights[li].id) && state.bridges[bi].lights[li].reachable {
                    state.bridges[bi].lights[li].isOn = newOn
                }
                return .run { send in
                    do { try await hue.setGroupState(bridge, roomId, newOn, nil) }
                    catch { await send(.refresh) }   // silent truth-restore
                }

            case let .toggleLight(bridgeId, lightId):
                guard let bi = state.bridges.firstIndex(where: { $0.bridge.bridgeId == bridgeId }),
                      let li = state.bridges[bi].lights.firstIndex(where: { $0.id == lightId }),
                      state.bridges[bi].lights[li].reachable,
                      let bridge = state.config.bridge(bridgeId) else { return .none }
                let newOn = !state.bridges[bi].lights[li].isOn
                state.bridges[bi].lights[li].isOn = newOn
                recomputeRoomAnyOn(&state, bridgeIndex: bi)
                return .run { send in
                    do { try await hue.setLightState(bridge, lightId, newOn, nil) }
                    catch { await send(.refresh) }
                }

            case let .roomBrightnessChanged(bridgeId, roomId, percent):
                guard let bi = state.bridges.firstIndex(where: { $0.bridge.bridgeId == bridgeId }),
                      let ri = state.bridges[bi].rooms.firstIndex(where: { $0.id == roomId }) else { return .none }
                let bri = HueBrightness.bri(fromPercent: percent)
                state.bridges[bi].rooms[ri].brightness = bri
                state.bridges[bi].rooms[ri].anyOn = true
                let memberIds = Set(state.bridges[bi].rooms[ri].lightIds)
                for li in state.bridges[bi].lights.indices
                where memberIds.contains(state.bridges[bi].lights[li].id) && state.bridges[bi].lights[li].reachable {
                    state.bridges[bi].lights[li].brightness = bri
                    state.bridges[bi].lights[li].isOn = true
                }
                return .run { send in
                    try await clock.sleep(for: Self.sliderDebounce)
                    await send(.commitRoomBrightness(bridgeId: bridgeId, roomId: roomId, bri: bri))
                }
                .cancellable(id: CancelID.roomBrightness(roomId), cancelInFlight: true)

            case let .commitRoomBrightness(bridgeId, roomId, bri):
                guard let bridge = state.config.bridge(bridgeId) else { return .none }
                return .run { send in
                    do { try await hue.setGroupState(bridge, roomId, nil, bri) }
                    catch { await send(.refresh) }
                }

            case let .lightBrightnessChanged(bridgeId, lightId, percent):
                guard let bi = state.bridges.firstIndex(where: { $0.bridge.bridgeId == bridgeId }),
                      let li = state.bridges[bi].lights.firstIndex(where: { $0.id == lightId }),
                      state.bridges[bi].lights[li].reachable else { return .none }
                let bri = HueBrightness.bri(fromPercent: percent)
                state.bridges[bi].lights[li].brightness = bri
                state.bridges[bi].lights[li].isOn = true
                recomputeRoomAnyOn(&state, bridgeIndex: bi)
                return .run { send in
                    try await clock.sleep(for: Self.sliderDebounce)
                    await send(.commitLightBrightness(bridgeId: bridgeId, lightId: lightId, bri: bri))
                }
                .cancellable(id: CancelID.lightBrightness(lightId), cancelInFlight: true)

            case let .commitLightBrightness(bridgeId, lightId, bri):
                guard let bridge = state.config.bridge(bridgeId) else { return .none }
                return .run { send in
                    do { try await hue.setLightState(bridge, lightId, nil, bri) }
                    catch { await send(.refresh) }
                }

            case let .recallScene(bridgeId, groupId, sceneId):
                guard let bridge = state.config.bridge(bridgeId) else { return .none }
                if let bi = state.bridges.firstIndex(where: { $0.bridge.bridgeId == bridgeId }),
                   let ri = state.bridges[bi].rooms.firstIndex(where: { $0.id == groupId }) {
                    state.bridges[bi].rooms[ri].anyOn = true   // optimistic: a recalled scene lights the room
                }
                return .run { send in
                    try? await hue.recallScene(bridge, groupId, sceneId)
                    await send(.sceneRecalled(sceneId: sceneId))
                    await send(.refresh)
                }

            case let .sceneRecalled(sceneId):
                state.recalledScene = sceneId
                return .run { send in
                    try? await clock.sleep(for: .seconds(1.2))
                    await send(.clearSceneSuccess(sceneId: sceneId))
                }
                .cancellable(id: CancelID.sceneSuccess(sceneId), cancelInFlight: true)

            case let .clearSceneSuccess(sceneId):
                if state.recalledScene == sceneId { state.recalledScene = nil }
                return .none
            }
        }
    }

    /// Recompute every room's `anyOn` in a bridge from its member lights — keeps room rows honest
    /// after a per-light toggle/brightness edit.
    private func recomputeRoomAnyOn(_ state: inout State, bridgeIndex bi: Int) {
        let onIds = Set(state.bridges[bi].lights.filter(\.isOn).map(\.id))
        for ri in state.bridges[bi].rooms.indices {
            state.bridges[bi].rooms[ri].anyOn = state.bridges[bi].rooms[ri].lightIds.contains { onIds.contains($0) }
        }
    }
}
