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
#endif
