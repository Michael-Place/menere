import FamilyDomain
import Foundation

/// How one ritual button should render: which ritual, and whether it's *prominent* (filled) vs.
/// subdued (tinted).
public struct RitualPresentation: Equatable, Sendable, Identifiable {
    public let ritual: HueRitual
    public let isProminent: Bool
    public var id: String { ritual.key }

    public init(ritual: HueRitual, isProminent: Bool) {
        self.ritual = ritual
        self.isProminent = isProminent
    }
}

/// Pure ordering/prominence logic for the ritual buttons — a function of the clock and the meal
/// plan only, so it's trivially unit-testable and has no UI/network dependency.
///
/// Shipped rule:
///   • **Bedtime** (`key == "bedtime"`) becomes prominent **and first** at/after 18:00 local.
///     Before 18:00 it's subdued and sorts after the prominent buttons.
///   • **Dinner** (`key == "dinner"`) is prominent when tonight's meal plan has a home-cooked
///     entry (a recipe, not eating-out); otherwise subdued.
///   • Any other ritual is subdued by default.
///   • Ordering: in the evening, Bedtime is forced to the front; otherwise prominent buttons come
///     first, then subdued, each preserving the config's declared order (a stable sort).
public enum HueRitualLayout {
    public static let bedtimeKey = "bedtime"
    public static let dinnerKey = "dinner"
    /// The hour (local, 24h) at/after which Bedtime is promoted to first + filled.
    public static let eveningHour = 18

    /// Whether it's "evening" (Bedtime-prominent time) for `now` in `calendar`.
    public static func isEvening(_ now: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.hour, from: now) >= eveningHour
    }

    public static func ordered(
        rituals: [HueRitual],
        now: Date,
        homeCookedDinner: Bool,
        calendar: Calendar = .current
    ) -> [RitualPresentation] {
        let evening = isEvening(now, calendar: calendar)

        func prominent(_ r: HueRitual) -> Bool {
            switch r.key {
            case bedtimeKey: return evening
            case dinnerKey:  return homeCookedDinner
            default:         return false
            }
        }

        func rank(_ r: HueRitual) -> Int {
            if evening && r.key == bedtimeKey { return 0 }   // Bedtime forced to front after 18:00
            return prominent(r) ? 1 : 2                       // prominent, then subdued
        }

        // Stable sort by rank (enumerate to break ties by declared order).
        return rituals.enumerated()
            .sorted { a, b in
                let ra = rank(a.element), rb = rank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map { RitualPresentation(ritual: $0.element, isProminent: prominent($0.element)) }
    }
}
