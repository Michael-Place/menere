import Foundation

/// A packing bucket used to group items on a specialized packing list (P30.5). Mirrors the
/// `GroceryCategory` pattern: `sortOrder` gives the sections a sensible top-to-bottom order,
/// `displayName`/`icon` drive the grouped packing-detail section headers.
///
/// Decode-safe on `ListItem.packingCategory` (an optional). A `nil`/unknown value renders under
/// `.misc` via `ListItem.effectivePackingCategory`.
public enum PackingCategory: String, Codable, CaseIterable, Sendable, Equatable {
    case clothes
    case toiletries
    case documents
    case kidGear
    case electronics
    case medications
    case misc

    public var displayName: String {
        switch self {
        case .clothes: "Clothes"
        case .toiletries: "Toiletries"
        case .documents: "Documents"
        case .kidGear: "Kid gear"
        case .electronics: "Electronics"
        case .medications: "Medications"
        case .misc: "Everything else"
        }
    }

    public var icon: String {
        switch self {
        case .clothes: "tshirt"
        case .toiletries: "shower"
        case .documents: "doc.text"
        case .kidGear: "stroller"
        case .electronics: "cable.connector"
        case .medications: "pills"
        case .misc: "bag"
        }
    }

    /// Order the packing sections appear in (essentials first, catch-all last).
    public var sortOrder: Int {
        switch self {
        case .documents: 0
        case .clothes: 1
        case .toiletries: 2
        case .medications: 3
        case .kidGear: 4
        case .electronics: 5
        case .misc: 6
        }
    }
}
