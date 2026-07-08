import FamilyDomain
import Foundation
import SwiftUI

// Client-surface value types for the "house" card. These describe *live* bridge state (rooms,
// lights, scenes, sensor temps) — the identity/mapping half lives in `FamilyDomain.HueConfig`.
// All are Foundation-clean, Sendable, and Equatable so they flow through TCA state.

/// A freshly-paired bridge's identity + friendly name, read from `/config` during pairing (P12-C3).
/// The name (e.g. "Downstairs Hub") is stored in `HueBridgeConfig.name` and shown in Settings.
public struct HueBridgeInfo: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One reachable bridge's live state, produced by `HueClient.readBridge`. The Today "house" card
/// aggregates these across all reachable bridges (P12-C3): temps merge, lights sum, and each
/// ritual's button renders only when *its* bridge produced a snapshot.
public struct BridgeSnapshot: Equatable, Sendable, Identifiable {
    public var bridge: HueBridgeConfig
    public var rooms: [HueRoom]
    public var lights: [HueLight]
    public var scenes: [HueScene]
    public var temperatures: [HueTemperature]

    public var id: String { bridge.bridgeId }

    public init(
        bridge: HueBridgeConfig,
        rooms: [HueRoom] = [],
        lights: [HueLight] = [],
        scenes: [HueScene] = [],
        temperatures: [HueTemperature] = []
    ) {
        self.bridge = bridge
        self.rooms = rooms
        self.lights = lights
        self.scenes = scenes
        self.temperatures = temperatures
    }
}

/// A Hue V1 group we treat as a room/zone.
public struct HueRoom: Equatable, Sendable, Identifiable {
    /// The V1 group id.
    public let id: String
    public let name: String
    /// Raw V1 group type ("Room" / "Zone").
    public let type: String
    /// V1 light ids belonging to this group.
    public let lightIds: [String]
    /// Whether any light in the group is currently on. `var` so the House surface can flip it
    /// optimistically before the write lands.
    public var anyOn: Bool
    /// Group brightness 1–254 (Hue V1 group `action.bri`) — the last-set group level, used by the
    /// House room-detail slider. Nil when the bridge reports none.
    public var brightness: Int?

    public init(id: String, name: String, type: String, lightIds: [String], anyOn: Bool, brightness: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.lightIds = lightIds
        self.anyOn = anyOn
        self.brightness = brightness
    }
}

/// How a Hue bulb is currently expressing color (Hue V1 `state.colormode`). `.none` covers plain
/// dimmable / on-off bulbs that carry no color at all.
public enum HueColorMode: String, Equatable, Sendable {
    case hs   // hue + saturation
    case xy   // CIE xy chromaticity
    case ct   // color temperature (mireds)
    case none
}

