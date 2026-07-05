import Foundation

/// The kind of a child health recommendation — drives the icon + section grouping on the Health
/// schedule surface. The CHILD analog of ``PetSpecies`` / a plant's care category (P31).
public enum ChildCareCategory: String, Codable, Sendable, CaseIterable, Equatable {
    case wellVisit
    case vaccine
    case dental
    case screening

    public var displayName: String {
        switch self {
        case .wellVisit: "Well-child visit"
        case .vaccine: "Vaccines"
        case .dental: "Dental"
        case .screening: "Vision & hearing"
        }
    }

    /// SF Symbol for the row/section — resolved by the SettingsFeature surface.
    public var iconSymbol: String {
        switch self {
        case .wellVisit: "stethoscope"
        case .vaccine: "syringe.fill"
        case .dental: "mouth.fill"
        case .screening: "eye.fill"
        }
    }
}

/// A recommended well-child pediatric visit at a given age. Pure data — the Health schedule surface
/// turns `ageMonths` into a real calendar date via the kid's birthdate.
public struct WellVisit: Equatable, Sendable, Identifiable {
    /// The child's age (in whole months) the visit is recommended at.
    public let ageMonths: Int
    public var id: Int { ageMonths }

    public init(ageMonths: Int) { self.ageMonths = ageMonths }

    /// The pediatric-schedule label — "2-month checkup", "18-month checkup", "3-year checkup".
    /// Under two we speak in months (how pediatric visits are named); the 30-month visit keeps its
    /// months name; from two years on it's years.
    public var label: String {
        if ageMonths < 24 { return "\(ageMonths)-month checkup" }
        if ageMonths == 30 { return "30-month checkup" }
        if ageMonths % 12 == 0 { return "\(ageMonths / 12)-year checkup" }
        return "\(ageMonths)-month checkup"
    }
}

/// One dated child-health recommendation ahead of a kid — a vaccine round, dental visit, or screening.
/// The age it's due at (`ageMonths`) plus warm copy; the surface resolves the date from the birthday.
public struct ChildCareItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let ageMonths: Int
    public let category: ChildCareCategory
    public let note: String

    public init(id: String, title: String, ageMonths: Int, category: ChildCareCategory, note: String) {
        self.id = id
        self.title = title
        self.ageMonths = ageMonths
        self.category = category
        self.note = note
    }

    /// The pediatric-visit-style age label ("15 months", "4 years") for the item's due age.
    public var ageLabel: String {
        if ageMonths < 24 { return ageMonths == 1 ? "1 month" : "\(ageMonths) months" }
        let years = ageMonths / 12
        let remainder = ageMonths % 12
        if remainder == 0 { return years == 1 ? "1 year" : "\(years) years" }
        return "\(years) yr \(remainder) mo"
    }
}

/// A band of developmental milestones to watch for over an age range — the "log it in Memories!" hook.
/// A few per band (not medical screening tools — cues that a moment is worth capturing).
public struct MilestoneBand: Equatable, Sendable {
    public let lowerMonths: Int
    public let upperMonths: Int
    public let label: String
    public let milestones: [String]

    public init(lowerMonths: Int, upperMonths: Int, label: String, milestones: [String]) {
        self.lowerMonths = lowerMonths
        self.upperMonths = upperMonths
        self.label = label
        self.milestones = milestones
    }

    /// `true` when `months` falls in this band (inclusive lower, exclusive upper).
    public func contains(_ months: Int) -> Bool { months >= lowerMonths && months < upperMonths }
}

/// A kid's resolved child-health schedule at a moment in time — what the Health schedule surface reads.
/// The next well-visit, the upcoming dated items (vaccines/dental/screening) in the near window, and the
/// current developmental milestones to watch. All ages; the surface maps them to dates via the birthday.
public struct ChildSchedule: Equatable, Sendable {
    public let ageInMonths: Int
    public let nextWellVisit: WellVisit?
    public let upcomingItems: [ChildCareItem]
    public let milestoneBandLabel: String?
    public let milestonesToWatch: [String]

    public init(
        ageInMonths: Int,
        nextWellVisit: WellVisit?,
        upcomingItems: [ChildCareItem],
        milestoneBandLabel: String?,
        milestonesToWatch: [String]
    ) {
        self.ageInMonths = ageInMonths
        self.nextWellVisit = nextWellVisit
        self.upcomingItems = upcomingItems
        self.milestoneBandLabel = milestoneBandLabel
        self.milestonesToWatch = milestonesToWatch
    }

