import Foundation

/// The **Family Radar** (P20) — a pure, UI-free read of every latent alert sitting in the Family
/// Brain: documents whose `expiryDate` has already passed (EXPIRED — the loudest signal, e.g. an
/// expired pet rabies cert) or whose `dueDate`/`expiryDate` falls inside the attention horizon
/// (UPCOMING — a registration due in 8 days, a renewal). Both the Today "Family Radar" card and the
/// Radar detail list read from this so they always agree on what's urgent, how it's labeled, and how
/// it's ordered. Powers the card's top items + the detail list's Expired / This month / Later groups.
///
/// Mirrors `Document.needsAttention` (soonest of due/expiry within the horizon) but SPLITS the set
/// into expired vs upcoming and attaches a humanized, pet-aware label — the same voice the pets
/// overview uses ("Sprinkle's rabies").
public struct FamilyRadar: Equatable, Sendable {
    /// Which date drives an item — picks the chip glyph/copy (Expired/Expires vs Overdue/Due).
    public enum DateKind: Equatable, Sendable { case due, expiry }

    /// P20-C2 — is a past-dated document an ACTIONABLE renewal or just a past-dated RECORD?
    /// **renewable**: expiry means DO something (rabies/vaccine, registration, license, insurance,
    /// passport, warranty, inspection…) → keeps the loud alert + renew/add-to-calendar action.
    /// **historical**: a record whose date is simply in the past (a COVID-19 card, a vet visit /
    /// clinical summary, a receipt) → demoted to a calm "Records" list, never the alarm.
    public enum RadarKind: String, Equatable, Sendable, CaseIterable { case renewable, historical }

    /// A single radar entry: one document, the date driving it, and the humanized label.
    public struct Item: Equatable, Identifiable, Sendable {
        public let doc: Document
        /// The driving date — the soonest of the doc's due/expiry that landed it on the radar.
        public let date: Date
        public let kind: DateKind
        /// Whole days from `now` to `date` (negative = past-due / expired).
        public let days: Int
        /// The linked pet's display name, if this doc is pet-linked (drives the pawprint + "'s" copy).
        public let petName: String?
        /// Renewable (act on it) vs historical (a past-dated record). Drives loud-vs-quiet routing.
        public let radarKind: RadarKind

        public init(
            doc: Document, date: Date, kind: DateKind, days: Int, petName: String?,
            radarKind: RadarKind = .renewable
        ) {
            self.doc = doc
            self.date = date
            self.kind = kind
            self.days = days
            self.petName = petName
            self.radarKind = radarKind
        }

        public var id: String { doc.id }

        /// Past its driving date — expired (expiry) or overdue (due). The card's LOUD bucket.
        public var isExpired: Bool { days < 0 }
        /// Pet-linked → treated as a vaccine/health item (pawprint icon, "Renew …" reminder path).
        public var isVaccine: Bool { petName != nil }

        /// The humanized headline. Pet-linked → "Sprinkle's rabies" (name + stripped paperwork
        /// nouns); otherwise the document's own title ("Kindercare registration").
        public var label: String {
            guard let petName else { return doc.title }
            return "\(FamilyRadar.firstName(petName))'s \(FamilyRadar.docLabel(doc, petName: petName))"
        }

        /// The row icon: a pawprint for pet items, else the document type's glyph.
        public var iconSymbol: String {
            isVaccine ? "pawprint.fill" : doc.type.symbolName
        }

        /// The title for the idempotent "renew" reminder an expired vaccine offers.
        public var renewTitle: String {
            guard let petName else { return "Renew \(doc.title)" }
            return "Renew \(FamilyRadar.firstName(petName))'s \(FamilyRadar.docLabel(doc, petName: petName))"
        }

        /// A calm year suffix for a demoted historical record — "Rabies card · 2023".
        public var recordSubtitle: String {
            let f = DateFormatter(); f.dateFormat = "yyyy"
            return f.string(from: date)
        }
    }