/// A single Hue light's state. The card needs only on-ness + name; the House surface (P12-C4) also
/// needs brightness (for the per-light slider) and reachability (unreachable lights dim + disable).
/// P16 adds **color**: capability flags (`supportsColor` / `supportsColorTemp`) so the UI shows a
/// control only on a bulb that can honor it, plus the current color state (hue/sat, xy, or mireds)
/// and a computed SwiftUI ``swatchColor`` for the row swatch + picker binding. A plain white bulb
/// decodes to `.none` / both flags false and renders exactly as before.
public struct HueLight: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// `var` so House rows flip optimistically ahead of the write.
    public var isOn: Bool
    /// Current brightness 1–254 (Hue V1 `state.bri`); nil when the light isn't dimmable / reports none.
    public var brightness: Int?
    /// Whether the bridge can currently reach the light (V1 `state.reachable`). Unreachable lights
    /// render ink-soft with disabled controls.
    public var reachable: Bool

    // MARK: Color (P16) — all optimistically mutable so the House surface can preview a change.

    /// Which color model the bulb is currently expressing (V1 `state.colormode`). `.none` for plain bulbs.
    public var colorMode: HueColorMode
    /// Hue 0–65535 (V1 `state.hue`) when in/for `hs` mode; nil on non-color bulbs.
    public var hue: Int?
    /// Saturation 0–254 (V1 `state.sat`) when in/for `hs` mode; nil on non-color bulbs.
    public var saturation: Int?
    /// CIE xy chromaticity [x, y] (V1 `state.xy`) when in `xy` mode; nil otherwise.
    public var xy: [Double]?
    /// Color temperature in **mireds** (V1 `state.ct`, ~153 cool → 500 warm); nil on non-CT bulbs.
    public var colorTemp: Int?
    /// True when the bulb can render arbitrary color (hue/sat or xy). Capability, so `let`.
    public let supportsColor: Bool
    /// True when the bulb can render tunable white (color temperature). Capability, so `let`.
    public let supportsColorTemp: Bool

    public init(
        id: String,
        name: String,
        isOn: Bool,
        brightness: Int? = nil,
        reachable: Bool = true,
        colorMode: HueColorMode = .none,
        hue: Int? = nil,
        saturation: Int? = nil,
        xy: [Double]? = nil,
        colorTemp: Int? = nil,
        supportsColor: Bool = false,
        supportsColorTemp: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isOn = isOn
        self.brightness = brightness
        self.reachable = reachable
        self.colorMode = colorMode
        self.hue = hue
        self.saturation = saturation
        self.xy = xy
        self.colorTemp = colorTemp
        self.supportsColor = supportsColor
        self.supportsColorTemp = supportsColorTemp
    }

    /// The current color temperature expressed in **Kelvin** (the family-friendly unit), derived from
    /// `colorTemp` mireds. Nil when the bulb reports no CT.
    public var colorTempKelvin: Int? {
        colorTemp.map { HueColor.kelvin(fromMireds: $0) }
    }

    /// A SwiftUI `Color` approximating what the bulb is showing — for the row swatch and the color
    /// picker's binding. Renders the *hue* at full legibility (not dimmed by brightness) so the swatch
    /// stays readable. Plain bulbs (no color state) fall back to a soft warm white.
    public var swatchColor: Color {
        switch colorMode {
        case .hs:
            if let hue, let saturation {
                return HueColor.color(hue: hue, saturation: saturation)
            }
        case .xy:
            if let xy, xy.count == 2 {
                return HueColor.color(fromXY: xy[0], xy[1])
            }
        case .ct:
            if let colorTemp {
                return HueColor.color(fromMireds: colorTemp)
            }
        case .none:
            break
        }
        // A capable bulb with no reported color yet (or a plain bulb) → warm white.
        return HueColor.color(fromMireds: 366)
    }
}

/// A single color write for one light — the payload the House color picker / warm-cool slider hands to
/// `HueClient.setLightState`. Three shapes mirror the V1 `state` keys the bridge accepts (`hue`+`sat`,
/// `xy`, or `ct`); the P14 agent tools resolve "make the lamp teal" / "warm the kitchen" through the
/// same value.
public enum HueColorCommand: Equatable, Sendable {
    case hueSat(hue: Int, saturation: Int)
    case xy(x: Double, y: Double)
    case colorTemp(mireds: Int)
}

/// Pure color math: mireds↔Kelvin, the warm→cool slider mapping, and approximate Hue-state→`Color`
/// conversions for the swatch. Deliberately view/reducer-free (like ``HueBrightness``) so the UI, the
/// mock store, and any future agent tool all convert identically.
public enum HueColor {
    /// Hue's color-temperature bounds (mireds). 153 ≈ 6500K (cool), 500 ≈ 2000K (warm).
    public static let minMireds = 153
    public static let maxMireds = 500

    /// Curated on-brand color presets for the per-light palette: a readable spread across the wheel.
    /// Each is a (hue 0–65535, sat 0–254) pair the picker sends verbatim.
    public static let presets: [(name: String, hue: Int, saturation: Int)] = [
        ("Red", 0, 254),
        ("Orange", 4500, 240),
        ("Amber", 8000, 210),
        ("Green", 25500, 240),
        ("Teal", 39000, 210),
        ("Blue", 46920, 254),
        ("Violet", 50400, 230),
        ("Pink", 56100, 200),
    ]

    // MARK: Mireds ↔ Kelvin

    public static func kelvin(fromMireds mireds: Int) -> Int {
        guard mireds > 0 else { return 0 }
        return Int((1_000_000.0 / Double(mireds)).rounded())
    }

    public static func mireds(fromKelvin kelvin: Int) -> Int {
        guard kelvin > 0 else { return maxMireds }
        let m = Int((1_000_000.0 / Double(kelvin)).rounded())
        return min(maxMireds, max(minMireds, m))
    }

    // MARK: Warm→cool slider (0 = warmest, 1 = coolest)

    /// Slider position 0…1 (warm→cool) → mireds (warm = high mireds, cool = low), clamped.
    public static func mireds(fromWarmCool t: Double) -> Int {
        let clamped = min(1, max(0, t))
        let m = Double(maxMireds) - clamped * Double(maxMireds - minMireds)
        return min(maxMireds, max(minMireds, Int(m.rounded())))
    }

