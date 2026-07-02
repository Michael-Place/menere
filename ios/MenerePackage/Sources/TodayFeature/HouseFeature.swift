import ComposableArchitecture
import FamilyDomain
import Foundation
import HueClient

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

        public init(config: HueConfig, members: [HouseholdMember] = [], bridges: [BridgeSnapshot] = []) {
            self.config = config
            self.members = members
            self.bridges = bridges
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
    }

    public init() {}

    @Dependency(\.hue) var hue
    @Dependency(\.continuousClock) var clock

    /// ≥150ms between slider PUTs (the required floor). One quiescent tick, then one write.
    static let sliderDebounce: Duration = .milliseconds(150)

    private enum CancelID: Hashable {
        case refresh
        case sceneSuccess(String)
        case roomBrightness(String)
        case lightBrightness(String)
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task, .refresh:
                state.isRefreshing = true
                let bridges = state.config.bridges
                return .run { send in
                    let snapshots = await hue.readHouse(bridges)
                    await send(.houseReloaded(snapshots))
                }
                .cancellable(id: CancelID.refresh, cancelInFlight: true)

            case let .houseReloaded(snapshots):
                state.isRefreshing = false
                state.bridges = snapshots
                return .none

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
