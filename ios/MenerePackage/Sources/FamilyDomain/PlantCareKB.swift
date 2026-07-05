import Foundation

/// A seeded plant-care recommendation (P31) — the PLANT analog of ``PetCareTemplate``. A pure
/// template: a title, a recurring cadence (`intervalDays`), a badge symbol, and a warm one-line note.
/// Like the pet templates it materializes into a **new ``CareTask`` appended to the plant's own
/// ``CareItem``** (plants already exist as care items) rather than minting a fresh item. Not persisted
/// itself — the tailored library lives in ``PlantCareKB``, which reads each plant's ``SpeciesProfile``
/// to decide *which* templates apply (e.g. misting only for humidity-lovers, fertilizing only in the
/// growing season).
public struct PlantCareTemplate: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var intervalDays: Int
    /// SF Symbol badged on the recommendation row (mirrors the plant care-preset glyphs).
    public var symbol: String
    public var note: String
    /// Lowercase keywords used to recognize whether the plant ALREADY has a matching task (title match),
    /// so we never offer a duplicate. Kept separate from `title` so an edited/renamed task ("Water the
    /// Monstera") still matches "water".
    public var matchKeywords: [String]

    public init(
        id: String,
        title: String,
        intervalDays: Int,
        symbol: String,
        note: String,
        matchKeywords: [String]
    ) {
        self.id = id
        self.title = title
        self.intervalDays = intervalDays
        self.symbol = symbol
        self.note = note
        self.matchKeywords = matchKeywords
    }

    /// A human cadence label reusing the shared care copy ("Weekly", "Monthly", "Yearly").
    public var frequencyLabel: String { CareItem.intervalLabel(intervalDays) }

    /// `true` when `task` is this recommendation already on the plant — matched by title keyword.
    public func matches(_ task: CareTask) -> Bool {
        let t = task.title.lowercased()
        return matchKeywords.contains { !$0.isEmpty && t.contains($0) }
    }

    /// Materialize this template into a ``CareTask`` to append to the plant's ``CareItem``. When
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

/// One line of a plant's recommended schedule: the template, plus the plant's matching existing task
/// (if any). Powers the plant-detail "Recommended schedule" section (already-tracking vs missing) and
/// the "N of M on schedule" signal.
public struct PlantScheduleItem: Equatable, Sendable, Identifiable {
    public let template: PlantCareTemplate
    /// The plant's existing task that satisfies this recommendation, or nil if it's missing.
    public let existingTask: CareTask?

    public var id: String { template.id }

    /// `true` when the plant already tracks this recommendation.
    public var isPresent: Bool { existingTask != nil }

    /// `true` when it's present AND not overdue — the definition of "on schedule".
    public func isOnSchedule(now: Date = Date()) -> Bool {
        guard let t = existingTask else { return false }
        return !t.isOverdue(now: now)
    }
}

/// A plant's recommended schedule resolved against its current tasks — the per-plant rollup the setup
/// section and the up-to-date signal read from.
public struct PlantSchedule: Equatable, Sendable {
    public let items: [PlantScheduleItem]

    /// Recommendations the plant already tracks.
    public var present: [PlantScheduleItem] { items.filter(\.isPresent) }
    /// Recommendations the plant is missing — the ones offered to add.
    public var missing: [PlantScheduleItem] { items.filter { !$0.isPresent } }
    /// Total recommended for this plant right now (season- and species-tailored).
    public var total: Int { items.count }
    /// Present AND current — the numerator of "N of M on schedule".
    public func onScheduleCount(now: Date = Date()) -> Int {
        items.filter { $0.isOnSchedule(now: now) }.count
    }
    /// `true` when every recommendation is set up and current.
    public func isFullyOnSchedule(now: Date = Date()) -> Bool { total > 0 && onScheduleCount(now: now) == total }
}