    /// Mireds → slider position 0…1 (warm→cool). Nil mireds → nil.
    public static func warmCool(fromMireds mireds: Int?) -> Double? {
        guard let mireds else { return nil }
        let clamped = min(maxMireds, max(minMireds, mireds))
        return Double(maxMireds - clamped) / Double(maxMireds - minMireds)
    }

    // MARK: State → Color

    /// Hue `hue`/`sat` (0–65535 / 0–254) → a full-brightness SwiftUI `Color`.
    public static func color(hue: Int, saturation: Int) -> Color {
        Color(
            hue: min(1, max(0, Double(hue) / 65535.0)),
            saturation: min(1, max(0, Double(saturation) / 254.0)),
            brightness: 1.0
        )
    }

    /// CIE xy (D65, Wide-gamut) → sRGB `Color`. The standard Philips inverse-gamma conversion at full
    /// luminance (Y = 1) so the swatch reads at full legibility.
    public static func color(fromXY x: Double, _ y: Double) -> Color {
        guard y > 0 else { return color(fromMireds: 366) }
        let z = 1.0 - x - y
        let Y = 1.0
        let X = (Y / y) * x
        let Z = (Y / y) * z
        // Wide RGB D65 conversion matrix.
        var r = X * 1.656492 - Y * 0.354851 - Z * 0.255038
        var g = -X * 0.707196 + Y * 1.655397 + Z * 0.036152
        var b = X * 0.051713 - Y * 0.121364 + Z * 1.011530
        // Reverse gamma correction.
        func gamma(_ c: Double) -> Double {
            let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055
            return min(1, max(0, v))
        }
        r = gamma(r); g = gamma(g); b = gamma(b)
        // Normalize so the brightest channel is 1 (keeps the hue, maximizes legibility).
        let maxC = max(r, max(g, b))
        if maxC > 0 { r /= maxC; g /= maxC; b /= maxC }
        return Color(red: r, green: g, blue: b)
    }

    /// Mireds → an approximate warm/cool white `Color` (Tanner Helland's black-body approximation).
    public static func color(fromMireds mireds: Int) -> Color {
        let kelvin = Double(kelvin(fromMireds: mireds))
        let temp = min(40000, max(1000, kelvin)) / 100.0
        var r, g, b: Double
        // Red
        if temp <= 66 { r = 255 } else {
            r = 329.698727446 * pow(temp - 60, -0.1332047592)
        }
        // Green
        if temp <= 66 {
            g = 99.4708025861 * log(temp) - 161.1195681661
        } else {
            g = 288.1221695283 * pow(temp - 60, -0.0755148492)
        }
        // Blue
        if temp >= 66 { b = 255 } else if temp <= 19 { b = 0 } else {
            b = 138.5177312231 * log(temp - 10) - 305.0447927307
        }
        func clamp(_ c: Double) -> Double { min(255, max(0, c)) / 255.0 }
        return Color(red: clamp(r), green: clamp(g), blue: clamp(b))
    }
}

/// A recallable Hue V1 scene.
public struct HueScene: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// The group the scene targets, when the bridge reports one.
    public let groupId: String?

    public init(id: String, name: String, groupId: String?) {
        self.id = id
        self.name = name
        self.groupId = groupId
    }
}

/// A bridge found via cloud discovery (`discovery.meethue.com`) during pairing (P12-C2). Just an
/// identity + LAN address — the pairing flow mints an app key against `ip` and confirms `id` via
/// `/config`.
public struct DiscoveredBridge: Equatable, Sendable, Identifiable {
    /// Bridge id (MAC-derived), as reported by cloud discovery.
    public let id: String
    /// The bridge's current LAN IP.
    public let ip: String

    public init(id: String, ip: String) {
        self.id = id
        self.ip = ip
    }
}

/// A ZLLTemperature sensor's identity + bridge name, used by the pairing binding step (P12-C2) to
/// label sensors and capture `sensorNames` for future re-matching. (Distinct from `HueTemperature`,
/// which carries the live reading but not the name.)
public struct HueSensorInfo: Equatable, Sendable, Identifiable {
    public let id: String
    /// The sensor's `name` as reported by the bridge (e.g. "Hue motion sensor 1").
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A ZLLTemperature reading, already converted to °F (the family is US).
public struct HueTemperature: Equatable, Sendable, Identifiable {
    public let sensorId: String
    public let tempF: Double
    /// The sensor's `state.lastupdated` (ISO-ish string) when available.
    public let lastUpdated: String?

    public var id: String { sensorId }

    public init(sensorId: String, tempF: Double, lastUpdated: String?) {
        self.sensorId = sensorId
        self.tempF = tempF
        self.lastUpdated = lastUpdated
    }
}
