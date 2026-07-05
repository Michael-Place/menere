import Foundation

/// The species a ``PetCareTemplate`` applies to. Derived from a pet ``CareItem`` by
/// ``PetCareKB/species(for:)`` (icon first — `cat.fill` ⇒ cat — then a few breed keywords), so the
/// recommended schedule matches Fireball (cat) vs Sprinkle/Fajita (dogs) without a model change.
public enum PetSpecies: String, Codable, CaseIterable, Sendable, Equatable {
    case dog
    case cat

    public var displayName: String {
        switch self {
        case .dog: "Dog"
        case .cat: "Cat"
        }
    }
}

/// A seeded pet-care recommendation (P31) — the PET analog of ``MaintenanceTemplate``. A pure
/// template: a title, the species it's for, a recurring cadence (`intervalDays`), and a warm one-line
/// note. Unlike a house template it materializes into a **new ``CareTask`` appended to the pet's own
/// ``CareItem``** (pets already exist as care items) rather than creating a fresh item. Not persisted
/// itself — the library lives in ``PetCareKB``.
public struct PetCareTemplate: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var species: PetSpecies
    public var intervalDays: Int
    public var note: String
    /// Lowercase keywords used to recognize whether the pet ALREADY has a matching task (title match).
    /// A pet's existing task "Heartworm pill" matches this template's keyword "heartworm", so we never
    /// offer a duplicate. Kept separate from `title` so the seeded default-task titles still match.
    public var matchKeywords: [String]

    public init(
        id: String,
        title: String,
        species: PetSpecies,
        intervalDays: Int,
        note: String,
        matchKeywords: [String]
    ) {
        self.id = id
        self.title = title
        self.species = species
        self.intervalDays = intervalDays
        self.note = note
        self.matchKeywords = matchKeywords
    }

    /// A human cadence label reusing the shared care copy ("Monthly", "Yearly"), with the multi-year
    /// boosters special-cased for warmth.
    public var frequencyLabel: String {
        switch intervalDays {
        case 1095: return "Every 3 years"
        case 730: return "Every 2 years"
        default: return CareItem.intervalLabel(intervalDays)
        }
    }

    /// `true` when `task` is this recommendation already on the pet — matched by title keyword.
    public func matches(_ task: CareTask) -> Bool {
        let t = task.title.lowercased()
        return matchKeywords.contains { !$0.isEmpty && t.contains($0) }
    }

    /// Materialize this template into a ``CareTask`` to append to the pet's ``CareItem``. When
    /// `alreadyDone` the task is stamped done-now (caught-up, next due one interval out); otherwise it's
    /// left never-done ⇒ due today (the first real completion anchors it). `by` credits the actor.
    public func makeCareTask(alreadyDone: Bool = false, by uid: String? = nil, now: Date = Date()) -> CareTask {
        CareTask(
            title: title,
            intervalDays: intervalDays,
            lastDoneAt: alreadyDone ? now : nil,
            lastDoneBy: alreadyDone ? uid : nil
        )
    }
}

/// One line of a pet's recommended schedule: the template, plus the pet's matching existing task (if
/// any). Powers the pet-detail setup section (already-has vs missing) and the "N of M on schedule"
/// signal.
public struct PetScheduleItem: Equatable, Sendable, Identifiable {
    public let template: PetCareTemplate
    /// The pet's existing task that satisfies this recommendation, or nil if it's missing.
    public let existingTask: CareTask?

    public var id: String { template.id }

    /// `true` when the pet already tracks this recommendation.
    public var isPresent: Bool { existingTask != nil }

    /// `true` when it's present AND not overdue — the definition of "on schedule".
    public func isOnSchedule(now: Date = Date()) -> Bool {
        guard let t = existingTask else { return false }
        return !t.isOverdue(now: now)
    }
}

/// A pet's recommended schedule resolved against its current tasks — the per-pet rollup the setup
/// section and the up-to-date signal read from.
public struct PetSchedule: Equatable, Sendable {
    public let species: PetSpecies
    public let items: [PetScheduleItem]

