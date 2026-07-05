import Foundation

/// The kind of residence — gates nothing on its own but colors the copy and drives the setup form.
public enum HomeType: String, Codable, CaseIterable, Sendable, Equatable {
    case house
    case apartment
    case condo
    case townhouse

    public var displayName: String {
        switch self {
        case .house: "House"
        case .apartment: "Apartment"
        case .condo: "Condo"
        case .townhouse: "Townhouse"
        }
    }

    public var icon: String {
        switch self {
        case .house: "house.fill"
        case .apartment: "building.2.fill"
        case .condo: "building.fill"
        case .townhouse: "house.and.flag.fill"
        }
    }
}

/// Rough climate band — informs which seasonal tasks make sense (the Place house is temperate/NC).
public enum ClimateZone: String, Codable, CaseIterable, Sendable, Equatable {
    case cold
    case temperate
    case hot
    case tropical

    public var displayName: String {
        switch self {
        case .cold: "Cold"
        case .temperate: "Temperate"
        case .hot: "Hot"
        case .tropical: "Tropical"
        }
    }
}

/// The home's heating/cooling system. `nil`/`.none` on the profile gates out every `requiresHVAC`
/// task (filter changes, tune-ups, …).
public enum HVACType: String, Codable, CaseIterable, Sendable, Equatable {
    case centralAir
    case windowUnit
    case heatPump
    case radiator
    case none

    public var displayName: String {
        switch self {
        case .centralAir: "Central air"
        case .windowUnit: "Window unit"
        case .heatPump: "Heat pump"
        case .radiator: "Radiator"
        case .none: "None"
        }
    }
}

/// The family's home characteristics (P29, ported from Fambo). Filters the
/// ``MaintenanceKnowledgeBase`` down to the tasks that actually apply (a pool-less home never sees
/// pool tasks). Persisted as a single config doc at `households/{hid}/config/homeProfile`
/// (member-gated by the existing wildcard rule — no rules change). Every field decode-safe.
public struct HomeProfile: Codable, Equatable, Sendable {
    public var homeType: HomeType
    public var yearBuilt: Int?
    public var squareFootage: Int?
    public var climateZone: ClimateZone
    public var hasYard: Bool
    public var hasPool: Bool
    public var hasBasement: Bool
    public var hasGarage: Bool
    public var hasSepticSystem: Bool
    public var hvacType: HVACType?
    public var updatedAt: Date

    public init(
        homeType: HomeType = .house,
        yearBuilt: Int? = nil,
        squareFootage: Int? = nil,
        climateZone: ClimateZone = .temperate,
        hasYard: Bool = false,
        hasPool: Bool = false,
        hasBasement: Bool = false,
        hasGarage: Bool = false,
        hasSepticSystem: Bool = false,
        hvacType: HVACType? = nil,
        updatedAt: Date = .now
    ) {
        self.homeType = homeType
        self.yearBuilt = yearBuilt
        self.squareFootage = squareFootage
        self.climateZone = climateZone
        self.hasYard = hasYard
        self.hasPool = hasPool
        self.hasBasement = hasBasement
        self.hasGarage = hasGarage
        self.hasSepticSystem = hasSepticSystem
        self.hvacType = hvacType
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homeType = try c.decodeIfPresent(HomeType.self, forKey: .homeType) ?? .house
        yearBuilt = try c.decodeIfPresent(Int.self, forKey: .yearBuilt)
        squareFootage = try c.decodeIfPresent(Int.self, forKey: .squareFootage)
        climateZone = try c.decodeIfPresent(ClimateZone.self, forKey: .climateZone) ?? .temperate
        hasYard = try c.decodeIfPresent(Bool.self, forKey: .hasYard) ?? false
        hasPool = try c.decodeIfPresent(Bool.self, forKey: .hasPool) ?? false
        hasBasement = try c.decodeIfPresent(Bool.self, forKey: .hasBasement) ?? false
        hasGarage = try c.decodeIfPresent(Bool.self, forKey: .hasGarage) ?? false
        hasSepticSystem = try c.decodeIfPresent(Bool.self, forKey: .hasSepticSystem) ?? false
        hvacType = try c.decodeIfPresent(HVACType.self, forKey: .hvacType)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }

    /// A sensible starting profile for the Place house, offered on first setup (item 4 of P29):
    /// a house in a temperate/NC climate, central-air HVAC (Nest), with a yard (deck project),
    /// a garage (HomeKit opener), and a septic system (Septic System Solutions invoices). Basement
    /// off and pool off (a plant lives in a "Pool Room" but there's no actual pool) — both easy to
    /// flip on in the form.
    public static let placeDefault = HomeProfile(
        homeType: .house,
        climateZone: .temperate,
        hasYard: true,
        hasPool: false,
        hasBasement: false,
        hasGarage: true,
        hasSepticSystem: true,
        hvacType: .centralAir
    )
}
