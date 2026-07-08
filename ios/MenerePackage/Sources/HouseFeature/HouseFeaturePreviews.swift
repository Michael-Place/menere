#if DEBUG
import ComposableArchitecture
import FamilyDomain
import HomeKitClient
import HubspaceClient
import HueClient
import LutronClient
import MenereUI
import MerossClient
import NestClient
import SonosClient
import SwiftUI

// Previews for the Wave 1 House surface. Each seeds a config-only `HouseReducer` (the sub-clients'
// `previewValue`s serve the believable "Place house" fixtures) so `.task` populates the sections against
// the mock stores — the hardware-free render path. Dependency overrides carve out the loading / empty /
// offline states.

private struct PreviewError: Error {}

/// A believable fully-configured house — Hue mock bridge (+ dinner/bedtime rituals + labeled temps),
/// Lutron shades, Sonos, Nest, Hubspace, Meross garage, HomeKit. Renders the glance header + every
/// section on the new shared components.
private func fullConfig() -> HueConfig {
    HueConfig(
        bridgeId: "mock",
        bridgeIP: "127.0.0.1",
        applicationKey: "preview",
        rituals: [
            HueRitual(key: "dinner", label: "Dinner", sceneId: "dinner-scene", groupId: "1", bridgeId: "mock"),
            HueRitual(key: "bedtime", label: "Bedtime", sceneId: "bedtime-scene", groupId: "3", bridgeId: "mock"),
        ],
        sensorLabels: ["sensor-oliver": "Oliver", "sensor-famfis": "Famfis"],
        mock: true
    )
}

#Preview("House — full") {
    NavigationStack {
        HouseView(
            config: fullConfig(),
            members: [],
            bridges: [
                BridgeSnapshot(
                    bridge: fullConfig().bridges[0],
                    rooms: HueFixtures.rooms(for: ""),
                    lights: HueFixtures.lights(for: ""),
                    scenes: HueFixtures.scenes(for: ""),
                    temperatures: HueFixtures.temperatures(for: "")
                )
            ],
            lutronConfig: LutronConfig(bridgeIP: "127.0.0.1", mock: true),
            sonosConfig: SonosConfig(mock: true),
            nestConfig: NestConfig(projectId: "p", oauthClientId: "c", mock: true),
            hubspaceConfig: HubspaceConfig(mock: true),
            merossConfig: MerossConfig(mock: true),
            homekitConfig: HomeKitConfig(mock: true)
        )
    }
}

/// The SAME fully-configured house, but with the persisted view mode forced to **Rooms** — so the
/// preview renders the room cards (each mixing a room's light + shade + climate + speaker) and the
/// "Whole house" bucket (water + garage) at the bottom.
#Preview("House — Rooms mode") {
    UserDefaults.standard.set(HouseViewMode.rooms.rawValue, forKey: "house.viewMode")
    return NavigationStack {
        HouseView(
            config: fullConfig(),
            members: [],
            bridges: [
                BridgeSnapshot(
                    bridge: fullConfig().bridges[0],
                    rooms: HueFixtures.rooms(for: ""),
                    lights: HueFixtures.lights(for: ""),
                    scenes: HueFixtures.scenes(for: ""),
                    temperatures: HueFixtures.temperatures(for: "")
                )
            ],
            lutronConfig: LutronConfig(bridgeIP: "127.0.0.1", mock: true),
            sonosConfig: SonosConfig(mock: true),
            nestConfig: NestConfig(projectId: "p", oauthClientId: "c", mock: true),
            hubspaceConfig: HubspaceConfig(mock: true),
            merossConfig: MerossConfig(mock: true),
            homekitConfig: HomeKitConfig(mock: true)
        )
    }
}

#Preview("House — Devices mode") {
    UserDefaults.standard.set(HouseViewMode.devices.rawValue, forKey: "house.viewMode")
    return NavigationStack {
        HouseView(
            config: fullConfig(),
            members: [],
            bridges: [
                BridgeSnapshot(
                    bridge: fullConfig().bridges[0],
                    rooms: HueFixtures.rooms(for: ""),
                    lights: HueFixtures.lights(for: ""),
                    scenes: HueFixtures.scenes(for: ""),
                    temperatures: HueFixtures.temperatures(for: "")
                )
            ],
            lutronConfig: LutronConfig(bridgeIP: "127.0.0.1", mock: true),
            sonosConfig: SonosConfig(mock: true),
            nestConfig: NestConfig(projectId: "p", oauthClientId: "c", mock: true),
            hubspaceConfig: HubspaceConfig(mock: true),
            merossConfig: MerossConfig(mock: true),
            homekitConfig: HomeKitConfig(mock: true)
        )
    }
}

