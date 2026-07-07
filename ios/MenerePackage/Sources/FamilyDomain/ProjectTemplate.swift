import Foundation

/// **Projects PR4 — the Project KB.** A starter template for a big family undertaking: a suggested
/// phase, a real, useful starter checklist, and a "things people forget" list (the hard-won stuff
/// that trips families up). Selecting a template in the new-project flow pre-fills the workspace so
/// the family starts with structure instead of a blank page — the same idea as the Care Schedules KB.
///
/// Pure data (no UI, no network) so it lives in `FamilyDomain`. The view layer maps each template to
/// its accent color; `ProjectPhasePalette` already owns the phase → color mapping.
public struct ProjectTemplate: Identifiable, Equatable, Sendable {
    public let id: String
    /// The template's name — also a sensible default project name ("Pool build").
    public let title: String
    /// An SF Symbol for the picker row + card.
    public let systemImage: String
    /// The phase this kind of project usually starts in.
    public let phaseSuggestion: ProjectPhase
    /// A ready-made checklist — the concrete first moves.
    public let starterTasks: [String]
    /// The things people *forget* — surfaced into the project's notes so nothing slips.
    public let forgetNots: [String]
    /// A one-line summary prefill (also the picker-row subtitle).
    public let summaryHint: String

    public init(
        id: String,
        title: String,
        systemImage: String,
        phaseSuggestion: ProjectPhase,
        starterTasks: [String],
        forgetNots: [String],
        summaryHint: String
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.phaseSuggestion = phaseSuggestion
        self.starterTasks = starterTasks
        self.forgetNots = forgetNots
        self.summaryHint = summaryHint
    }

    /// The blank / "start from scratch" option — no seeded tasks or notes.
    public var isBlank: Bool { starterTasks.isEmpty && forgetNots.isEmpty }

    /// The starter checklist as real ``ProjectTask``s (all unchecked).
    public func starterProjectTasks() -> [ProjectTask] {
        starterTasks.map { ProjectTask(title: $0) }
    }

    /// The seed notes: the summary line followed by a **Don't forget** Markdown checklist of the
    /// `forgetNots`. Returns `nil` for the blank template (nothing to seed).
    public func starterNotes() -> String? {
        guard !forgetNots.isEmpty else { return nil }
        var lines: [String] = []
        let hint = summaryHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty { lines.append(hint); lines.append("") }
        lines.append("**Don't forget**")
        for item in forgetNots { lines.append("- \(item)") }
        return lines.joined(separator: "\n")
    }

    /// Look a template up by id (nil for unknown / the blank sentinel handled by callers).
    public static func named(_ id: String) -> ProjectTemplate? {
        catalog.first { $0.id == id }
    }
}