    /// Recommendations the pet already tracks.
    public var present: [PetScheduleItem] { items.filter(\.isPresent) }
    /// Recommendations the pet is missing — the ones offered to add.
    public var missing: [PetScheduleItem] { items.filter { !$0.isPresent } }
    /// Total recommended for the species.
    public var total: Int { items.count }
    /// Present AND current — the numerator of "N of M on schedule".
    public func onScheduleCount(now: Date = Date()) -> Int {
        items.filter { $0.isOnSchedule(now: now) }.count
    }
    /// `true` when every recommendation is set up and current.
    public func isFullyOnSchedule(now: Date = Date()) -> Bool { onScheduleCount(now: now) == total }
}

/// The seeded pet-care library (P31) — the PET analog of ``MaintenanceKnowledgeBase``. Recommended
/// recurring care by species: the loud recurring shots/preventatives/checkups a family actually
/// forgets. Pure data + a small resolver (`recommendedFor` / `schedule(for:)`); the pet DETAIL screen
/// materializes a missing template into the pet's own ``CareTask`` list.
public enum PetCareKB {

    /// The recommended schedule for a **dog** (Sprinkle & Fajita). Preventatives up front, then the
    /// vaccines/checkups, then grooming/weight.
    public static let dogTemplates: [PetCareTemplate] = [
        PetCareTemplate(
            id: "dog-heartworm",
            title: "Heartworm prevention",
            species: .dog,
            intervalDays: 30,
            note: "One chewable a month, year-round — heartworm is far easier to prevent than treat.",
            matchKeywords: ["heartworm"]
        ),
        PetCareTemplate(
            id: "dog-flea-tick",
            title: "Flea & tick",
            species: .dog,
            intervalDays: 30,
            note: "Monthly flea-and-tick preventative keeps the itch — and the tick-borne stuff — away.",
            matchKeywords: ["flea", "tick"]
        ),
        PetCareTemplate(
            id: "dog-vet-checkup",
            title: "Annual vet checkup",
            species: .dog,
            intervalDays: 365,
            note: "A yearly wellness exam catches the quiet things early. Bring the vaccine record.",
            matchKeywords: ["checkup", "check-up", "wellness", "annual vet", "vet visit"]
        ),
        PetCareTemplate(
            id: "dog-rabies",
            title: "Rabies booster",
            species: .dog,
            intervalDays: 1095,
            note: "Legally required. After the first year it's typically a 3-year booster.",
            matchKeywords: ["rabies"]
        ),
        PetCareTemplate(
            id: "dog-dhpp",
            title: "DHPP booster",
            species: .dog,
            intervalDays: 365,
            note: "Distemper/parvo combo — puppy series, then a booster every 1–3 years per your vet.",
            matchKeywords: ["dhpp", "distemper", "parvo", "da2pp"]
        ),
        PetCareTemplate(
            id: "dog-dental",
            title: "Dental cleaning",
            species: .dog,
            intervalDays: 365,
            note: "A yearly professional cleaning saves teeth — and heart and kidneys down the line.",
            matchKeywords: ["dental", "teeth cleaning"]
        ),
        PetCareTemplate(
            id: "dog-nail-trim",
            title: "Nail trim",
            species: .dog,
            intervalDays: 30,
            note: "Monthly trims keep the click off the floor and the paws happy.",
            matchKeywords: ["nail"]
        ),
        PetCareTemplate(
            id: "dog-deworming",
            title: "Deworming",
            species: .dog,
            intervalDays: 90,
            note: "A quarterly deworming keeps intestinal parasites in check.",
            matchKeywords: ["deworm", "worming", "dewormer"]
        ),
        PetCareTemplate(
            id: "dog-weight-check",
            title: "Weight check",
            species: .dog,
            intervalDays: 90,
            note: "A quick quarterly weigh-in catches creep before it becomes a vet conversation.",
            matchKeywords: ["weight"]
        ),
    ]