    /// The always-shown disclaimer. This is a general guide — never medical advice.
    public static let disclaimer =
        "This is a general guide based on typical pediatric schedules — always follow your pediatrician. "
        + "Every kid grows at their own pace."
}

/// The seeded child-care library (P31) — the CHILD analog of ``PetCareKB`` / ``PlantCareKB``. Age-based
/// recommended child-health milestones: well-child visits, CDC-style vaccine rounds, dental, vision &
/// hearing screening, and developmental milestones to watch. Pure data + a `scheduleFor(ageInMonths:)`
/// resolver. Deliberately framed as reminders "per your pediatrician" — Bacán is a nudge, not a clinic.
public enum ChildCareKB {

    // MARK: - Well-child visits

    /// Recommended well-child visit ages (months). The AAP/Bright Futures cadence: frequent in the first
    /// two years (1, 2, 4, 6, 9, 12, 15, 18, 24, 30 months) then **annual** from 3 years through 18.
    public static let wellVisitAges: [Int] =
        [1, 2, 4, 6, 9, 12, 15, 18, 24, 30] + Array(stride(from: 36, through: 216, by: 12))

    /// Every recommended well-visit as a value.
    public static let wellVisits: [WellVisit] = wellVisitAges.map(WellVisit.init)

    // MARK: - Vaccine milestones (CDC-style; "per your pediatrician")

    /// The routine childhood immunization rounds by age. Represented as **milestone ages**, not doses or
    /// medical instructions — each labeled "per your pediatrician" so the app stays a reminder.
    public static let vaccineItems: [ChildCareItem] = [
        ChildCareItem(
            id: "vax-2mo", title: "2-month shots", ageMonths: 2, category: .vaccine,
            note: "The 2-month round (DTaP, Hib, PCV, polio, rotavirus, hep B) — per your pediatrician."
        ),
        ChildCareItem(
            id: "vax-4mo", title: "4-month shots", ageMonths: 4, category: .vaccine,
            note: "The 4-month round (DTaP, Hib, PCV, polio, rotavirus) — per your pediatrician."
        ),
        ChildCareItem(
            id: "vax-6mo", title: "6-month shots", ageMonths: 6, category: .vaccine,
            note: "The 6-month round (DTaP, Hib, PCV, polio, hep B) plus baby's first flu shot — per your pediatrician."
        ),
        ChildCareItem(
            id: "vax-12mo", title: "12-month shots", ageMonths: 12, category: .vaccine,
            note: "The 1-year round (MMR, chickenpox, hep A, Hib, PCV) — per your pediatrician."
        ),
        ChildCareItem(
            id: "vax-15mo", title: "15–18-month shots", ageMonths: 15, category: .vaccine,
            note: "The toddler boosters (DTaP, hep A) around 15–18 months — per your pediatrician."
        ),
        ChildCareItem(
            id: "vax-4yr", title: "4–6-year shots", ageMonths: 48, category: .vaccine,
            note: "The pre-K boosters (DTaP, polio, MMR, chickenpox) around 4–6 years — per your pediatrician."
        ),
    ]

    // MARK: - Dental

    /// First dental visit ~12 months (first tooth / first birthday), then a checkup every 6 months.
    public static let dentalItems: [ChildCareItem] = {
        var items: [ChildCareItem] = [
            ChildCareItem(
                id: "dental-first", title: "First dental visit", ageMonths: 12, category: .dental,
                note: "The first dentist trip lands around the first birthday (or first tooth). Then every 6 months."
            )
        ]
        for months in stride(from: 18, through: 216, by: 6) {
            items.append(ChildCareItem(
                id: "dental-\(months)", title: "Dental checkup", ageMonths: months, category: .dental,
                note: "A twice-a-year cleaning keeps those little teeth happy."
            ))
        }
        return items
    }()

    // MARK: - Vision & hearing screening

    /// Vision and hearing are checked at well-visits; these are the ages an objective screening is
    /// typically added (newborn hearing, then formal vision screening from age 3).
    public static let screeningItems: [ChildCareItem] = [
        ChildCareItem(
            id: "screen-newborn-hearing", title: "Newborn hearing screen", ageMonths: 0, category: .screening,
            note: "The newborn hearing screen usually happens right at the hospital."
        ),
        ChildCareItem(
            id: "screen-vision-3yr", title: "Vision screening", ageMonths: 36, category: .screening,
            note: "A first formal vision & hearing screening around age 3, at the well-visit."
        ),
        ChildCareItem(
            id: "screen-vision-4yr", title: "Vision & hearing screening", ageMonths: 48, category: .screening,
            note: "Vision & hearing checked again at the 4-year well-visit."
        ),
        ChildCareItem(
            id: "screen-vision-5yr", title: "Vision & hearing screening", ageMonths: 60, category: .screening,
            note: "Vision & hearing checked at the 5-year well-visit before kindergarten."
        ),
    ]

