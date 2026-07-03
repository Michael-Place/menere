import ComposableArchitecture
import FamilyDomain
import Foundation
import HomeKitClient
import HubspaceClient
import HueClient
import LutronClient
import MerossClient
import NestClient
import PersistenceClient
import SonosClient
import UserDomain

/// Backing store for the Home tab's **Smart home** overview card (P16). It loads exactly the data the
/// Today "The house" card uses — the Hue config + one live `BridgeSnapshot` per reachable bridge, plus
/// the optional Lutron/Sonos/Nest/Hubspace/Meross/HomeKit configs — so tapping the card can seed the
/// exact same ``HouseView`` control screen Today pushes.
///
/// Deliberately self-contained and embeddable via `Scope` (see `ChoresReducer`): it never touches the
/// parent's state and re-reads independently, mirroring how Today loads the same pieces inline. The
/// card **shows whenever a Hue config doc exists** (`isConfigured`) — a config-existence gate, NOT a
/// reachability gate, so the card stays put when you're away from home (unlike Today's live glance).
@Reducer
public struct HouseCardReducer {
    @ObservableState
    public struct State: Equatable {
        /// The Hue config (nil = never paired ⇒ no card). Its presence gates the whole card.
        public var config: HueConfig?
        /// Live per-reachable-bridge snapshot (empty when away/unreachable — the card still shows,
        /// falling back to a capability summary). Seeds ``HouseView`` for an instant first paint.
        public var bridges: [BridgeSnapshot] = []
        /// Roster, for the control screen's room-owner avatars.
        public var members: [HouseholdMember] = []
        public var lutronConfig: LutronConfig?
        public var sonosConfig: SonosConfig?
        public var nestConfig: NestConfig?
        public var hubspaceConfig: HubspaceConfig?
        public var merossConfig: MerossConfig?
        public var homekitConfig: HomeKitConfig?
        /// Guards against redundant reloads when the hub re-appears.
        public var didLoad = false

        public init() {}

        /// The card shows only when Hue is configured (≥1 bridge doc) — same "no config ⇒ no card"
        /// rule as Today, but gated on the config's *existence* rather than live reachability.
        public var isConfigured: Bool {
            guard let config else { return false }
            return !config.bridges.isEmpty
        }

        /// The one-line glance: live "N lights on · 72°" when a bridge answered, else a capability
        /// summary ("Lights, shades & climate") so the card reads sensibly when away from home.
        public var statusLine: String {
            if !bridges.isEmpty {
                let onCount = bridges.flatMap(\.lights).filter(\.isOn).count
                var parts = [onCount == 0 ? "All lights off" : "\(onCount) light\(onCount == 1 ? "" : "s") on"]
                if let temp = firstTemperature { parts.append("\(Int(temp.rounded()))°") }
                return parts.joined(separator: " · ")
            }
            var caps = ["lights"]
            if lutronConfig != nil { caps.append("shades") }
            if nestConfig != nil { caps.append("climate") }
            if sonosConfig != nil { caps.append("speakers") }
            let shown = caps.prefix(3).joined(separator: ", ")
            return "Control \(shown)"
        }

        /// First labeled temperature (°F) across reachable bridges, if any — mirrors the Today card's
        /// label-scoped sensor read.
        private var firstTemperature: Double? {
            guard let config else { return nil }
            for snap in bridges {
                let labels = config.sensorLabels(for: snap.bridge.bridgeId)
                for t in snap.temperatures where labels[t.sensorId] != nil {
                    return t.tempF
                }
            }
            return nil
        }
    }

    public enum Action: Equatable {
        case load
        case loaded(
            config: HueConfig?, bridges: [BridgeSnapshot], members: [HouseholdMember],
            lutron: LutronConfig?, sonos: SonosConfig?, nest: NestConfig?,
            hubspace: HubspaceConfig?, meross: MerossConfig?, homekit: HomeKitConfig?
        )
    }

    public init() {}

    @Dependency(\.persistence) var persistence
    @Dependency(\.hue) var hue

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .load:
                guard !state.didLoad, let hid = hid() else { return .none }
                state.didLoad = true
                return .run { send in
                    // All reads independently resilient — a missing/failed config degrades to nil.
                    async let hueCfg = persistence.hueConfig(hid)
                    async let members = persistence.members(hid)
                    async let lutron = persistence.lutronConfig(hid)
                    async let sonos = persistence.sonosConfig(hid)
                    async let nest = persistence.nestConfig(hid)
                    async let hubspace = persistence.hubspaceConfig(hid)
                    async let meross = persistence.merossConfig(hid)
                    async let homekit = persistence.homekitConfig(hid)

                    let config = (try? await hueCfg) ?? nil
                    var bridges: [BridgeSnapshot] = []
                    if let config, !config.bridges.isEmpty {
                        bridges = await hue.readHouse(config.bridges)
                            .sorted { $0.bridge.bridgeId < $1.bridge.bridgeId }
                    }
                    await send(.loaded(
                        config: config, bridges: bridges,
                        members: (try? await members) ?? [],
                        lutron: (try? await lutron) ?? nil,
                        sonos: (try? await sonos) ?? nil,
                        nest: (try? await nest) ?? nil,
                        hubspace: (try? await hubspace) ?? nil,
                        meross: (try? await meross) ?? nil,
                        homekit: (try? await homekit) ?? nil
                    ))
                }

            case let .loaded(config, bridges, members, lutron, sonos, nest, hubspace, meross, homekit):
                state.config = config
                state.bridges = bridges
                state.members = members
                state.lutronConfig = lutron
                state.sonosConfig = sonos
                state.nestConfig = nest
                state.hubspaceConfig = hubspace
                state.merossConfig = meross
                state.homekitConfig = homekit
                return .none
            }
        }
    }
}
