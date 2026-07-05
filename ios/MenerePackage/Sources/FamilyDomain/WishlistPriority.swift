import Foundation

/// How much someone wants a wishlist buy (P30.5). Drives the priority chip + sort order on the
/// wishlist detail (high first, then unbought-first). Color is chosen in the view layer
/// (FamilyDomain stays UI-free), keyed off the case.
///
/// Decode-safe on `ListItem.priority` (an optional). A `nil`/unknown value sorts after any
/// explicit priority and shows no chip.
public enum WishlistPriority: String, Codable, CaseIterable, Sendable, Equatable {
    case high
    case medium
    case low

    public var displayName: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    public var icon: String {
        switch self {
        case .high: "exclamationmark.2"
        case .medium: "exclamationmark"
        case .low: "minus"
        }
    }

    /// Sort rank — high priority floats to the top. `nil` priorities sort after all of these.
    public var sortRank: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }
}