/// The seeded plant-care library (P31) — the PLANT analog of ``PetCareKB``. It derives a RECOMMENDED
/// recurring schedule *per plant* by reading its ``SpeciesProfile`` (humidity, fertilizer cadence) and
/// its species/common name:
///   - **Water** — the plant's own existing water cadence when it has one, else a species-sensible
///     default (drought-tolerant plants get a longer default).
///   - **Rotate** weekly — even light, recommended for most plants.
///   - **Mist** every few days — **only** for humidity-lovers (calatheas, ferns, tropicals); never for
///     succulents/cacti/drought-tolerant plants. Read from the profile's `humidity` text + the species.
///   - **Fertilize** monthly — **seasonal**: recommended only in the growing season (spring/summer);
///     rests in late fall + winter, so off-season it simply isn't offered.
///   - **Prune** quarterly and **Pest check** monthly — recommended for most plants.
///   - **Re-pot** yearly.
/// Graceful when the profile is nil: waters, rotates, prunes, pest-checks, seasonally fertilizes, and
/// re-pots — but skips misting (the specialized humidity-only recommendation).
public enum PlantCareKB {

    // MARK: Season (growing vs rest)

    /// The season for a given date (same month bands as ``Season/current``, but takes an explicit date
    /// so the schedule is testable and `now`-driven rather than reading the wall clock).
    public static func season(for date: Date) -> Season {
        let month = Calendar.current.component(.month, from: date)
        switch month {
        case 3...5: return .spring
        case 6...8: return .summer
        case 9...11: return .fall
        default: return .winter
        }
    }

    /// `true` in spring/summer — the active growing season when fertilizing helps. Fall/winter is the
    /// plant's rest, so fertilizing isn't recommended then.
    public static func isGrowingSeason(now: Date = Date()) -> Bool {
        switch season(for: now) {
        case .spring, .summer: return true
        case .fall, .winter: return false
        }
    }

    // MARK: Species / profile reading

