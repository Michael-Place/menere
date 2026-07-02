import Foundation

/// Pure conversions between a 0–100% UI slider value and Hue's 1–254 `bri` scale. Deliberately
/// free of any reducer/view — the House sliders map through it, and the P14 agent tools ("dim the
/// kitchen to 30%") resolve a percentage to `bri` through the exact same helper.
public enum HueBrightness {
    /// Hue's brightness bounds (0 is *off*, so the dimmable floor is 1).
    public static let minBri = 1
    public static let maxBri = 254

    /// A percentage (0–100) → Hue `bri` (1–254), clamped. 0% maps to the dimmable floor (1), not
    /// power-off — callers that mean "off" send `on: false` separately.
    public static func bri(fromPercent percent: Double) -> Int {
        let clamped = min(100, max(0, percent))
        let scaled = Int((clamped / 100.0 * Double(maxBri - minBri)).rounded()) + minBri
        return min(maxBri, max(minBri, scaled))
    }

    /// Hue `bri` (1–254) → percentage (0–100), rounded. Nil `bri` → nil (unknown level).
    public static func percent(fromBri bri: Int?) -> Double? {
        guard let bri else { return nil }
        let clamped = min(maxBri, max(minBri, bri))
        return Double(clamped - minBri) / Double(maxBri - minBri) * 100.0
    }
}
