import Foundation

/// A grocery-store aisle / category used to group items on a specialized grocery list.
///
/// Ported from Fambo's `GroceryCategory` (P30). `aisleOrder` reflects a typical store walk so
/// grouped grocery lists read top-to-bottom in shopping order. `displayName`/`icon` drive the
/// section headers in the aisle-grouped grocery detail UI.
public enum GroceryCategory: String, Codable, CaseIterable, Sendable, Equatable {
    case produce
    case dairy
    case meat
    case seafood
    case bakery
    case frozen
    case pantry
    case beverages
    case snacks
    case deli
    case household
    case health
    case baby
    case pets
    case other

    public var displayName: String {
        switch self {
        case .produce: "Produce"
        case .dairy: "Dairy & Eggs"
        case .meat: "Meat & Poultry"
        case .seafood: "Seafood"
        case .bakery: "Bakery"
        case .frozen: "Frozen"
        case .pantry: "Pantry"
        case .beverages: "Beverages"
        case .snacks: "Snacks"
        case .deli: "Deli"
        case .household: "Household"
        case .health: "Health & Beauty"
        case .baby: "Baby"
        case .pets: "Pets"
        case .other: "Other"
        }
    }

    public var icon: String {
        switch self {
        case .produce: "leaf"
        case .dairy: "cup.and.saucer"
        case .meat: "fork.knife"
        case .seafood: "fish"
        case .bakery: "birthday.cake"
        case .frozen: "snowflake"
        case .pantry: "cabinet"
        case .beverages: "mug"
        case .snacks: "popcorn"
        case .deli: "takeoutbag.and.cup.and.straw"
        case .household: "house"
        case .health: "heart"
        case .baby: "stroller"
        case .pets: "pawprint"
        case .other: "bag"
        }
    }

    /// Sort order matching a typical grocery store aisle layout.
    public var aisleOrder: Int {
        switch self {
        case .produce: 0
        case .bakery: 1
        case .deli: 2
        case .meat: 3
        case .seafood: 4
        case .dairy: 5
        case .frozen: 6
        case .pantry: 7
        case .snacks: 8
        case .beverages: 9
        case .household: 10
        case .health: 11
        case .baby: 12
        case .pets: 13
        case .other: 14
        }
    }
}