    /// An OVERDUE **care task** surfaced on the radar as an ACTIONABLE alert — distinct from a
    /// document expiry (which is a paperwork/renewal signal). The care system (`CareItem`/`CareTask`,
    /// kind house/zone/plant/pet) already knows what's overdue; the radar promotes those onto the
    /// family's can't-miss surface next to the doc alerts.
    ///
    /// High-signal by design: overdue **house/zone** maintenance ("HVAC filter") and overdue **pet**
    /// care ("Sprinkle: heartworm") each get their own row, but overdue **plant watering** is
    /// high-volume (the house has 32 plants), so it's SUMMARIZED into a single "N plants need water"
    /// row rather than N rows — one glance, not a flood. A grouped row is informational (no single
    /// entity to act on); a single-task row carries a one-tap "mark done".
    public struct CareRadarItem: Equatable, Identifiable, Sendable {
        /// The flavor of care — drives the row's glyph, copy, and tap target.
        public enum Category: String, Equatable, Sendable, CaseIterable {
            case house      // house + zone maintenance (HVAC filter, gutters, deep-clean rotation)
            case pet        // Fajita/Sprinkle meds, heartworm, grooming
            case plant      // watering / prune / re-pot
        }

        public let id: String
        /// The humanized headline — "HVAC filter", "Sprinkle: heartworm", "6 plants need water".
        public let label: String
        /// The row glyph (the care item's own icon, or a droplet for the grouped water summary).
        public let iconSymbol: String
        /// Whole days past due for the most-overdue task this row represents (positive = days over).
        public let daysOver: Int
        public let category: Category
        /// The care item this row acts on — **nil only** for the grouped multi-plant water summary.
        public let careItemID: String?
        /// The specific overdue task — **nil only** for the grouped multi-plant water summary.
        public let taskID: String?
        /// How many overdue tasks this row stands for (1 for a single task; N for "N plants need water").
        public let count: Int

        public init(
            id: String, label: String, iconSymbol: String, daysOver: Int, category: Category,
            careItemID: String?, taskID: String?, count: Int = 1
        ) {
            self.id = id
            self.label = label
            self.iconSymbol = iconSymbol
            self.daysOver = daysOver
            self.category = category
            self.careItemID = careItemID
            self.taskID = taskID
            self.count = count
        }

        /// A single, actionable task (house/pet/single plant) → offers a one-tap "mark done". The
        /// grouped multi-plant water summary is informational only (no single task to complete).
        public var isActionable: Bool { careItemID != nil && taskID != nil }
    }

    /// Items already past their driving date — most-overdue first. The loudest bucket. Renewable only.
    public let expired: [Item]
    /// Items due/expiring within the horizon (not yet past) — soonest first. Renewable only.
    public let upcoming: [Item]
    /// P20-C2 — past-dated HISTORICAL records (a COVID card, a vet visit) demoted OUT of the alarm
    /// into a calm, collapsed "Records" list. Most-recent first. Never on the loud card.
    public let records: [Item]
    /// Overdue CARE tasks (house/pet/plant) promoted onto the radar — most-overdue first. An
    /// ACTIONABLE category alongside the document alerts.
    public let care: [CareRadarItem]

    public init(
        expired: [Item], upcoming: [Item], records: [Item] = [], care: [CareRadarItem] = []
    ) {
        self.expired = expired
        self.upcoming = upcoming
        self.records = records
        self.care = care
    }

    /// Every LOUD radar item, expired-first then soonest-upcoming (records excluded — they're calm).
    public var all: [Item] { expired + upcoming }
    /// True when nothing needs the family's attention — records don't count (they never shout), but
    /// an overdue care task does.
    public var isEmpty: Bool { expired.isEmpty && upcoming.isEmpty && care.isEmpty }

    /// The top items for the compact Today card — expired first, capped so the card stays glanceable.
    public func topItems(limit: Int = 4) -> [Item] { Array(all.prefix(limit)) }