    /// The recommended schedule for a **cat** (Fireball).
    public static let catTemplates: [PetCareTemplate] = [
        PetCareTemplate(
            id: "cat-fvrcp",
            title: "FVRCP booster",
            species: .cat,
            intervalDays: 365,
            note: "The core feline combo (rhino/calici/panleuk) — a yearly-to-triennial booster per your vet.",
            matchKeywords: ["fvrcp", "distemper", "panleuk"]
        ),
        PetCareTemplate(
            id: "cat-rabies",
            title: "Rabies",
            species: .cat,
            intervalDays: 365,
            note: "Required for cats too — usually a yearly or 3-year booster depending on the vaccine.",
            matchKeywords: ["rabies"]
        ),
        PetCareTemplate(
            id: "cat-flea",
            title: "Flea prevention",
            species: .cat,
            intervalDays: 30,
            note: "Monthly flea preventative — indoor cats catch them too (hello, dog friends).",
            matchKeywords: ["flea", "tick"]
        ),
        PetCareTemplate(
            id: "cat-vet-checkup",
            title: "Annual vet checkup",
            species: .cat,
            intervalDays: 365,
            note: "Cats hide illness well — a yearly wellness exam is the best early warning.",
            matchKeywords: ["checkup", "check-up", "wellness", "annual vet", "vet visit"]
        ),
        PetCareTemplate(
            id: "cat-dental",
            title: "Dental",
            species: .cat,
            intervalDays: 365,
            note: "A yearly dental check heads off painful resorptive lesions and gum disease.",
            matchKeywords: ["dental", "teeth cleaning"]
        ),
        PetCareTemplate(
            id: "cat-deworming",
            title: "Deworming",
            species: .cat,
            intervalDays: 90,
            note: "A quarterly deworming keeps intestinal parasites in check.",
            matchKeywords: ["deworm", "worming", "dewormer"]
        ),
    ]

    /// Every seeded template (dog + cat).
    public static let allTemplates: [PetCareTemplate] = dogTemplates + catTemplates

    /// Look up a template by id — used by the materialize path.
    public static func template(id: String) -> PetCareTemplate? {
        allTemplates.first { $0.id == id }
    }

    /// Derive a pet's species from its ``CareItem``: the icon wins (`cat.fill` ⇒ cat), then a few
    /// breed keywords; everything else defaults to dog (the family is dog-heavy and the dog set is the
    /// safe general default).
    public static func species(for pet: CareItem) -> PetSpecies {
        let icon = pet.iconSymbol.lowercased()
        if icon.contains("cat") || icon.contains("fish") { return .cat }
        if icon.contains("dog") || icon.contains("bone") { return .dog }
        let breed = (pet.breed ?? "").lowercased()
        let catBreeds = ["cat", "kitten", "feline", "siamese", "tabby", "persian", "maine coon",
                         "ragdoll", "bengal", "sphynx", "shorthair", "longhair", "calico"]
        if catBreeds.contains(where: { breed.contains($0) }) { return .cat }
        return .dog
    }

    /// The species-appropriate recommended templates for `pet`.
    public static func recommendedFor(_ pet: CareItem) -> [PetCareTemplate] {
        switch species(for: pet) {
        case .dog: return dogTemplates
        case .cat: return catTemplates
        }
    }

    /// Resolve the pet's recommended schedule against its current tasks — each recommendation paired
    /// with the pet's matching task (if any). Drives the setup section + the "N of M on schedule" line.
    public static func schedule(for pet: CareItem) -> PetSchedule {
        let sp = species(for: pet)
        let templates = recommendedFor(pet)
        let items = templates.map { template in
            PetScheduleItem(
                template: template,
                existingTask: pet.tasks.first { template.matches($0) }
            )
        }
        return PetSchedule(species: sp, items: items)
    }
}
