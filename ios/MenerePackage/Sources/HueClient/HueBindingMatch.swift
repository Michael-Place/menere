import FamilyDomain
import Foundation

/// Pure name-matching for P12-C2 re-pairing: when a bridge dies and gets replaced, the family's
/// *meanings* (which scene is "Bedtime", which sensor is the nursery) live in Firestore but the
/// underlying Hue IDs change. These helpers re-bind meaning → new IDs by NAME, so a re-pair rarely
/// needs manual picking. No UI, no network — trivially unit-testable and shared by the pairing
/// sheet's binding step and the Settings status rows.
public enum HueBindingMatch {
    /// The two rituals every household gets offered at pairing time, even on a brand-new bridge.
    /// (Re-pairs additionally carry forward whatever rituals the old config already had.)
    public static let standardRituals: [(key: String, label: String)] = [
        (key: "bedtime", label: "Bedtime"),
        (key: "dinner", label: "Dinner's ready"),
    ]

    /// Auto-match a scene to a ritual by name. A scene matches when its name (case-insensitively)
    /// contains the ritual key or any significant word (≥4 letters) of the ritual label — so
    /// "Cozy Bedtime" binds `bedtime`, and "Dinner time" binds `dinner` / "Dinner's ready".
    /// Returns the first matching scene in the given order, or nil when nothing matches.
    public static func matchScene(key: String, label: String, in scenes: [HueScene]) -> HueScene? {
        let needles = sceneNeedles(key: key, label: label)
        return scenes.first { scene in
            let name = scene.name.lowercased()
            return needles.contains { name.contains($0) }
        }
    }

    /// The lowercased tokens a scene name is tested against: the ritual key plus each ≥4-letter word
    /// of the label (apostrophes/punctuation split words, so "Dinner's" → "dinner").
    public static func sceneNeedles(key: String, label: String) -> [String] {
        var needles = [key.lowercased()]
        for token in label.lowercased().split(whereSeparator: { !$0.isLetter }) where token.count >= 4 {
            needles.append(String(token))
        }
        return needles
    }

    /// The label to prefill for a freshly-discovered sensor when re-pairing: look up the old config's
    /// captured `sensorNames` for a sensor whose name matches `sensorName` (exact, case-insensitive,
    /// else substring either way) and carry its old label forward. Empty string when there's nothing
    /// to carry (first pairing, or a genuinely new sensor).
    public static func prefillSensorLabel(for sensorName: String, from existing: HueConfig?) -> String {
        guard let existing, let names = existing.sensorNames, !names.isEmpty else { return "" }
        let target = sensorName.lowercased()
        let match = names.first { $0.value.lowercased() == target }
            ?? names.first {
                let old = $0.value.lowercased()
                return target.contains(old) || old.contains(target)
            }
        guard let (oldSensorId, _) = match else { return "" }
        return existing.sensorLabels[oldSensorId] ?? ""
    }
}
