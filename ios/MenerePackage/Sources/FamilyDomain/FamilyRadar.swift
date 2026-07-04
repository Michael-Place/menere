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

    /// Items already past their driving date — most-overdue first. The loudest bucket. Renewable only.
    public let expired: [Item]
    /// Items due/expiring within the horizon (not yet past) — soonest first. Renewable only.
    public let upcoming: [Item]
    /// P20-C2 — past-dated HISTORICAL records (a COVID card, a vet visit) demoted OUT of the alarm
    /// into a calm, collapsed "Records" list. Most-recent first. Never on the loud card.
    public let records: [Item]

    public init(expired: [Item], upcoming: [Item], records: [Item] = []) {
        self.expired = expired
        self.upcoming = upcoming
        self.records = records
    }

    /// Every LOUD radar item, expired-first then soonest-upcoming (records excluded — they're calm).
    public var all: [Item] { expired + upcoming }
    /// True when nothing needs the family's attention — records don't count (they never shout).
    public var isEmpty: Bool { expired.isEmpty && upcoming.isEmpty }

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
    public static func compute(
        documents: [Document], pets: [CareItem], now: Date = Date(), horizonDays: Int = 90
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
            records: records.sorted { $0.date > $1.date }    // most-recent record first
        )
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