    /// The combined species/common/botanical/name text, lowercased — the substrate the humidity + drought
    /// classifiers match against.
    static func speciesText(_ plant: CareItem) -> String {
        [plant.species, plant.speciesLatin, plant.name]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    /// `true` for succulents/cacti/drought-tolerant plants — the ones that should NEVER be misted (misting
    /// invites rot). Read from the species name and, as a backstop, a "low humidity / dry air / drought"
    /// signal in the profile's humidity note.
    public static func isDroughtTolerant(_ plant: CareItem) -> Bool {
        let name = speciesText(plant)
        let droughtNames = [
            "succulent", "cactus", "cacti", "aloe", "echeveria", "haworthia", "jade", "crassula",
            "snake plant", "sansevieria", "zz plant", "zamioculcas", "agave", "sedum", "kalanchoe",
            "euphorbia", "ponytail palm", "string of pearls", "burro", "lithops", "yucca", "hoya",
            "desert", "aeonium", "gasteria", "portulaca",
        ]
        if droughtNames.contains(where: { name.contains($0) }) { return true }
        let humidity = (plant.speciesProfile?.humidity ?? "").lowercased()
        let dryHints = ["low humidity", "low-humidity", "dry air", "drought", "arid", "tolerates dry",
                        "prefers dry", "average household"]
        return dryHints.contains { humidity.contains($0) }
    }

    /// `true` for high-humidity-loving plants (calatheas, ferns, tropicals) — the ones that genuinely
    /// benefit from misting. Drought-tolerant plants are excluded first; then a "high humidity / humid /
    /// mist / tropical" signal in the profile's humidity note wins; then a classic humidity-lover species
    /// list as a backstop for plants with no profile.
    public static func lovesHumidity(_ plant: CareItem) -> Bool {
        if isDroughtTolerant(plant) { return false }
        let humidity = (plant.speciesProfile?.humidity ?? "").lowercased()
        let humidHints = ["high humidity", "high-humidity", "loves humidity", "humid", "mist",
                          "tropical", "moist air", "group it"]
        if humidHints.contains(where: { humidity.contains($0) }) { return true }
        let name = speciesText(plant)
        let humidLovers = [
            "calathea", "fern", "maranta", "prayer plant", "nerve plant", "fittonia", "orchid",
            "anthurium", "alocasia", "stromanthe", "ctenanthe", "peace lily", "spathiphyllum",
            "air plant", "tillandsia", "croton", "nephrolepis", "pitcher plant", "carnivorous",
        ]
        return humidLovers.contains { name.contains($0) }
    }

    /// The recommended watering cadence: the plant's OWN existing water-task interval when it has one
    /// (respect what the family already does), else a species-sensible default — drought-tolerant plants
    /// get a longer default (14d) than the general houseplant default (7d).
    public static func waterInterval(for plant: CareItem) -> Int {
        if let existing = plant.tasks.first(where: { $0.title.lowercased().contains("water") }),
           let days = existing.intervalDays {
            return days
        }
        return isDroughtTolerant(plant) ? 14 : 7
    }

    // MARK: Recommendation resolver

    /// The species- and season-tailored recommended templates for `plant`. Reads the ``SpeciesProfile``
    /// (humidity → mist-or-not) and the calendar (`now` → growing-season fertilize-or-not). Order is the
    /// warm reading order: water → rotate → mist → fertilize → prune → pest → re-pot.
    public static func recommendedFor(_ plant: CareItem, now: Date = Date()) -> [PlantCareTemplate] {
        var templates: [PlantCareTemplate] = []

        templates.append(PlantCareTemplate(
            id: "plant-water",
            title: "Water",
            intervalDays: waterInterval(for: plant),
            symbol: "drop.fill",
            note: "The one that matters most — a steady rhythm beats a big drink after a dry spell.",
            matchKeywords: ["water"]
        ))

        templates.append(PlantCareTemplate(
            id: "plant-rotate",
            title: "Rotate",
            intervalDays: 7,
            symbol: "arrow.clockwise",
            note: "A quarter-turn each week keeps it growing straight instead of leaning for the light.",
            matchKeywords: ["rotate"]
        ))

        // Mist — ONLY for humidity-lovers; succulents/cacti/drought-tolerant plants are excluded.
        if lovesHumidity(plant) {
            templates.append(PlantCareTemplate(
                id: "plant-mist",
                title: "Mist",
                intervalDays: 3,
                symbol: "humidity.fill",
                note: "This one loves damp air — a few mists a week keeps the leaf edges from crisping.",
                matchKeywords: ["mist"]
            ))
        }

        // Fertilize — SEASONAL: only in the growing season (spring/summer); rests in fall/winter.
        if isGrowingSeason(now: now) {
            templates.append(PlantCareTemplate(
                id: "plant-fertilize",
                title: "Fertilize",
                intervalDays: 30,
                symbol: "leaf.fill",
                note: "Feed monthly while it's actively growing — then ease off through fall and winter.",
                matchKeywords: ["fertil", "feed"]
            ))
        }

        templates.append(PlantCareTemplate(
            id: "plant-prune",
            title: "Prune",
            intervalDays: 90,
            symbol: "scissors",
            note: "A quarterly tidy of spent or leggy growth keeps it full and encourages new shoots.",
            matchKeywords: ["prune"]
        ))

        templates.append(PlantCareTemplate(
            id: "plant-pest",
            title: "Pest check",
            intervalDays: 30,
            symbol: "ladybug.fill",
            note: "A monthly peek under the leaves catches spider mites and gnats before they settle in.",
            matchKeywords: ["pest"]
        ))

        templates.append(PlantCareTemplate(
            id: "plant-repot",
            title: "Re-pot",
            intervalDays: 365,
            symbol: "shippingbox.fill",
            note: "Fresh soil and a size up once a year keeps the roots happy and the growth going.",
            matchKeywords: ["repot", "re-pot"]
        ))

        return templates
    }

    /// Look up a tailored template by id for a given plant — used by the materialize path so the water
    /// cadence (which varies per plant) is rebuilt correctly. Respects the same season/species tailoring
    /// as ``recommendedFor(_:now:)``.
    public static func template(id: String, for plant: CareItem, now: Date = Date()) -> PlantCareTemplate? {
        recommendedFor(plant, now: now).first { $0.id == id }
    }

    /// Resolve the plant's recommended schedule against its current tasks — each recommendation paired
    /// with the plant's matching task (if any). Drives the setup section + the "N of M on schedule" line.
    public static func schedule(for plant: CareItem, now: Date = Date()) -> PlantSchedule {
        let templates = recommendedFor(plant, now: now)
        let items = templates.map { template in
            PlantScheduleItem(
                template: template,
                existingTask: plant.tasks.first { template.matches($0) }
            )
        }
        return PlantSchedule(items: items)
    }
}