#Preview("House — empty (nothing set up)") {
    let store = withDependencies {
        $0.sonos = .testValue     // no nil-config discovery
        $0.homekit = .testValue   // not authorized → no inventory
    } operation: {
        Store(initialState: HouseReducer.State(config: HueConfig(bridges: []))) { HouseReducer() }
    }
    return NavigationStack { HouseView(store: store) }
}

#Preview("House — offline / away") {
    var hue = HueClient.previewValue
    hue.testConnection = { _ in false }            // bridge unreachable → readHouse returns []
    var lutron = LutronClient.previewValue
    lutron.shades = { _ in throw PreviewError() }  // configured Lutron that didn't answer → Offline badge

    let store = withDependencies {
        $0.hue = hue
        $0.lutron = lutron
        $0.sonos = .testValue
        $0.homekit = .testValue
    } operation: {
        Store(
            initialState: HouseReducer.State(
                config: fullConfig(),
                lutronConfig: LutronConfig(bridgeIP: "127.0.0.1", mock: true)
            )
        ) { HouseReducer() }
    }
    return NavigationStack { HouseView(store: store) }
}

// W2a — the newly-exposed latent states.

/// A COOLING thermostat so the cool (sky) HVAC glow + the interactive mode switcher render (the "full"
/// preview already shows the warm HEATING glow via the heat-mode fixture).
#Preview("House — cooling glow") {
    var nest = NestClient.previewValue
    nest.thermostats = { _ in
        [NestThermostat(
            id: "enterprises/mock/devices/UPSTAIRS", roomName: "Upstairs",
            ambientCelsius: 24.5, humidityPercent: 52, mode: .cool,
            availableModes: [.heat, .cool, .heatCool, .off],
            heatCelsius: NestTemp.fToC(68), coolCelsius: NestTemp.fToC(72),
            hvacStatus: "COOLING"
        )]
    }
    let store = withDependencies {
        $0.nest = nest
        $0.sonos = .testValue
        $0.homekit = .testValue
    } operation: {
        Store(initialState: HouseReducer.State(
            config: HueConfig(bridges: []),
            nestConfig: NestConfig(projectId: "p", oauthClientId: "c", mock: true)
        )) { HouseReducer() }
    }
    return NavigationStack { HouseView(store: store) }
}

/// A **jammed** front-door lock (`currentLockState` 2) + a **stopped** garage door (`currentDoorState`
/// 4) so the jam/stopped surfacing renders — before W2a both silently read "Locked" / a fake settle.
#Preview("House — HomeKit faults (jam / stopped)") {
    let inventory = HKInventory(homeName: "Place House", accessories: [
        HKAccessory(
            id: "garage", name: "Garage Door", room: "Garage",
            category: HKAccessoryCategory("garageDoorOpener"),
            services: [HKService(id: "gs", type: .garageDoorOpener, name: "Garage Door", characteristics: [
                HKCharacteristicSnapshot(id: "gc", type: .currentDoorState, value: .int(4), isWritable: false),   // stopped
                HKCharacteristicSnapshot(id: "gt", type: .targetDoorState, value: .int(1), isWritable: true),
            ])], isReachable: true),
        HKAccessory(
            id: "lock", name: "Front Door", room: "Entry",
            category: HKAccessoryCategory("doorLock"),
            services: [HKService(id: "ls", type: .lockMechanism, name: "Front Door", characteristics: [
                HKCharacteristicSnapshot(id: "lc", type: .currentLockState, value: .int(2), isWritable: false),   // jammed
                HKCharacteristicSnapshot(id: "lt", type: .targetLockState, value: .int(1), isWritable: true),
            ])], isReachable: true),
    ])
    var homekit = HomeKitClient.testValue
    homekit.inventory = { _ in inventory }
    let store = withDependencies {
        $0.homekit = homekit
        $0.sonos = .testValue
    } operation: {
        Store(initialState: HouseReducer.State(
            config: HueConfig(bridges: []),
            homekitConfig: HomeKitConfig(mock: true)   // mock → auth treated authorized, no live prompt
        )) { HouseReducer() }
    }
    return NavigationStack { HouseView(store: store) }
}
#endif