    /// Build the radar from every document + the household's pets.
    ///
    /// - **EXPIRED** (the loud bucket): a document whose `expiryDate` has already passed — a vaccine
    ///   cert, warranty, or registration that needs renewing. A stale past *due* date (a closed
    ///   mortgage's disclosure) is deliberately NOT an alert — only a past *expiry* is.
    /// - **UPCOMING**: the soonest of a document's `dueDate`/`expiryDate` that falls inside
    ///   `[today, horizonDays]` — a registration due in 8 days, a warranty expiring next month.
    ///
    /// Pet association is by `linkedPetIds` (names the pet in the label). Expired sorts most-overdue
    /// first; upcoming sorts soonest first.
    ///
    /// `careItems` (the household's whole care roster — a superset of `pets`) additionally feeds the
    /// ACTIONABLE overdue-care rows via ``computeCare(careItems:now:)``; pass `[]` to keep the
    /// documents-only radar. `pets` still drives the pet-name labels on vaccine documents.
    public static func compute(
        documents: [Document], pets: [CareItem], careItems: [CareItem] = [],
        now: Date = Date(), horizonDays: Int = 90
    ) -> FamilyRadar {
        var expired: [Item] = []
        var upcoming: [Item] = []
        var records: [Item] = []
        for doc in documents {
            let petName = pets.first { pet in doc.linkedPetIds.contains(pet.id) }?.name
            let radarKind = classify(doc)

            // EXPIRED: a past expiry date claims the whole item — the loudest, most-actionable signal.
            if let expiry = doc.expiryDate {
                let days = Document.dayCount(from: now, to: expiry)
                if days < 0 {
                    let item = Item(doc: doc, date: expiry, kind: .expiry, days: days,
                                    petName: petName, radarKind: radarKind)
                    // Historical past-dated docs are RECORDS, not alarms → the calm list, never the card.
                    if radarKind == .historical {
                        records.append(item)
                    } else if !isDismissed(doc, now: now) {
                        // Dismissed (snoozed) renewables drop off the loud card until their snooze lapses.
                        expired.append(item)
                    }
                    continue
                }
            }

            // Only RENEWABLE items ever shout an upcoming reminder; historical upcoming dates stay quiet.
            guard radarKind == .renewable, !isDismissed(doc, now: now) else { continue }

            // UPCOMING: consider due and expiry independently; take the soonest inside the horizon.
            var candidates: [(date: Date, kind: DateKind)] = []
            if let due = doc.dueDate { candidates.append((due, .due)) }
            if let expiry = doc.expiryDate { candidates.append((expiry, .expiry)) }
            let soonest = candidates
                .map { (date: $0.date, kind: $0.kind, days: Document.dayCount(from: now, to: $0.date)) }
                .filter { $0.days >= 0 && $0.days <= horizonDays }
                .min { $0.days < $1.days }
            if let soonest {
                upcoming.append(Item(doc: doc, date: soonest.date, kind: soonest.kind,
                                     days: soonest.days, petName: petName, radarKind: radarKind))
            }
        }
        return FamilyRadar(
            expired: expired.sorted { $0.days < $1.days },   // most overdue first
            upcoming: upcoming.sorted { $0.days < $1.days }, // soonest first
            records: records.sorted { $0.date > $1.date },   // most-recent record first
            care: computeCare(careItems: careItems, now: now)
        )
    }

    // MARK: Overdue care (P20 care extension)

