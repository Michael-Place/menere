import ComposableArchitecture
import FamilyDomain
import Foundation
import HomeKitClient
import HubspaceClient
import HueClient
import LutronClient
import MerossClient
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

        // MARK: Per-section load tracking (Wave 1)
        /// Each subsystem sets its flag when its FIRST fetch lands (even when the result is empty). Paired
        /// with config presence this is what lets the view tell *configured-but-unreachable* (loaded &&
        /// empty && configured → a dimmed "Offline" badge, section stays visible) apart from
        /// *not-configured* (section hides) and *still-loading* (a spinner badge). Derived purely from
        /// config presence + fetch success — never an invented hardware probe.
        public var hueLoaded = false
        public var lutronLoaded = false
        public var sonosLoaded = false
        public var nestLoaded = false
        public var hubspaceLoaded = false
        public var garageLoaded = false
        public var homekitLoaded = false
        /// Bumped whenever an optimistic write reverts (the device didn't answer) — the view watches this
        /// with `.errorHaptic` + a transient toast so a failed tap is no longer an invisible no-op.
        public var writeErrorTick = 0

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

        // MARK: Hubspace water timer (P15-C4)
        /// The household's Hubspace config (nil = not set up). Stable for the screen's lifetime.
        public var hubspaceConfig: HubspaceConfig?
        /// Live spigot state, mutated optimistically and re-synced on refresh / the ~30s poll. Loaded on
        /// `.task`; empty = not set up / unreachable (silent degrade).
        public var spigots: [HubspaceSpigot] = []

        // MARK: Meross/Refoss garage opener (P15-C5)
        /// The household's Meross config (nil = not set up). Stable for the screen's lifetime.
        public var merossConfig: MerossConfig?
        /// Live garage door state, re-synced on refresh and after the settle delay. Loaded on `.task`;
        /// empty = not set up / unreachable (silent degrade).
        public var garageDoors: [GarageDoor] = []
        /// Per-channel transitional state while a door is moving (garage doors are slow): "Opening…" /
        /// "Closing…". Set optimistically on a commit, cleared after the ~20s settle re-read.
        public var garageSettling: [Int: GarageTransition] = [:]
        /// The channel awaiting an OPEN confirmation (drives the "Open the garage?" dialog). Opening is a
        /// security action → always confirmed; closing is not.
        public var confirmingGarageOpen: Int?

        // MARK: Apple HomeKit (P15-C7)
        /// The household's OPTIONAL HomeKit config (nil is fine — HomeKit reads the live local Home once
        /// authorized; the doc only forces the mock). Stable for the screen's lifetime.
        public var homekitConfig: HomeKitConfig?
        /// The app's HomeKit authorization (drives whether the live Home is read). Loaded on `.task`.
        public var homekitAuth: HKAuthStatus = .notDetermined
        /// The snapshot of the live (or mock) Home — powers the HomeKit section (locks/plugs/sensors) and,
        /// when it contains a garage, the Garage section. Nil until loaded / not authorized.
        public var homekitInventory: HKInventory?
        /// Which integration powers the Garage section. **HomeKit takes precedence** when the authorized
        /// Home contains a garage-door opener; otherwise the Meross/Refoss config is the fallback.
        public var garageSource: GarageSource = .meross
        /// channel → HomeKit accessory id, populated when the Garage section is HomeKit-sourced (so
        /// `commitGarage` knows which accessory to write).
        public var garageHomeKitAccessoryIds: [Int: String] = [:]
        /// The accessory id awaiting an UNLOCK confirmation (drives the "Unlock the front door?" dialog).
        /// Unlocking is a security action → always confirmed; locking is not (mirrors garage open/close).
        public var confirmingHomeKitUnlock: String?

        public init(
            config: HueConfig, members: [HouseholdMember] = [], bridges: [BridgeSnapshot] = [],
            lutronConfig: LutronConfig? = nil, shades: [LutronShade] = [],
            sonosConfig: SonosConfig? = nil, sonosGroups: [SonosGroup] = [],
            nestConfig: NestConfig? = nil, thermostats: [NestThermostat] = [],
            hubspaceConfig: HubspaceConfig? = nil, spigots: [HubspaceSpigot] = [],
            merossConfig: MerossConfig? = nil, garageDoors: [GarageDoor] = [],
            homekitConfig: HomeKitConfig? = nil
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
            self.hubspaceConfig = hubspaceConfig
            self.spigots = spigots
            self.merossConfig = merossConfig
            self.garageDoors = garageDoors
            self.homekitConfig = homekitConfig
        }

        /// The transitional display state of a moving garage door.
        public enum GarageTransition: Equatable, Sendable { case opening, closing }

        /// Which integration powers the Garage section (HomeKit wins when a HomeKit garage exists).
        public enum GarageSource: Equatable, Sendable { case meross, homeKit }

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

        // MARK: Section status (Wave 1)

        /// Fold (configured?, loaded?, empty?) into the four-way ``DeviceStatus`` the header badge reads.
        private func status(configured: Bool, loaded: Bool, isEmpty: Bool) -> DeviceStatus {
            guard configured else { return .notConfigured }
            if !loaded { return .loading }
            return isEmpty ? .unreachable : .ok
        }

        /// Hue is "configured" once any bridge doc exists; unreachable when the read returned no bridges.
        public var hueStatus: DeviceStatus {
            status(configured: !config.bridges.isEmpty, loaded: hueLoaded, isEmpty: bridges.isEmpty)
        }
        public var lutronStatus: DeviceStatus {
            status(configured: lutronConfig != nil, loaded: lutronLoaded, isEmpty: shades.isEmpty)
        }
        /// Sonos needs no pairing (nil config still discovers), so it's only "configured" with an explicit
        /// config; a nil-config discovery that finds nothing simply doesn't show (notConfigured).
        public var sonosStatus: DeviceStatus {
            status(configured: sonosConfig != nil, loaded: sonosLoaded, isEmpty: sonosGroups.isEmpty)
        }
        public var nestStatus: DeviceStatus {
            status(configured: nestConfig?.isConnected == true, loaded: nestLoaded, isEmpty: thermostats.isEmpty)
        }
        public var hubspaceStatus: DeviceStatus {
            status(configured: hubspaceConfig?.isConnected == true, loaded: hubspaceLoaded, isEmpty: spigots.isEmpty)
        }
        /// Garage is configured when either the Meross opener is set up OR HomeKit has claimed the section.
        public var garageStatus: DeviceStatus {
            let configured = merossConfig?.isConnected == true || garageSource == .homeKit
            return status(configured: configured, loaded: garageLoaded || homekitLoaded, isEmpty: garageDoors.isEmpty)
        }
        /// HomeKit is configured once the app is authorized (or a mock config forces it); unreachable when
        /// the authorized Home surfaced no controllable accessories.
        public var homekitStatus: DeviceStatus {
            let configured = homekitAuth == .authorized || homekitConfig != nil
            // "Empty" = the authorized Home surfaced no accessories at all. A Home with only lights (Hue
            // owns those) still shows the section for its "All HomeKit devices" discovery affordance.
            let empty = homekitInventory.map { $0.accessories.isEmpty } ?? true
            return status(configured: configured, loaded: homekitLoaded, isEmpty: empty)
        }

        // MARK: House-at-a-glance (Wave 1)

        /// Labeled temperature readings for the glance header: every *labeled* Hue thermometer plus each
        /// Nest thermostat's ambient. `(label, °F)`, in a stable order (Hue first, then climate).
        public var glanceTemperatures: [(label: String, tempF: Double)] {
            var out: [(label: String, tempF: Double)] = []
            for snap in bridges {
                let labels = config.sensorLabels(for: snap.bridge.bridgeId)
                for t in snap.temperatures {
                    if let label = labels[t.sensorId] { out.append((label, t.tempF)) }
                }
            }
            for thermostat in thermostats {
                if let ambient = thermostat.ambientF { out.append((thermostat.roomName, ambient)) }
            }
            return out
        }

        /// Reachable lights currently on, summed across bridges — the header's lights-on count.
        public var lightsOnCount: Int {
            bridges.flatMap(\.lights).filter { $0.isOn && $0.reachable }.count
        }

        /// True when a Hue bridge is reachable (so "All lights off" / "Goodnight" can actually do something).
        public var hasReachableLights: Bool { !bridges.isEmpty }

        /// The night/bedtime ritual, if the family curated one — recalled as the second half of "Goodnight".
        public var nightRitual: HueRitual? {
            config.rituals.first { r in
                let hay = (r.key + " " + r.label).lowercased()
                return hay.contains("night") || hay.contains("bed")
            }
        }

        /// Ritual chips surfaced at the top of the House screen. Prefer the family-curated rituals; when
        /// none exist, fall back to the distinct scene names across reachable bridges so there's still a
        /// one-tap scene surface up top (matched by name to its bridge/group for recall).
        public var glanceScenes: [GlanceScene] {
            if !config.rituals.isEmpty {
                return config.rituals.compactMap { ritual in
                    guard config.bridge(ritual.bridgeId) != nil else { return nil }
                    return GlanceScene(id: ritual.id, name: ritual.label, bridgeId: ritual.bridgeId,
                                       groupId: ritual.groupId, sceneId: ritual.sceneId)
                }
            }
            var seen = Set<String>()
            var out: [GlanceScene] = []
            for snap in bridges {
                for scene in snap.scenes.sorted(by: { $0.name < $1.name }) {
                    guard let groupId = scene.groupId, !seen.contains(scene.name) else { continue }
                    seen.insert(scene.name)
                    out.append(GlanceScene(id: "\(snap.bridge.bridgeId)/\(scene.id)", name: scene.name,
                                           bridgeId: snap.bridge.bridgeId, groupId: groupId, sceneId: scene.id))
                }
            }
            return out
        }

        /// True when NOTHING is set up (no config across any subsystem, nothing discovered) — drives the
        /// top-level "Nothing set up yet" empty state.
        public var isAnythingConfigured: Bool {
            !config.bridges.isEmpty || lutronConfig != nil || sonosConfig != nil
                || nestConfig?.isConnected == true || hubspaceConfig?.isConnected == true
                || merossConfig?.isConnected == true || homekitConfig != nil
                || !sonosGroups.isEmpty || homekitInventory != nil
        }

        /// True only on the very first paint with no seeded snapshot — drives the loading skeleton. Once
        /// Today has seeded `bridges`, or any section has answered, this is false.
        public var isInitialLoading: Bool {
            isRefreshing && !hueLoaded && !lutronLoaded && !sonosLoaded && !nestLoaded
                && !hubspaceLoaded && !garageLoaded && !homekitLoaded
                && bridges.isEmpty && shades.isEmpty && sonosGroups.isEmpty
                && thermostats.isEmpty && spigots.isEmpty && garageDoors.isEmpty && homekitInventory == nil
        }

        /// True when Hue is configured but no bridge answered (seeded-away) — drives the "Not home —
        /// showing last known" banner.
        public var isAwayFromHome: Bool { hueStatus == .unreachable }
    }

    /// A one-tap scene chip surfaced at the top of the House screen (a curated ritual, or a fallback
    /// distinct scene). Carries everything `recallScene` needs.
    public struct GlanceScene: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let bridgeId: String
        public let groupId: String
        public let sceneId: String
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

        // House-at-a-glance master actions (Wave 1)
        /// Turn every Hue room/zone group off (optimistic) — the header's "All lights off".
        case allLightsOff
        /// All-off + recall any curated night/bedtime ritual — the header's "Goodnight".
        case goodnight
        /// An optimistic write reverted (the device didn't answer). Bumps `writeErrorTick` so the view can
        /// surface the subtle toast + error haptic. Purely a feedback signal — the truth-restore re-read is
        /// dispatched alongside it by the failing handler.
        case writeFailed

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

        // Hubspace water timer (P15-C4)
        case spigotsReloaded([HubspaceSpigot])
        /// Open/close one outlet, optionally for a timed run (optimistic; commits immediately). P14 seam
        /// over `setSpigot`.
        case toggleSpigot(deviceId: String, instance: String, open: Bool, durationMinutes: Int?)
        /// The ~30s poll while the House screen is visible — a single spigot re-read (the View drives the
        /// cadence and cancels it on disappear, so there's no background polling).
        case waterPoll

        // Meross/Refoss garage opener (P15-C5)
        case garageReloaded([GarageDoor])
        /// A tap on a door's OPEN action — routes through the confirmation dialog (opening is a security
        /// action). Never actuates directly.
        case garageOpenRequested(channel: Int)
        /// The user confirmed the pending open → actually opens the door.
        case confirmGarageOpen
        /// The user dismissed the open confirmation.
        case cancelGarageOpen
        /// A tap on a door's CLOSE action — closing is safe, so it commits directly (no confirmation).
        case garageCloseRequested(channel: Int)
        /// The shared commit that actuates a door (optimistic + settling). P14 seam over `setGarage`.
        /// NOTE: the agent harness must gate `open == true` behind its OWN confirmation (see MerossClient).
        case commitGarage(channel: Int, open: Bool)
        /// Fired ~20s after a commit (garage doors are slow) — clears the door's settling state and
        /// re-reads the true state.
        case garageSettleElapsed(channel: Int)
        /// A single garage state re-read (after settle / after a failed write). Silent degrade.
        case garagePoll

        // Apple HomeKit (P15-C7)
        /// Load HomeKit authorization + inventory (on `.task`/`.refresh`, and as a silent re-read after a
        /// failed write). In mock mode auth is treated as authorized and the fixture Home is served.
        case homekitLoad
        case homekitAuthLoaded(HKAuthStatus)
        case homekitInventoryLoaded(HKInventory?)
        /// Toggle a smart plug/switch's power (optimistic). P14 seam over `setCharacteristic`.
        case homekitToggleOutlet(accessoryId: String)
        /// Lock (secure) a door — safe, commits directly (no confirmation). P14 seam over `setCharacteristic`.
        case homekitLockRequested(accessoryId: String)
        /// A tap to UNLOCK — routes through the confirmation dialog (unlocking is a security action).
        case homekitUnlockRequested(accessoryId: String)
        /// The user confirmed the pending unlock → actually unlocks.
        case confirmHomeKitUnlock
        /// The user dismissed the unlock confirmation.
        case cancelHomeKitUnlock
        /// The shared commit that secures/unsecures a lock (optimistic). P14 seam over `setCharacteristic`.
        /// NOTE: the agent harness must gate `secured == false` (unlock) behind its OWN confirmation.
        case commitHomeKitLock(accessoryId: String, secured: Bool)
    }

    public init() {}

    @Dependency(\.hue) var hue
    @Dependency(\.lutron) var lutron
    @Dependency(\.sonos) var sonos
    @Dependency(\.nest) var nest
    @Dependency(\.hubspace) var hubspace
    @Dependency(\.meross) var meross
    @Dependency(\.homekit) var homekit
    @Dependency(\.continuousClock) var clock

    /// ≥150ms between slider PUTs (the required floor). One quiescent tick, then one write.
    static let sliderDebounce: Duration = .milliseconds(150)
    /// ≥300ms after the last thermostat stepper tap before a single SDM command lands (SDM is a cloud
    /// call — a coarser debounce than the LAN sliders so a −−−+ flurry collapses to one write).
    static let stepperDebounce: Duration = .milliseconds(300)
    /// How long a garage door is shown as "Opening…" / "Closing…" before we re-read its true state. Garage
    /// doors are physically slow — ~20s covers a full travel with margin.
    static let garageSettleDuration: Duration = .seconds(20)

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
        case waterRefresh
        case garageRefresh
        case garageSettle(Int)
        case homekitRefresh
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
                let hubspaceConfig = state.hubspaceConfig
                let merossConfig = state.merossConfig
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
                        // Always send (even empty) so a *configured* Sonos that discovers nothing reads as
                        // unreachable rather than spinning forever (Wave 1: distinguishable states).
                        guard !speakers.isEmpty else { await send(.sonosReloaded([])); return }
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
                    .cancellable(id: CancelID.nestRefresh, cancelInFlight: true),
                    // Spigots load independently (P15-C4) — a Hubspace cloud hiccup never blocks the
                    // rest. Nil config or an error → empty → the Water section hides.
                    .run { send in
                        guard let hubspaceConfig, hubspaceConfig.isConnected else { return }
                        let spigots = (try? await hubspace.spigots(hubspaceConfig)) ?? []
                        await send(.spigotsReloaded(spigots))
                    }
                    .cancellable(id: CancelID.waterRefresh, cancelInFlight: true),
                    // Garage loads independently (P15-C5) — a dead opener never blocks the rest. Nil config
                    // or an error → empty → the Garage section hides.
                    .run { send in
                        guard let merossConfig, merossConfig.isConnected else { return }
                        let doors = (try? await meross.garageState(merossConfig)) ?? []
                        await send(.garageReloaded(doors))
                    }
                    .cancellable(id: CancelID.garageRefresh, cancelInFlight: true),
                    // HomeKit loads independently (P15-C7) — auth + inventory. Powers the HomeKit section
                    // and (when the Home has a garage) takes over the Garage section from Meross.
                    .send(.homekitLoad)
                )

            case let .houseReloaded(snapshots):
                state.isRefreshing = false
                state.hueLoaded = true
                state.bridges = snapshots
                return .none

            case let .shadesReloaded(shades):
                state.lutronLoaded = true
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
                state.sonosLoaded = true
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
                state.nestLoaded = true
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

            // MARK: Hubspace water timer (P15-C4)

            case let .spigotsReloaded(spigots):
                state.hubspaceLoaded = true
                state.spigots = spigots
                return .none

            case .waterPoll:
                // The ~30s poll (View-driven, cancelled on disappear). A single single-flighted re-read;
                // nil/unconnected config → no-op.
                guard let config = state.hubspaceConfig, config.isConnected else { return .none }
                return .run { send in
                    let spigots = (try? await hubspace.spigots(config)) ?? []
                    await send(.spigotsReloaded(spigots))
                }
                .cancellable(id: CancelID.waterRefresh, cancelInFlight: true)

            case let .toggleSpigot(deviceId, instance, open, durationMinutes):
                guard let config = state.hubspaceConfig,
                      let si = state.spigots.firstIndex(where: { $0.id == deviceId }),
                      let oi = state.spigots[si].outlets.firstIndex(where: { $0.instance == instance })
                else { return .none }
                // Optimistic: flip the outlet locally, then commit. On failure re-read to restore truth.
                let outlet = state.spigots[si].outlets[oi]
                var outlets = state.spigots[si].outlets
                outlets[oi] = outlet.setting(open: open, remainingMinutes: durationMinutes)
                let spigot = state.spigots[si]
                state.spigots[si] = HubspaceSpigot(id: spigot.id, name: spigot.name, outlets: outlets, batteryPercent: spigot.batteryPercent)
                return .run { send in
                    do { try await hubspace.setSpigot(config, deviceId, instance, open, durationMinutes) }
                    catch { await send(.writeFailed); await send(.waterPoll) }   // toast + truth-restore
                }

            // MARK: Meross/Refoss garage opener (P15-C5)

            case let .garageReloaded(doors):
                // Meross-sourced re-read. If HomeKit has claimed the Garage section (precedence), ignore
                // the Meross truth so the two sources never fight over `garageDoors`.
                guard state.garageSource == .meross else { return .none }
                state.garageLoaded = true
                state.garageDoors = doors
                return .none

            case let .garageOpenRequested(channel):
                // Opening the garage is a security action — always route through the confirmation dialog.
                state.confirmingGarageOpen = channel
                return .none

            case .cancelGarageOpen:
                state.confirmingGarageOpen = nil
                return .none

            case .confirmGarageOpen:
                guard let channel = state.confirmingGarageOpen else { return .none }
                state.confirmingGarageOpen = nil
                return .send(.commitGarage(channel: channel, open: true))

            case let .garageCloseRequested(channel):
                // Closing is safe — no confirmation.
                return .send(.commitGarage(channel: channel, open: false))

            case let .commitGarage(channel, open):
                guard let di = state.garageDoors.firstIndex(where: { $0.channel == channel }) else { return .none }
                // Optimistic: flip the door + show the transitional state (garage doors are slow).
                state.garageDoors[di] = state.garageDoors[di].setting(open: open)
                state.garageSettling[channel] = open ? .opening : .closing
                // Route the write to whichever integration owns the Garage section. HomeKit precedence:
                // when the authorized Home has a garage opener it powers this section; else Meross.
                switch state.garageSource {
                case .meross:
                    guard let config = state.merossConfig else {
                        state.garageSettling[channel] = nil
                        return .none
                    }
                    return .run { send in
                        do { try await meross.setGarage(config, channel, open) }
                        catch {
                            // Write failed — toast + restore truth immediately (clear settling + re-read).
                            await send(.writeFailed)
                            await send(.garageSettleElapsed(channel: channel))
                            return
                        }
                        // Let the door travel, then re-read its true resting state.
                        try? await clock.sleep(for: Self.garageSettleDuration)
                        await send(.garageSettleElapsed(channel: channel))
                    }
                    .cancellable(id: CancelID.garageSettle(channel), cancelInFlight: true)
                case .homeKit:
                    guard let accessoryId = state.garageHomeKitAccessoryIds[channel] else {
                        state.garageSettling[channel] = nil
                        return .none
                    }
                    let config = state.homekitConfig
                    // HomeKit garage target door state: 0 == open, 1 == closed.
                    let target = HKCharacteristicValue.int(open ? 0 : 1)
                    return .run { send in
                        do { try await homekit.setCharacteristic(config, accessoryId, .garageDoorOpener, .targetDoorState, target) }
                        catch {
                            await send(.writeFailed)
                            await send(.garageSettleElapsed(channel: channel))
                            return
                        }
                        try? await clock.sleep(for: Self.garageSettleDuration)
                        await send(.garageSettleElapsed(channel: channel))
                    }
                    .cancellable(id: CancelID.garageSettle(channel), cancelInFlight: true)
                }

            case let .garageSettleElapsed(channel):
                state.garageSettling[channel] = nil
                return .send(.garagePoll)

            case .garagePoll:
                switch state.garageSource {
                case .meross:
                    guard let config = state.merossConfig, config.isConnected else { return .none }
                    return .run { send in
                        let doors = (try? await meross.garageState(config)) ?? []
                        await send(.garageReloaded(doors))
                    }
                    .cancellable(id: CancelID.garageRefresh, cancelInFlight: true)
                case .homeKit:
                    // HomeKit garage re-read = reload the whole inventory (also refreshes the HomeKit
                    // section); `homekitInventoryLoaded` re-derives the garage rows.
                    return .send(.homekitLoad)
                }

            // MARK: Apple HomeKit (P15-C7)

            case .homekitLoad:
                let config = state.homekitConfig
                return .run { send in
                    // Mock mode is always "authorized" and serves the fixture Home — it never touches the
                    // live HMHomeManager (so it never triggers the permission prompt). Live mode reads the
                    // real status; the FIRST such read is what surfaces the system prompt.
                    let status: HKAuthStatus = config?.isMock == true ? .authorized : await homekit.authorizationStatus()
                    await send(.homekitAuthLoaded(status))
                    guard status == .authorized else { return }
                    let inventory = await homekit.inventory(config)
                    await send(.homekitInventoryLoaded(inventory))
                }
                .cancellable(id: CancelID.homekitRefresh, cancelInFlight: true)

            case let .homekitAuthLoaded(status):
                state.homekitAuth = status
                // When not authorized the inventory read never fires, so conclude the first-load here so
                // the section doesn't spin forever (it just won't render unless a config forces it).
                if status != .authorized { state.homekitLoaded = true }
                return .none

            case let .homekitInventoryLoaded(inventory):
                state.homekitLoaded = true
                state.homekitInventory = inventory
                guard let inventory else { return .none }
                // GARAGE PRECEDENCE (P15-C7): a HomeKit garage-door opener takes over the Garage section
                // from the Meross fallback. When present, derive the door rows from HomeKit and remember
                // each channel's accessory id for writes; when absent, leave the Meross-sourced rows alone.
                let garages = inventory.garageAccessories
                if !garages.isEmpty {
                    state.garageSource = .homeKit
                    var map: [Int: String] = [:]
                    var doors: [GarageDoor] = []
                    for (i, accessory) in garages.enumerated() {
                        map[i] = accessory.id
                        doors.append(GarageDoor(channel: i, name: accessory.name, isOpen: accessory.garageIsOpen ?? false))
                    }
                    state.garageHomeKitAccessoryIds = map
                    // Don't clobber an in-flight optimistic/settling door with a stale re-read.
                    for i in doors.indices where state.garageSettling[doors[i].channel] != nil {
                        if let live = state.garageDoors.first(where: { $0.channel == doors[i].channel }) {
                            doors[i] = live
                        }
                    }
                    state.garageDoors = doors
                }
                return .none

            case let .homekitToggleOutlet(accessoryId):
                guard let inventory = state.homekitInventory,
                      let accessory = inventory.accessories.first(where: { $0.id == accessoryId }) else { return .none }
                let newOn = !(accessory.powerIsOn ?? false)
                let serviceType: HKServiceType = accessory.hasService(.outlet) ? .outlet : .switch
                Self.optimisticallySet(&state.homekitInventory, accessoryId: accessoryId, type: .powerState, value: .bool(newOn))
                let config = state.homekitConfig
                return .run { send in
                    do { try await homekit.setCharacteristic(config, accessoryId, serviceType, .powerState, .bool(newOn)) }
                    catch { await send(.writeFailed); await send(.homekitLoad) }   // toast + truth-restore
                }

            case let .homekitLockRequested(accessoryId):
                // Locking (securing) is safe — no confirmation.
                return .send(.commitHomeKitLock(accessoryId: accessoryId, secured: true))

            case let .homekitUnlockRequested(accessoryId):
                // Unlocking is a security action — always route through the confirmation dialog.
                state.confirmingHomeKitUnlock = accessoryId
                return .none

            case .cancelHomeKitUnlock:
                state.confirmingHomeKitUnlock = nil
                return .none

            case .confirmHomeKitUnlock:
                guard let accessoryId = state.confirmingHomeKitUnlock else { return .none }
                state.confirmingHomeKitUnlock = nil
                return .send(.commitHomeKitLock(accessoryId: accessoryId, secured: false))

            case let .commitHomeKitLock(accessoryId, secured):
                // Optimistic: reflect the new lock state locally (currentLockState: 1 secured / 0 unsecured).
                Self.optimisticallySet(&state.homekitInventory, accessoryId: accessoryId, type: .currentLockState, value: .int(secured ? 1 : 0))
                let config = state.homekitConfig
                return .run { send in
                    do { try await homekit.setCharacteristic(config, accessoryId, .lockMechanism, .targetLockState, .int(secured ? 1 : 0)) }
                    catch { await send(.writeFailed); await send(.homekitLoad) }   // toast + truth-restore
                }

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
                    catch { await send(.writeFailed); await send(.refresh) }   // toast + truth-restore
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
                    catch { await send(.writeFailed); await send(.refresh) }
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

            case .allLightsOff:
                return Self.turnAllLightsOff(&state, hue: hue)

            case .goodnight:
                // All-off, then recall the curated night/bedtime ritual (if any) so "Goodnight" lands the
                // house on its bedtime look rather than pitch dark.
                let off = Self.turnAllLightsOff(&state, hue: hue)
                guard let ritual = state.nightRitual else { return off }
                return .merge(
                    off,
                    .send(.recallScene(bridgeId: ritual.bridgeId, groupId: ritual.groupId, sceneId: ritual.sceneId))
                )

            case .writeFailed:
                state.writeErrorTick += 1
                return .none
            }
        }
    }

    /// Turn every Hue room/zone group off — the shared body of "All lights off" and "Goodnight". Flips
    /// room `anyOn` + member-light `isOn` optimistically, then fires one `setGroupState(off)` per group
    /// across every reachable bridge (reusing the exact verb the P14 agent harness wraps).
    private static func turnAllLightsOff(_ state: inout State, hue: HueClient) -> Effect<Action> {
        var effects: [Effect<Action>] = []
        for bi in state.bridges.indices {
            guard let bridge = state.config.bridge(state.bridges[bi].bridge.bridgeId) else { continue }
            for ri in state.bridges[bi].rooms.indices {
                state.bridges[bi].rooms[ri].anyOn = false
                let roomId = state.bridges[bi].rooms[ri].id
                effects.append(.run { send in
                    do { try await hue.setGroupState(bridge, roomId, false, nil) }
                    catch { await send(.writeFailed); await send(.refresh) }
                })
            }
            for li in state.bridges[bi].lights.indices where state.bridges[bi].lights[li].reachable {
                state.bridges[bi].lights[li].isOn = false
            }
        }
        return effects.isEmpty ? .none : .merge(effects)
    }

    /// Optimistically rewrite one characteristic's value across every matching service on a HomeKit
    /// accessory (value types are immutable, so we rebuild in place). Used so a plug toggle / lock action
    /// reflects instantly before the write lands; a failed write silently re-reads truth.
    static func optimisticallySet(_ inventory: inout HKInventory?, accessoryId: String, type: HKCharacteristicType, value: HKCharacteristicValue) {
        guard var inv = inventory,
              let ai = inv.accessories.firstIndex(where: { $0.id == accessoryId }) else { return }
        let accessory = inv.accessories[ai]
        let services = accessory.services.map { service -> HKService in
            guard service.characteristics.contains(where: { $0.type == type }) else { return service }
            let chars = service.characteristics.map { ch in
                ch.type == type
                    ? HKCharacteristicSnapshot(id: ch.id, type: ch.type, value: value, isWritable: ch.isWritable)
                    : ch
            }
            return HKService(id: service.id, type: service.type, name: service.name, characteristics: chars)
        }
        inv.accessories[ai] = HKAccessory(
            id: accessory.id, name: accessory.name, room: accessory.room,
            category: accessory.category, services: services, isReachable: accessory.isReachable
        )
        inventory = inv
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
