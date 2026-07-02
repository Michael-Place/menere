import Foundation

/// Helpers for Lutron shade levels. Unlike Hue brightness (1–254 with a dimmable floor), a Lutron
/// shade **zone Level is already 0–100** (0 = fully closed, 100 = fully open), so the House slider maps
/// straight through — these helpers only clamp and label. Kept pure (no reducer/view) so the P14 agent
/// tools ("open Oliver's shade halfway") resolve a level through the same code the UI uses.
public enum LutronLevel {
    public static let min = 0
    public static let max = 100

    /// Clamp an arbitrary integer to the 0–100 shade range.
    public static func clamp(_ level: Int) -> Int {
        Swift.max(min, Swift.min(max, level))
    }

    /// A human label for a level: "Open" at 100, "Closed" at 0, else "45%".
    public static func label(_ level: Int) -> String {
        switch clamp(level) {
        case Self.max: return "Open"
        case Self.min: return "Closed"
        case let l: return "\(l)%"
        }
    }
}