    /// Build the ACTIONABLE overdue-care rows from the household's care roster.
    ///
    /// Only truly **overdue** tasks qualify (`CareTask.isOverdue` — a real anchor that's in the past),
    /// so a never-done, un-anchored task doesn't cry wolf. Then:
    /// - **house / zone** upkeep → one row each ("HVAC filter", "Deep clean: kitchen").
    /// - **pet** care → one row each, name-first ("Sprinkle: heartworm").
    /// - **plant watering** → SUMMARIZED: one "N plants need water" row when 2+ plants are overdue on a
    ///   watering task (a single overdue plant reads as its own "Japanese maple: water" row). This is
    ///   the volume valve — 32 plants must never become 32 radar rows.
    /// - other **plant** tasks (prune, re-pot, fertilize) → one row each — low-volume, so no grouping.
    ///
    /// Rows sort most-overdue first.
    public static func computeCare(careItems: [CareItem], now: Date = Date()) -> [CareRadarItem] {
        var rows: [CareRadarItem] = []
        // (item, task, daysOver) for every plant on an overdue WATERING task — grouped below.
        var overdueWatering: [(item: CareItem, task: CareTask, daysOver: Int)] = []

        for item in careItems {
            for task in item.tasks where task.isOverdue(now: now) {
                let daysOver = -(task.daysUntilDue(now: now) ?? 0)   // overdue ⇒ positive
                switch item.kind {
                case .plant where isWateringTask(task):
                    overdueWatering.append((item, task, daysOver))
                case .plant:
                    rows.append(CareRadarItem(
                        id: "care-\(item.id)-\(task.id)",
                        label: careLabel(item: item, task: task),
                        iconSymbol: item.iconSymbol, daysOver: daysOver, category: .plant,
                        careItemID: item.id, taskID: task.id
                    ))
                case .pet:
                    rows.append(CareRadarItem(
                        id: "care-\(item.id)-\(task.id)",
                        label: "\(firstName(item.name)): \(task.title.lowercased())",
                        iconSymbol: item.iconSymbol, daysOver: daysOver, category: .pet,
                        careItemID: item.id, taskID: task.id
                    ))
                case .house, .zone:
                    rows.append(CareRadarItem(
                        id: "care-\(item.id)-\(task.id)",
                        label: careLabel(item: item, task: task),
                        iconSymbol: item.iconSymbol, daysOver: daysOver, category: .house,
                        careItemID: item.id, taskID: task.id
                    ))
                }
            }
        }

        // Summarize overdue plant watering: 1 plant → its own actionable row; 2+ → one grouped row.
        if overdueWatering.count == 1, let only = overdueWatering.first {
            rows.append(CareRadarItem(
                id: "care-\(only.item.id)-\(only.task.id)",
                label: "\(only.item.name): needs water",
                iconSymbol: "drop.fill", daysOver: only.daysOver, category: .plant,
                careItemID: only.item.id, taskID: only.task.id
            ))
        } else if overdueWatering.count > 1 {
            let worst = overdueWatering.map(\.daysOver).max() ?? 0
            rows.append(CareRadarItem(
                id: "care-plants-water",
                label: "\(overdueWatering.count) plants need water",
                iconSymbol: "drop.fill", daysOver: worst, category: .plant,
                careItemID: nil, taskID: nil, count: overdueWatering.count
            ))
        }

        return rows.sorted { $0.daysOver > $1.daysOver }   // most overdue first
    }

    /// A watering task — the high-volume plant chore we summarize rather than list per-plant.
    static func isWateringTask(_ task: CareTask) -> Bool {
        task.title.lowercased().contains("water")
    }

    /// A short row headline for a care task, de-duplicating a name that already contains the task (or
    /// vice-versa): item "HVAC filter" + task "Replace filter" → "HVAC filter — Replace filter" only
    /// when they don't overlap; when one contains the other, the longer wins.
    static func careLabel(item: CareItem, task: CareTask) -> String {
        let name = item.name.trimmingCharacters(in: .whitespaces)
        let title = task.title.trimmingCharacters(in: .whitespaces)
        let n = name.lowercased(), t = title.lowercased()
        if t.contains(n) { return title }
        if n.contains(t) { return name }
        return "\(name): \(title.lowercased())"
    }

    /// Whether a document is currently snoozed off the loud radar (family tapped Dismiss/Snooze).
    static func isDismissed(_ doc: Document, now: Date) -> Bool {
        guard let until = doc.radarDismissedUntil else { return false }
        return until > now
    }