    /// Every dated (non-well-visit) recommendation — vaccines + dental + screening.
    public static let allItems: [ChildCareItem] = vaccineItems + dentalItems + screeningItems

    // MARK: - Developmental milestones to watch

    /// Milestones to watch by age band — the Journal/Memories hook. A handful per band; framed as
    /// "watch for / log it", not a screening checklist.
    public static let milestoneBands: [MilestoneBand] = [
        MilestoneBand(lowerMonths: 0, upperMonths: 4, label: "0–3 months", milestones: [
            "That first real social smile",
            "Following you with their eyes",
            "Lifting their head during tummy time",
        ]),
        MilestoneBand(lowerMonths: 4, upperMonths: 7, label: "4–6 months", milestones: [
            "Rolling over",
            "Babbling and cooing back at you",
            "Reaching for and grabbing toys",
        ]),
        MilestoneBand(lowerMonths: 7, upperMonths: 10, label: "7–9 months", milestones: [
            "Sitting up without support",
            "Responding to their own name",
            "Passing a toy hand to hand",
        ]),
        MilestoneBand(lowerMonths: 10, upperMonths: 13, label: "10–12 months", milestones: [
            "First words (around 12 months — log it!)",
            "Pulling up to stand",
            "Waving bye-bye",
        ]),
        MilestoneBand(lowerMonths: 13, upperMonths: 19, label: "13–18 months", milestones: [
            "First steps and walking on their own",
            "Saying several words",
            "Pointing to show you things",
        ]),
        MilestoneBand(lowerMonths: 19, upperMonths: 25, label: "19–24 months", milestones: [
            "Running (mind the corners!)",
            "Two-word phrases",
            "Following simple instructions",
        ]),
        MilestoneBand(lowerMonths: 25, upperMonths: 37, label: "2–3 years", milestones: [
            "Short sentences and lots of new words",
            "Climbing and kicking a ball",
            "Sorting shapes and colors",
        ]),
        MilestoneBand(lowerMonths: 37, upperMonths: 49, label: "3–4 years", milestones: [
            "Telling little stories",
            "Hopping and pedaling a trike",
            "Drawing a person with a few parts",
        ]),
        MilestoneBand(lowerMonths: 49, upperMonths: 61, label: "4–5 years", milestones: [
            "Counting and knowing colors",
            "Dressing themselves",
            "Telling a longer make-believe story",
        ]),
        MilestoneBand(lowerMonths: 61, upperMonths: 73, label: "5–6 years", milestones: [
            "Writing some letters and their name",
            "Skipping and balancing",
            "Playing games with rules and taking turns",
        ]),
    ]

    /// The developmental band that contains `months` (nil past the last modeled band).
    public static func milestoneBand(forMonths months: Int) -> MilestoneBand? {
        milestoneBands.first { $0.contains(months) }
    }

    // MARK: - Resolver

    /// The default forward window (months) used to gather upcoming dated items.
    public static let defaultWindowMonths = 12

    /// Resolve a child's schedule at `ageInMonths`: the **next well-child visit** (the first recommended
    /// visit at or after this age), the **upcoming dated items** (vaccines/dental/screening) due now or
    /// within the next `windowMonths`, and the **milestones to watch** for the current age band.
    public static func scheduleFor(ageInMonths months: Int, windowMonths: Int = defaultWindowMonths) -> ChildSchedule {
        let clamped = max(0, months)

        let nextWellVisit = wellVisits.first { $0.ageMonths >= clamped }

        let upcoming = allItems
            .filter { $0.ageMonths >= clamped && $0.ageMonths <= clamped + windowMonths }
            .sorted { $0.ageMonths < $1.ageMonths }

        let band = milestoneBand(forMonths: clamped)

        return ChildSchedule(
            ageInMonths: clamped,
            nextWellVisit: nextWellVisit,
            upcomingItems: upcoming,
            milestoneBandLabel: band?.label,
            milestonesToWatch: band?.milestones ?? []
        )
    }

    /// Convenience: resolve straight from a member (nil when the member has no birthday).
    public static func schedule(for member: HouseholdMember, asOf now: Date = Date()) -> ChildSchedule? {
        guard let months = member.ageInMonths(asOf: now) else { return nil }
        return scheduleFor(ageInMonths: months)
    }
}
