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

        public init(doc: Document, date: Date, kind: DateKind, days: Int, petName: String?) {
            self.doc = doc
            self.date = date
            self.kind = kind
            self.days = days
            self.petName = petName
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
    }

    /// Items already past their driving date — most-overdue first. The loudest bucket.
    public let expired: [Item]
    /// Items due/expiring within the horizon (not yet past) — soonest first.
    public let upcoming: [Item]

    public init(expired: [Item], upcoming: [Item]) {
        self.expired = expired
        self.upcoming = upcoming
    }

    /// Every radar item, expired-first then soonest-upcoming.
    public var all: [Item] { expired + upcoming }
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
        for doc in documents {
            let petName = pets.first { pet in doc.linkedPetIds.contains(pet.id) }?.name

            // EXPIRED: a past expiry date claims the whole item — the loudest, most-actionable signal.
            if let expiry = doc.expiryDate {
                let days = Document.dayCount(from: now, to: expiry)
                if days < 0 {
                    expired.append(Item(doc: doc, date: expiry, kind: .expiry, days: days, petName: petName))
                    continue
                }
            }

            // UPCOMING: consider due and expiry independently; take the soonest inside the horizon.
            var candidates: [(date: Date, kind: DateKind)] = []
            if let due = doc.dueDate { candidates.append((due, .due)) }
            if let expiry = doc.expiryDate { candidates.append((expiry, .expiry)) }
            let soonest = candidates
                .map { (date: $0.date, kind: $0.kind, days: Document.dayCount(from: now, to: $0.date)) }
                .filter { $0.days >= 0 && $0.days <= horizonDays }
                .min { $0.days < $1.days }
            if let soonest {
                upcoming.append(Item(doc: doc, date: soonest.date, kind: soonest.kind, days: soonest.days, petName: petName))
            }
        }
        return FamilyRadar(
            expired: expired.sorted { $0.days < $1.days },   // most overdue first
            upcoming: upcoming.sorted { $0.days < $1.days }  // soonest first
        )
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