extension ProjectTemplate {
    /// The starter catalog. Each entry carries a genuinely useful first-move checklist plus the
    /// "things people forget" that families learn the hard way. Warm, first-name voice in copy where
    /// it fits (Oliver's school, the dogs). The blank/custom option is last.
    public static let catalog: [ProjectTemplate] = [
        ProjectTemplate(
            id: "pool",
            title: "Pool build",
            systemImage: "figure.pool.swim",
            phaseSuggestion: .researching,
            starterTasks: [
                "Call three pool builders for quotes",
                "Check HOA rules and pull city permits",
                "Confirm each builder's license and insurance",
                "Decide: gunite vs. fiberglass vs. vinyl",
                "Plan the safety fence and gate alarms",
                "Set the budget and line up financing",
                "Schedule the dig and inspection dates",
            ],
            forgetNots: [
                "Verify each builder's license AND liability insurance before you sign anything",
                "HOA approval and city permits can take weeks — start those early",
                "Budget for the ongoing costs: chemicals, electricity, cleaning, winterizing",
                "Safety first with the kids: code-compliant fence, self-closing gate, alarms, a cover",
                "Figure out how the dig equipment reaches the yard — protect sprinklers and lines",
                "Ask about the warranty and who actually services the pool after it's built",
            ],
            summaryHint: "Building a backyard pool — gathering builders, quotes, and permits."
        ),
        ProjectTemplate(
            id: "renovation",
            title: "Home renovation",
            systemImage: "hammer.fill",
            phaseSuggestion: .researching,
            starterTasks: [
                "Define the scope: must-haves vs. nice-to-haves",
                "Get three contractor bids",
                "Verify license, insurance, and references",
                "Set the budget with a contingency",
                "Check which permits you'll need",
                "Plan a temporary kitchen / living setup",
                "Pick materials and finishes",
            ],
            forgetNots: [
                "Add a 10–20% contingency — surprises behind the walls are guaranteed",
                "Get everything in a written contract with a clear payment schedule",
                "Confirm permits and inspections — unpermitted work bites you at resale",
                "Ask about the timeline AND what happens if it slips",
                "Order long-lead items (windows, cabinets, tile) early",
                "Take before/after photos for insurance and your records",
            ],
            summaryHint: "A home renovation — scope, bids, and budget."
        ),
        ProjectTemplate(
            id: "school",
            title: "School search",
            systemImage: "backpack.fill",
            phaseSuggestion: .researching,
            starterTasks: [
                "List the must-haves: distance, hours, philosophy, budget",
                "Shortlist four or five schools",
                "Book tours and open houses",
                "Note each application deadline",
                "Gather records and line up recommendations",
                "Compare tuition plus aftercare costs",
                "Plan Oliver's transition from Kindercare",
            ],
            forgetNots: [
                "Write down EACH school's application deadline — they vary a lot",
                "Ask about waitlists and when offer letters actually go out",
                "Line up recommendation letters early — people need lead time",
                "Check aftercare and hours against your work schedule",
                "Plan a gentle transition for Oliver — visits, and real goodbyes at Kindercare",
                "Tour on a normal day, not just during the polished open house",
            ],
            summaryHint: "Finding Oliver's next school — tours, deadlines, and the big transition."
        ),
        ProjectTemplate(
            id: "trip",
            title: "Trip or vacation",
            systemImage: "airplane",
            phaseSuggestion: .researching,
            starterTasks: [
                "Pick the dates and destination",
                "Set a budget",
                "Book flights and lodging",
                "Sketch a rough day-by-day plan",
                "Check passports, IDs, and documents",
                "Arrange care for the dogs and the house",
                "Build a packing list",
            ],
            forgetNots: [
                "Check passport expiry — many countries need six months of validity",
                "Line up care for Fajita & Sprinkle plus someone for the house and plants",
                "Travel insurance, and let your bank know you're traveling",
                "Confirm car seats, stroller, and kid gear at the destination",
                "Download offline maps and keep every confirmation in one place",
                "Leave an itinerary with someone you trust",
            ],
            summaryHint: "Planning a family trip — dates, bookings, and logistics."
        ),
        ProjectTemplate(
            id: "party",
            title: "Big party",
            systemImage: "party.popper.fill",
            phaseSuggestion: .researching,
            starterTasks: [
                "Set the date, headcount, and budget",
                "Pick and book the venue",
                "Send invites and track RSVPs",
                "Plan the food and drinks",
                "Line up the cake or dessert",
                "Arrange decorations and entertainment",
                "Make a day-of timeline",
            ],
            forgetNots: [
                "Send invites early and track RSVPs so your headcount is real",
                "Ask about dietary restrictions and allergies",
                "Have a weather plan — shade, heat, or an indoor backup",
                "Don't forget the unglamorous stuff: ice, trash bags, parking, restrooms",
                "Line up help for setup AND cleanup",
                "Set a rain / backup date if it's outdoors",
            ],
            summaryHint: "Throwing a big party — venue, guests, food, and fun."
        ),
        ProjectTemplate(
            id: "baby",
            title: "New baby",
            systemImage: "figure.and.child.holdinghands",
            phaseSuggestion: .dreaming,
            starterTasks: [
                "Choose a pediatrician",
                "Set up the nursery",
                "Install the car seat and get it checked",
                "Pack the hospital bag",
                "Sort parental leave and finances",
                "Line up help for the first few weeks",
                "Add the baby to health insurance",
            ],
            forgetNots: [
                "Get the car seat installation checked by a certified tech",
                "Add the baby to health insurance within the enrollment window",
                "Line up help and meals for the first two weeks",
                "Start the parental-leave paperwork early",
                "Prep Oliver and Famfis for a new sibling",
                "Knock out the newborn to-do list: birth certificate, SSN, first pediatrician visit",
            ],
            summaryHint: "Getting ready for a new baby — nursery, gear, and the first weeks."
        ),
        ProjectTemplate(
            id: "car",
            title: "Car purchase",
            systemImage: "car.fill",
            phaseSuggestion: .researching,
            starterTasks: [
                "Set the budget and get financing pre-approval",
                "Shortlist models and must-have features",
                "Check reliability and total cost of ownership",
                "Get quotes from a few dealers",
                "Line up your trade-in value",
                "Test drive the top choices",
                "Review the full out-the-door price and fees",
            ],
            forgetNots: [
                "Get financing pre-approval BEFORE you walk into the dealership",
                "Compare the out-the-door price, not the monthly payment",
                "Check the insurance cost for the model before you buy",
                "Watch for junk fees buried in the paperwork",
                "Buying used? Get a pre-purchase inspection and a history report",
                "Make sure Oliver and Famfis' car seats actually fit",
            ],
            summaryHint: "Buying a car — budget, models, and the best deal."
        ),
        ProjectTemplate(
            id: "moving",
            title: "Moving",
            systemImage: "shippingbox.fill",
            phaseSuggestion: .researching,
            starterTasks: [
                "Set the move date and budget",
                "Get three mover quotes (or plan the DIY)",
                "Sort, declutter, and donate",
                "Gather packing supplies",
                "Transfer utilities and update your address",
                "Pack a first-night essentials box",
                "Update your address everywhere",
            ],
            forgetNots: [
                "Schedule / transfer utilities for the new place BEFORE move day",
                "Forward mail and update your address: bank, insurance, DMV, schools",
                "Pack a 'first night' box — meds, chargers, toiletries, kid comfort items",
                "Verify the mover's license and insurance, and read the contract",
                "Measure big furniture against the doorways",
                "Keep valuables and documents with you, not on the truck",
            ],
            summaryHint: "Moving to a new home — movers, packing, and logistics."
        ),
        ProjectTemplate(
            id: "landscaping",
            title: "Landscaping",
            systemImage: "leaf.fill",
            phaseSuggestion: .dreaming,
            starterTasks: [
                "Define the vision and the zones",
                "Set a budget",
                "Get designer / landscaper quotes",
                "Check irrigation and drainage",
                "Pick plants for your climate",
                "Plan the phasing — what comes first",
                "Confirm permits or HOA rules if needed",
            ],
            forgetNots: [
                "Call 811 before ANY digging — buried utility lines",
                "Plan irrigation and drainage before you plant anything",
                "Pick plants for your zone and the real sun/shade situation",
                "Budget for ongoing maintenance (or a service)",
                "Check HOA rules on trees, fences, and structures",
                "Phase it — you don't have to do the whole yard at once",
            ],
            summaryHint: "A landscaping project — design, plants, and phasing."
        ),
        ProjectTemplate(
            id: "custom",
            title: "Start from scratch",
            systemImage: "square.dashed",
            phaseSuggestion: .dreaming,
            starterTasks: [],
            forgetNots: [],
            summaryHint: ""
        ),
    ]
}
