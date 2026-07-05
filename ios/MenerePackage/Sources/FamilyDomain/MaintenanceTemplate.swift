import Foundation

/// How often a maintenance template should recur. The `intervalDays` mirrors Fambo's
/// `approximateIntervalDays` — the cadence carried onto a materialized ``CareTask``.
public enum MaintenanceFrequency: String, Codable, CaseIterable, Sendable, Equatable {
    case daily
    case weekly
    case biweekly
    case monthly
    case quarterly
    case semiannual
    case annual
    case seasonal

    public var displayName: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .biweekly: "Every 2 weeks"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .semiannual: "Twice a year"
        case .annual: "Yearly"
        case .seasonal: "Seasonal"
        }
    }

    /// The cadence in days, carried onto the ``CareTask`` when a template is materialized.
    public var intervalDays: Int {
        switch self {
        case .daily: 1
        case .weekly: 7
        case .biweekly: 14
        case .monthly: 30
        case .quarterly: 90
        case .semiannual: 180
        case .annual: 365
        case .seasonal: 90
        }
    }
}

/// A category of home maintenance — nine buckets ported from Fambo. Drives the per-category health
/// score and the section grouping in the suggested list.
public enum MaintenanceCategory: String, Codable, CaseIterable, Sendable, Equatable {
    case hvac
    case plumbing
    case electrical
    case exterior
    case interior
    case appliances
    case safety
    case yard
    case pool

    public var displayName: String {
        switch self {
        case .hvac: "HVAC"
        case .plumbing: "Plumbing"
        case .electrical: "Electrical"
        case .exterior: "Exterior"
        case .interior: "Interior"
        case .appliances: "Appliances"
        case .safety: "Safety"
        case .yard: "Yard"
        case .pool: "Pool"
        }
    }

    public var icon: String {
        switch self {
        case .hvac: "fan.fill"
        case .plumbing: "drop.fill"
        case .electrical: "bolt.fill"
        case .exterior: "house.fill"
        case .interior: "paintbrush.fill"
        case .appliances: "refrigerator.fill"
        case .safety: "shield.checkered"
        case .yard: "leaf.fill"
        case .pool: "figure.pool.swim"
        }
    }
}

/// The season a seasonal task belongs to. `Season.current` reads the calendar month.
public enum Season: String, Codable, CaseIterable, Sendable, Equatable {
    case spring
    case summer
    case fall
    case winter

    public var displayName: String {
        switch self {
        case .spring: "Spring"
        case .summer: "Summer"
        case .fall: "Fall"
        case .winter: "Winter"
        }
    }

    public static var current: Season {
        let month = Calendar.current.component(.month, from: .now)
        switch month {
        case 3...5: return .spring
        case 6...8: return .summer
        case 9...11: return .fall
        default: return .winter
        }
    }
}

/// A seeded home-maintenance recommendation (P29, ported from Fambo's `MaintenanceTask`). A pure
/// template: it carries a cadence, an optional season, difficulty, `requires*` gates, and an
/// estimate. Materializing one creates a ``CareItem`` (kind `.house`) whose ``CareTask`` carries the
/// template's `intervalDays` + a `maintenanceTemplateID` back-reference (so the health score can find
/// it again). Not persisted itself — the library lives in ``MaintenanceKnowledgeBase``.
public struct MaintenanceTemplate: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var category: MaintenanceCategory
    public var frequency: MaintenanceFrequency
    public var difficulty: ChoreDifficulty
    public var season: Season?
    public var requiresYard: Bool
    public var requiresPool: Bool
    public var requiresBasement: Bool
    public var requiresGarage: Bool
    public var requiresSepticSystem: Bool
    public var requiresHVAC: Bool
    public var estimatedMinutes: Int

    public init(
        id: String,
        title: String,
        description: String,
        category: MaintenanceCategory,
        frequency: MaintenanceFrequency,
        difficulty: ChoreDifficulty = .easy,
        season: Season? = nil,
        requiresYard: Bool = false,
        requiresPool: Bool = false,
        requiresBasement: Bool = false,
        requiresGarage: Bool = false,
        requiresSepticSystem: Bool = false,
        requiresHVAC: Bool = false,
        estimatedMinutes: Int = 30
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.category = category
        self.frequency = frequency
        self.difficulty = difficulty
        self.season = season
        self.requiresYard = requiresYard
        self.requiresPool = requiresPool
        self.requiresBasement = requiresBasement
        self.requiresGarage = requiresGarage
        self.requiresSepticSystem = requiresSepticSystem
        self.requiresHVAC = requiresHVAC
        self.estimatedMinutes = estimatedMinutes
    }

    /// The cadence in days for the materialized ``CareTask``.
    public var intervalDays: Int { frequency.intervalDays }

    /// Materialize this template into a house ``CareItem`` carrying a single ``CareTask`` with this
    /// template's cadence + a `maintenanceTemplateID` back-reference. When `alreadyDone` the task's
    /// `lastDoneAt` is stamped now (so it reads as caught-up, next due one interval out); otherwise
    /// it's left never-done ⇒ due today.
    public func makeCareItem(alreadyDone: Bool = false, now: Date = Date()) -> CareItem {
        CareItem(
            kind: .house,
            name: title,
            iconSymbol: category.icon,
            tasks: [
                CareTask(
                    title: title,
                    intervalDays: intervalDays,
                    lastDoneAt: alreadyDone ? now : nil,
                    maintenanceTemplateID: id
                ),
            ],
            careNotes: description
        )
    }
}
