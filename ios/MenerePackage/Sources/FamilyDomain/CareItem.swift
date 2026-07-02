import Foundation

/// What kind of thing needs recurring care. **P8 uses `.house`/`.zone` only** — the `.plant`
/// and `.pet` cases exist so P9 (Plants & garden) and P10 (Pets) are additive, not a model change.
public enum CareKind: String, Codable, CaseIterable, Sendable, Equatable {
    case house      // whole-house upkeep: HVAC filter, gutters, water heater
    case zone       // a room / area on a rotation: "Deep clean: kitchen"
    case plant      // DORMANT until P9
    case pet        // DORMANT until P10

    public var displayName: String {
        switch self {
        case .house: "House"
        case .zone: "Zone"
        case .plant: "Plant"
        case .pet: "Pet"
        }
    }

    /// A sensible default SF Symbol when the user hasn't picked one.
    public var defaultSymbol: String {
        switch self {
        case .house: "house.fill"
        case .zone: "square.split.bottomrightquarter.fill"
        case .plant: "leaf.fill"
        case .pet: "pawprint.fill"
        }
    }
}

/// A single recurring upkeep task inside a ``CareItem`` — "Replace filter", "Wash bedding".
///
/// Distinct from a kid `Chore`: **no XP**, tracked purely by *who did it last, and when*.
/// The due date is a **computed convention** (`lastDoneAt + intervalDays`), not stored — the
/// codebase computes derived values (see `Chore.effectiveXP`, `MemberStats.levelProgress`) rather
/// than persisting them, so there's no stale `dueAt` to reconcile.
///
/// First-due convention: a task with an interval that has **never been done** (`lastDoneAt == nil`)
/// is treated as **due today** — you haven't done it yet, so it needs doing. A never-done task is
/// *due* but not *overdue* (there's no missed anchor to be late against). A task with **no
/// interval** (`intervalDays == nil`) is seasonal/manual: it never becomes automatically due.
public struct CareTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// Cadence in days. `nil` = seasonal / manual (mark done whenever, never auto-due).
    public var intervalDays: Int?
    public var lastDoneAt: Date?
    /// The uid of whoever last marked it done.
    public var lastDoneBy: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        intervalDays: Int? = 30,
        lastDoneAt: Date? = nil,
        lastDoneBy: String? = nil
    ) {
        self.id = id
        self.title = title
        self.intervalDays = intervalDays
        self.lastDoneAt = lastDoneAt
        self.lastDoneBy = lastDoneBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        intervalDays = try c.decodeIfPresent(Int.self, forKey: .intervalDays)
        lastDoneAt = try c.decodeIfPresent(Date.self, forKey: .lastDoneAt)
        lastDoneBy = try c.decodeIfPresent(String.self, forKey: .lastDoneBy)
    }

    /// `true` when there's no cadence — seasonal / manual.
    public var isManual: Bool { intervalDays == nil }

    /// Computed next-due date (`lastDoneAt + intervalDays`). `nil` for a manual task or a
    /// never-done task (no anchor to add the interval to — see `daysUntilDue` for the never-done
    /// "due today" convention).
    public var dueAt: Date? {
        guard let intervalDays, let lastDoneAt else { return nil }
        return Calendar.current.date(byAdding: .day, value: intervalDays, to: lastDoneAt)
    }

    /// Whole days until due: `> 0` future, `0` due today, `< 0` overdue. `nil` for manual tasks.
    /// A never-done interval task returns `0` (due today) per the first-due convention.
    public func daysUntilDue(now: Date = Date()) -> Int? {
        guard intervalDays != nil else { return nil }
        guard let due = dueAt else { return 0 }   // never done → due today
        let cal = Calendar.current
        return cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: now),
            to: cal.startOfDay(for: due)
        ).day
    }

    /// `true` when the task needs doing today or is past due (interval tasks only).
    public func isDue(now: Date = Date()) -> Bool {
        guard let days = daysUntilDue(now: now) else { return false }
        return days <= 0
    }

    /// `true` only when a real due date has passed — a never-done task is *due*, not *overdue*.
    public func isOverdue(now: Date = Date()) -> Bool {
        guard lastDoneAt != nil, let days = daysUntilDue(now: now) else { return false }
        return days < 0
    }
}

/// A *thing that needs recurring care* — the house, a room/zone (and later a plant or pet). One
/// shared primitive introduced at P8 and reused by P9/P10 (see ROADMAP "Architectural spine").
///
/// Persisted at `households/{hid}/careItems/{id}` (covered by the existing member-gated wildcard
/// rule — no rules change).
public struct CareItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: CareKind
    public var name: String
    public var iconSymbol: String
    public var location: String?
    public var tasks: [CareTask]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: CareKind = .house,
        name: String,
        iconSymbol: String = "house.fill",
        location: String? = nil,
        tasks: [CareTask] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.iconSymbol = iconSymbol
        self.location = location
        self.tasks = tasks
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(CareKind.self, forKey: .kind) ?? .house
        name = try c.decode(String.self, forKey: .name)
        iconSymbol = try c.decodeIfPresent(String.self, forKey: .iconSymbol) ?? "house.fill"
        location = try c.decodeIfPresent(String.self, forKey: .location)
        tasks = try c.decodeIfPresent([CareTask].self, forKey: .tasks) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// The task that drives the collapsed row: the soonest-due one. Interval tasks sort by days
    /// until due (overdue first); manual tasks fall to the back.
    public func soonestDueTask(now: Date = Date()) -> CareTask? {
        tasks.min {
            ($0.daysUntilDue(now: now) ?? Int.max) < ($1.daysUntilDue(now: now) ?? Int.max)
        }
    }

    // MARK: Form pickers (UI-free option data)

    /// Curated SF Symbols for the care-item icon grid (house/zone flavor).
    public static let iconOptions: [String] = [
        "house.fill", "wind", "drop.fill", "sparkles", "shower.fill", "bathtub.fill",
        "bed.double.fill", "sink.fill", "washer.fill", "fanblades.fill", "flame.fill", "spigot.fill",
        "trash.fill", "leaf.fill", "paintbrush.fill", "hammer.fill",
    ]

    /// The interval choices offered in the task cadence picker (`nil` = seasonal / manual).
    public static let intervalChoices: [Int?] = [7, 14, 30, 60, 90, 180, nil]

    /// A human label for a cadence value, used by the picker and row copy.
    public static func intervalLabel(_ days: Int?) -> String {
        switch days {
        case .none: return "Seasonal / manual"
        case 7: return "Weekly"
        case 14: return "Every 2 weeks"
        case 30: return "Monthly"
        case 60: return "Every 2 months"
        case 90: return "Quarterly"
        case 180: return "Twice a year"
        case let .some(d): return "Every \(d) days"
        }
    }
}
