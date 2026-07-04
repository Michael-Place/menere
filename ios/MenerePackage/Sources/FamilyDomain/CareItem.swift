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
/// Due-anchor convention (interval tasks only — a `nil`-interval task is seasonal/manual and never
/// auto-due). The next-due date resolves in priority order:
///   1. **Done before** (`lastDoneAt != nil`): due = `lastDoneAt + intervalDays`.
///   2. **Never done, but anchored** (`firstDueAt != nil`): due = `firstDueAt` — an explicit first
///      due date (P9-C3 uses this for seasonal windows, e.g. "first prune in March").
///   3. **Never done, no anchor**: **due today** — you haven't done it yet, so it needs doing.
/// A task is *overdue* only when it has a real anchor (a prior completion **or** a `firstDueAt`)
/// that's in the past. An un-anchored never-done task is *due*, not *overdue* — nothing to be late
/// against.
public struct CareTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// Cadence in days. `nil` = seasonal / manual (mark done whenever, never auto-due).
    public var intervalDays: Int?
    public var lastDoneAt: Date?
    /// The uid of whoever last marked it done.
    public var lastDoneBy: String?
    /// An explicit first-due anchor for a task that's never been done — the due date to use until
    /// the first completion stamps `lastDoneAt`. `nil` = fall back to "due today". Decode-safe
    /// additive field (P9); P9-C3 sets it for seasonal windows.
    public var firstDueAt: Date?

    public init(
        id: String = UUID().uuidString,
        title: String,
        intervalDays: Int? = 30,
        lastDoneAt: Date? = nil,
        lastDoneBy: String? = nil,
        firstDueAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.intervalDays = intervalDays
        self.lastDoneAt = lastDoneAt
        self.lastDoneBy = lastDoneBy
        self.firstDueAt = firstDueAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        intervalDays = try c.decodeIfPresent(Int.self, forKey: .intervalDays)
        lastDoneAt = try c.decodeIfPresent(Date.self, forKey: .lastDoneAt)
        lastDoneBy = try c.decodeIfPresent(String.self, forKey: .lastDoneBy)
        firstDueAt = try c.decodeIfPresent(Date.self, forKey: .firstDueAt)
    }

    /// `true` when there's no cadence — seasonal / manual.
    public var isManual: Bool { intervalDays == nil }

    /// Computed next-due date. `lastDoneAt + intervalDays` once done; otherwise the `firstDueAt`
    /// anchor when set; `nil` for a manual task or an un-anchored never-done task (see
    /// `daysUntilDue` for the never-done "due today" convention).
    public var dueAt: Date? {
        guard let intervalDays else { return nil }   // manual: never auto-due
        if let lastDoneAt {
            return Calendar.current.date(byAdding: .day, value: intervalDays, to: lastDoneAt)
        }
        return firstDueAt   // never done → explicit anchor, or nil ⇒ "due today" in daysUntilDue
    }

    /// Whole days until due: `> 0` future, `0` due today, `< 0` overdue. `nil` for manual tasks.
    /// An un-anchored never-done interval task returns `0` (due today) per the convention above.
    public func daysUntilDue(now: Date = Date()) -> Int? {
        guard intervalDays != nil else { return nil }
        guard let due = dueAt else { return 0 }   // never done, no anchor → due today
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

    /// `true` only when a real anchor (a prior completion **or** a `firstDueAt`) has passed — an
    /// un-anchored never-done task is *due*, not *overdue*.
    public func isOverdue(now: Date = Date()) -> Bool {
        guard lastDoneAt != nil || firstDueAt != nil else { return false }
        guard let days = daysUntilDue(now: now) else { return false }
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
    /// Storage path of the item's photo (`households/{hid}/care/{id}/photo.jpg`). Plant-flavored
    /// (P9) but kind-agnostic. Decode-safe additive field.
    public var photoPath: String?
    /// Free-text species / common name (plants), e.g. "Monstera". C2 fills this from AI identify.
    public var species: String?
    /// Latin / botanical name, e.g. "Monstera deliciosa" — rendered italic when present.
    public var speciesLatin: String?
    /// Free-text care notes ("bright indirect light, let the top inch dry out").
    public var careNotes: String?
    /// Plant-only (P19-C3): free text about the plant's SITUATION — pot type, soil, indoor/outdoor,
    /// light/drafts ("Outside on the balcony in a terracotta pot, dries out fast"). Distinct from
    /// `careNotes` (generic care advice): this is the context the AI troubleshooter uses to adapt its
    /// diagnosis + watering cadence. Decode-safe additive field (older plants nil).
    public var careContext: String?
    /// Plant-only (P9.1): the light level the plant lives in — one of the capture wizard's choices
    /// ("Low" / "Medium" / "Bright indirect" / "Direct sun"). Free-form `String?` so future choices
    /// stay additive. Decode-safe additive field; rendered ink-soft on the plant row/detail.
    public var lightLevel: String?
    /// Pet-only (P10): breed, e.g. "Chihuahua mix". Decode-safe additive field.
    public var breed: String?
    /// Pet-only (P10): birthday, for age. Decode-safe additive field.
    public var birthday: Date?
    /// Pet-only (P10): vet contact name. Decode-safe additive field.
    public var vetName: String?
    /// Pet-only (P10): vet contact phone. Decode-safe additive field.
    public var vetPhone: String?

    public init(
        id: String = UUID().uuidString,
        kind: CareKind = .house,
        name: String,
        iconSymbol: String = "house.fill",
        location: String? = nil,
        tasks: [CareTask] = [],
        createdAt: Date = Date(),
        photoPath: String? = nil,
        species: String? = nil,
        speciesLatin: String? = nil,
        careNotes: String? = nil,
        careContext: String? = nil,
        lightLevel: String? = nil,
        breed: String? = nil,
        birthday: Date? = nil,
        vetName: String? = nil,
        vetPhone: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.iconSymbol = iconSymbol
        self.location = location
        self.tasks = tasks
        self.createdAt = createdAt
        self.photoPath = photoPath
        self.species = species
        self.speciesLatin = speciesLatin
        self.careNotes = careNotes
        self.careContext = careContext
        self.lightLevel = lightLevel
        self.breed = breed
        self.birthday = birthday
        self.vetName = vetName
        self.vetPhone = vetPhone
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
        photoPath = try c.decodeIfPresent(String.self, forKey: .photoPath)
        species = try c.decodeIfPresent(String.self, forKey: .species)
        speciesLatin = try c.decodeIfPresent(String.self, forKey: .speciesLatin)
        careNotes = try c.decodeIfPresent(String.self, forKey: .careNotes)
        careContext = try c.decodeIfPresent(String.self, forKey: .careContext)
        lightLevel = try c.decodeIfPresent(String.self, forKey: .lightLevel)
        breed = try c.decodeIfPresent(String.self, forKey: .breed)
        birthday = try c.decodeIfPresent(Date.self, forKey: .birthday)
        vetName = try c.decodeIfPresent(String.self, forKey: .vetName)
        vetPhone = try c.decodeIfPresent(String.self, forKey: .vetPhone)
    }

    /// The task that drives the collapsed row: the soonest-due one. Interval tasks sort by days
    /// until due (overdue first); manual tasks fall to the back.
    public func soonestDueTask(now: Date = Date()) -> CareTask? {
        tasks.min {
            ($0.daysUntilDue(now: now) ?? Int.max) < ($1.daysUntilDue(now: now) ?? Int.max)
        }
    }

    // MARK: Form pickers (UI-free option data)

    /// Curated SF Symbols for the care-item icon grid (house/zone flavor). Kept for existing call
    /// sites; new code should prefer ``iconOptions(for:)`` so plants get their own set.
    public static let iconOptions: [String] = [
        "house.fill", "wind", "drop.fill", "sparkles", "shower.fill", "bathtub.fill",
        "bed.double.fill", "sink.fill", "washer.fill", "fanblades.fill", "flame.fill", "spigot.fill",
        "trash.fill", "leaf.fill", "paintbrush.fill", "hammer.fill",
    ]

    /// Plant-flavored icon grid — leaf/drop/sun symbols instead of house upkeep glyphs.
    public static let plantIconOptions: [String] = [
        "leaf.fill", "camera.macro", "tree.fill", "drop.fill", "humidity.fill", "sun.max.fill",
        "cloud.rain.fill", "sparkles", "ladybug.fill", "scissors", "fanblades.fill", "wind",
    ]

    /// Yard-flavored icon grid (P9-C3) — tree/leaf/pruning/sun-and-sprinkler glyphs for outdoor
    /// seasonal zones, distinct from indoor-plant and house-upkeep sets.
    public static let zoneIconOptions: [String] = [
        "tree.fill", "leaf.fill", "scissors", "sun.max.fill", "sprinkler.and.droplets.fill",
        "drop.fill", "cloud.rain.fill", "sparkles", "wind", "flame.fill", "trash.fill", "hammer.fill",
    ]

    /// Pet-flavored icon grid (P10) — pawprint/dog/grooming/vet glyphs for Fajita & Sprinkle.
    public static let petIconOptions: [String] = [
        "pawprint.fill", "dog.fill", "cat.fill", "bone.fill", "pills.fill", "cross.case.fill",
        "scissors", "shower.fill", "figure.walk", "heart.fill", "teddybear.fill", "fish.fill",
    ]

    /// The icon set for a given care kind. Plants get leaf/drop/sun flavor; yard zones get
    /// tree/pruning/sprinkler flavor; pets get pawprint/dog/grooming glyphs; house keeps the upkeep
    /// glyphs (no change for existing call sites).
    public static func iconOptions(for kind: CareKind) -> [String] {
        switch kind {
        case .plant: return plantIconOptions
        case .zone: return zoneIconOptions
        case .pet: return petIconOptions
        default: return iconOptions
        }
    }

    /// The light-level choices offered in the plant capture wizard's "Home" step (P9.1), stored as the
    /// free-form ``lightLevel`` string. Ordered dim → bright.
    public static let lightLevelChoices: [String] = ["Low", "Medium", "Bright indirect", "Direct sun"]

    // MARK: House-health rollup (UI-free — the same math powers the Home banner and Today card)

    /// A due-or-soon care task paired with the item it belongs to. `days` is the whole-day count
    /// until due (`< 0` overdue, `0` due today). Sorted overdue-first by the rollup helpers so the
    /// Home banner and the Today "Home care" card agree on ordering and naming.
    public struct CareDue: Equatable, Identifiable, Sendable {
        public let item: CareItem
        public let task: CareTask
        public let days: Int
        public let isOverdue: Bool
        public var id: String { "\(item.id)/\(task.id)" }
    }

    /// Every interval task across `items` that is due within `horizonDays` (overdue included),
    /// sorted soonest-first (most overdue first). Manual/seasonal tasks and comfortably-future tasks
    /// are excluded. Both the House-care banner and the Today "Home care" card read from this.
    public static func dueTasks(
        in items: [CareItem], now: Date = Date(), within horizonDays: Int = 7
    ) -> [CareDue] {
        var result: [CareDue] = []
        for item in items {
            for task in item.tasks {
                guard let days = task.daysUntilDue(now: now), days <= horizonDays else { continue }
                result.append(CareDue(item: item, task: task, days: days, isOverdue: task.isOverdue(now: now)))
            }
        }
        return result.sorted { $0.days < $1.days }
    }

    /// The house-health summary — overdue / due-this-week / caught-up — derived from the same
    /// ``dueTasks(in:now:within:)`` set so the Home banner and Today never disagree.
    public static func houseHealth(
        for items: [CareItem], now: Date = Date(), within horizonDays: Int = 7
    ) -> HouseHealth {
        let due = dueTasks(in: items, now: now, within: horizonDays)
        let overdue = due.filter(\.isOverdue)
        if let worst = overdue.first {   // sorted soonest-first ⇒ most overdue is first
            return .overdue(count: overdue.count, worstItem: worst.item.name, daysOver: -worst.days)
        }
        if let soonest = due.first {     // no overdue here ⇒ every entry is upcoming
            return .dueThisWeek(count: due.count, soonestItem: soonest.item.name, days: soonest.days)
        }
        return .caughtUp
    }

    /// The interval choices offered in the task cadence picker (`nil` = seasonal / manual). Kept for
    /// existing call sites; new code should prefer ``intervalChoices(for:)``.
    public static let intervalChoices: [Int?] = [7, 14, 30, 60, 90, 180, nil]

    /// Plant care cadences — tight watering-ish intervals up front, plus the longer prune/re-pot
    /// windows (90 = quarterly, 365 = yearly) so every P19-C1 care-task preset (Prune 90d, Re-pot 365d)
    /// is representable in the form's cadence picker.
    public static let plantIntervalChoices: [Int?] = [2, 3, 5, 7, 10, 14, 30, 90, 365, nil]

    /// Yard cadences (P9-C3) — seasonal windows measured in months, plus a `nil` "seasonal / manual"
    /// for one-off jobs you only mark when you do them.
    public static let zoneIntervalChoices: [Int?] = [30, 60, 90, 180, 365, nil]

    /// Pet cadences (P10) — meds/flea-tick (monthly), grooming, nail trims, up through yearly (shots),
    /// plus a `nil` "seasonal / manual" for one-off care.
    public static let petIntervalChoices: [Int?] = [7, 14, 30, 60, 90, 180, 365, nil]

    /// The cadence choices for a given care kind. Plants get short watering intervals; yard zones get
    /// month-scale seasonal windows; pets get med/grooming cadences; house keeps its set (no behavior
    /// change for existing call sites).
    public static func intervalChoices(for kind: CareKind) -> [Int?] {
        switch kind {
        case .plant: return plantIntervalChoices
        case .zone: return zoneIntervalChoices
        case .pet: return petIntervalChoices
        default: return intervalChoices
        }
    }

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
        case 365: return "Yearly"
        case let .some(d): return "Every \(d) days"
        }
    }
}

/// The whole-house upkeep summary shown at the top of the House-care section and (as a quiet line)
/// on Today. UI-free by design — views own the color, icon, and voice; this owns the math and the
/// one reserved caught-up line. Built by ``CareItem/houseHealth(for:now:within:)``.
public enum HouseHealth: Equatable, Sendable {
    /// One or more interval tasks are past due. `worstItem` is the most-overdue item's name.
    case overdue(count: Int, worstItem: String, daysOver: Int)
    /// Nothing overdue, but `count` interval tasks come due inside the horizon. `soonestItem` is the
    /// nearest one's name; `days` is `0` for due-today.
    case dueThisWeek(count: Int, soonestItem: String, days: Int)
    /// Nothing overdue or due soon — the house is happy.
    case caughtUp

    /// The single reserved caught-up line, shared by the Home banner and the Today quiet line so it
    /// only ever lives in one place.
    public static let happyLine = "The house is happy."
}