    // MARK: Renewable vs historical classification (P20-C2)

    /// Keywords that mean a past date is an ACTIONABLE renewal — err toward these to keep the alarm.
    static let renewableKeywords: Set<String> = [
        "rabies", "vaccine", "vaccination", "vaccinated", "registration", "license", "licence",
        "permit", "insurance", "policy", "passport", "visa", "membership", "subscription",
        "warranty", "inspection", "renewal", "renew", "certification", "credential",
    ]

    /// Strong markers that a document is a past-dated RECORD, not a to-do — these WIN over a renewable
    /// keyword that happens to co-occur (a COVID-19 "vaccination card" is a record, not a renewal).
    static let historicalKeywords: Set<String> = [
        "card", "history", "clinical", "summary", "photo", "statement", "receipt", "invoice",
        "result", "results", "lab", "labs", "discharge", "visit", "note", "notes", "closed",
        "disclosure", "transcript", "diagnosis", "test",
    ]

    /// Classify a document as **renewable** (loud, act-on-it) or **historical** (a calm past record).
    /// Order matters:
    /// 1. `.receipt`-typed docs are always historical.
    /// 2. A strong historical marker in the TITLE **or** TAGS wins first — a COVID "card" or an ER
    ///    "photo" stays a record even though "vaccination" is also a renewable word.
    /// 3. Renewable only when the **TITLE** names the renewable thing (a "Rabies" cert, a
    ///    "Registration"). Anchoring to the title — not tags — is deliberate: the "Stage Road Vet"
    ///    visit is tagged `rabies` (it's the same appointment as the cert) yet its title names no
    ///    renewal, so it stays a quiet record instead of duplicating the rabies alert.
    /// 4. Otherwise lean historical so an ambiguous doc never cries wolf.
    public static func classify(_ doc: Document) -> RadarKind {
        if doc.type == .receipt { return .historical }
        let titleTokens = tokenize(doc.title)
        let tagTokens = doc.tags.reduce(into: Set<String>()) { $0.formUnion(tokenize($1)) }
        // Strong record markers (title OR tags) win — a COVID card, an ER photo, a lab result.
        if !titleTokens.isDisjoint(with: historicalKeywords)
            || !tagTokens.isDisjoint(with: historicalKeywords) { return .historical }
        // Renewable only when the TITLE itself names the renewable thing.
        if !titleTokens.isDisjoint(with: renewableKeywords) { return .renewable }
        return .historical   // ambiguous → don't cry wolf
    }

    /// Lowercased, punctuation-split word tokens of a string.
    private static func tokenize(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    // MARK: Humanization (matches the pets overview's voice)

    /// First whitespace token of a name — "Sprinkle Fajardo" → "Sprinkle".
    static func firstName(_ full: String) -> String {
        full.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? full
    }

    /// A short human label for a linked doc — strips the pet's name and generic paperwork nouns so
    /// "Sprinkle's Rabies Vaccination Certificate" reads as "rabies". Falls back to the full title.
    static func docLabel(_ doc: Document, petName: String) -> String {
        let petFirst = firstName(petName).lowercased()
        let drop: Set<String> = [
            "certificate", "certificates", "record", "records", "vaccine", "vaccines",
            "vaccination", "vaccinations", "shot", "shots", "doc", "document", "report", "proof", "the",
        ]
        let words = doc.title.split(whereSeparator: { $0.isWhitespace }).compactMap { raw -> String? in
            var w = String(raw).lowercased()
            if w.hasSuffix("'s") { w = String(w.dropLast(2)) }
            w = w.trimmingCharacters(in: .punctuationCharacters)
            if w.isEmpty || w == petFirst || drop.contains(w) { return nil }
            return w
        }
        let label = words.joined(separator: " ")
        return label.isEmpty ? doc.title : label
    }
}
