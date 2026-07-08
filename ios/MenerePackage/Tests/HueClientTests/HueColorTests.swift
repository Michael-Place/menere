import Foundation
import Testing

@testable import HueClient

/// Locks the P16 Hue color layer: the pure `HueColor` math, the capability-aware fixtures, and the
/// stateful mock store's optimistic color application (color/ct writes reflect on a re-read with no
/// hardware).
struct HueColorTests {
    // MARK: HueColor math

    @Test func miredsKelvinRoundTripsWithinBounds() {
        // 6500K ≈ 153 mireds (cool), 2700K ≈ 370 mireds (warm).
        #expect(HueColor.kelvin(fromMireds: 153) == 6536)
        #expect(HueColor.mireds(fromKelvin: 6536) == 153)
        // Out-of-range Kelvin clamps into Hue's mired window.
        #expect(HueColor.mireds(fromKelvin: 100) == HueColor.maxMireds)
        #expect(HueColor.mireds(fromKelvin: 100_000) == HueColor.minMireds)
    }

    @Test func warmCoolSliderMapsEndpoints() {
        // 0 = warmest (max mireds), 1 = coolest (min mireds).
        #expect(HueColor.mireds(fromWarmCool: 0) == HueColor.maxMireds)
        #expect(HueColor.mireds(fromWarmCool: 1) == HueColor.minMireds)
        // Round-trips back to the slider position.
        #expect(HueColor.warmCool(fromMireds: HueColor.maxMireds) == 0)
        #expect(HueColor.warmCool(fromMireds: HueColor.minMireds) == 1)
        #expect(HueColor.warmCool(fromMireds: nil) == nil)
    }

    @Test func presetsAreNonEmptyAndInHueRange() {
        #expect(!HueColor.presets.isEmpty)
        for preset in HueColor.presets {
            #expect((0...65535).contains(preset.hue))
            #expect((0...254).contains(preset.saturation))
        }
    }

    // MARK: Capability-aware fixtures

    @Test func fixturesSeedColorAmbianceAndPlainBulbs() {
        let lights = HueFixtures.lights(for: "")
        func light(_ id: String) -> HueLight { lights.first { $0.id == id }! }

        // Full color (extended color light).
        let ceiling = light("1")
        #expect(ceiling.supportsColor)
        #expect(ceiling.colorMode == .hs)
        #expect(ceiling.hue != nil && ceiling.saturation != nil)

        // Tunable white only (ambiance) — CT, but not full color.
        let counter = light("3")
        #expect(counter.supportsColorTemp)
        #expect(!counter.supportsColor)
        #expect(counter.colorMode == .ct)
        #expect(counter.colorTemp != nil)
        #expect(counter.colorTempKelvin != nil)

        // Plain dimmable white — no color capability at all.
        let sink = light("4")
        #expect(!sink.supportsColor)
        #expect(!sink.supportsColorTemp)
        #expect(sink.colorMode == .none)
    }

    // MARK: Mock store optimism

    @Test func mockStoreAppliesHueSatOptimistically() async {
        let store = HueMockStore()
        // Oliver's lamp (5) starts off; a color write turns it on and records hs state.
        await store.setLight(bridgeId: "b", lightId: "5", on: nil, brightness: nil,
                             color: .hueSat(hue: 46920, saturation: 254))
        let lights = await store.lights(for: "b")
        let lamp = lights.first { $0.id == "5" }!
        #expect(lamp.colorMode == .hs)
        #expect(lamp.hue == 46920)
        #expect(lamp.saturation == 254)
        #expect(lamp.isOn)   // a color change implies power-on
    }

    @Test func mockStoreAppliesColorTempOptimistically() async {
        let store = HueMockStore()
        await store.setLight(bridgeId: "b", lightId: "3", on: nil, brightness: nil,
                             color: .colorTemp(mireds: 300))
        let counter = await store.lights(for: "b").first { $0.id == "3" }!
        #expect(counter.colorMode == .ct)
        #expect(counter.colorTemp == 300)
    }
}
