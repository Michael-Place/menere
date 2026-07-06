import Foundation

/// The kind of a Family-Brain document. Each case carries a user-facing display name and an
/// SF Symbol; UI layers map these to tints (kept out of `FamilyDomain` so it stays UI-free).
///
/// `pet` is included now — pet linking (`Document.linkedPetIds`) is a P10 feature, but keeping the
/// case + field present today keeps C2's extraction schema stable.
public enum DocumentType: String, Codable, CaseIterable, Sendable, Equatable {
    case receipt
    case medical
    case school
    case pet
    case tax
    case manual
    case other

    public var displayName: String {
        switch self {
        case .receipt: "Receipt"
        case .medical: "Medical"
        case .school: "School"
        case .pet: "Pet"
        case .tax: "Tax"
        case .manual: "Manual"
        case .other: "Document"
        }
    }

    public var symbolName: String {
        switch self {
        case .receipt: "receipt"
        case .medical: "cross.case.fill"
        case .school: "graduationcap.fill"
        case .pet: "pawprint.fill"
        case .tax: "building.columns.fill"
        case .manual: "book.closed.fill"
        case .other: "doc.fill"
        }
    }
}

/// Where a document is in the intake → AI pipeline. Intake (P7-C1) writes `.pending`; the
/// `processDocument` Cloud Function (P7-C2) flips it to `.processed` (or `.failed`).
public enum DocumentProcessingState: String, Codable, Sendable, Equatable {
    case pending
    case processed
    case failed
}

/// A Family-Brain document: a scanned / imported artifact (receipt, medical form, school paper,
/// appliance manual, …) plus the structured fields AI extracts from it. The family's "second brain".
///
/// Intake (C1) uploads page images (or a PDF) to Storage and creates this doc with
/// `processingState == .pending` and only `title` / `type: .other` filled; the AI fields
/// (`tags`, `summary`, `amount`, dates, …) are populated later by C2's `processDocument`.
///
/// Persisted at `households/{hid}/documents/{id}`; page files live in Storage under
/// `households/{hid}/documents/{id}/…` (paths recorded in `pagePaths`, in page order).
public struct Document: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var type: DocumentType
    /// AI-suggested / user tags for local full-text filtering (C3).
    public var tags: [String]
    /// `HouseholdMember.id`s this document is about (e.g. a doctor's note for Famfis).
    public var linkedMemberIds: [String]
    /// Linked pet ids — pets arrive in P10; field kept now so C2's schema is stable.
    public var linkedPetIds: [String]
    /// Linked plant / care-item ids (`CareItem.id`, typically `kind == .plant`) this document relates
    /// to — the Green Thumb receipt → the plants it bought (Act V V1-A, receipt↔entity). Decode-safe
    /// optional (older docs → nil); the AI pipeline never writes it, so it survives re-processing.
    /// Pets keep their own `linkedPetIds`; this is the plant/garden half of the same idea.
    public var linkedCareItemIds: [String]?
    /// Linked project-list item ids (`ListItem.id` inside a `.project` FamilyList) — the Deck Daddy's
    /// invoice → the deck project item (Act V V1-A). Decode-safe optional (older docs → nil); the AI
    /// pipeline never writes it, so it survives re-processing.
    public var linkedProjectItemIds: [String]?
    /// The date printed on the document itself (invoice date, visit date), if detected.
    public var docDate: Date?
    /// An actionable due date (a bill due, a form deadline) → can suggest a calendar event.
    public var dueDate: Date?
    /// An expiry date (a warranty, a vaccination cert) → can drive a reminder.
    public var expiryDate: Date?
    /// A monetary amount (receipt total, invoice), if detected.
    public var amount: Double?
    /// The vendor / issuer / provider (store, clinic, school), if detected.
    public var vendor: String?
    /// A one-line AI summary of the document.
    public var summary: String?
    /// Full extracted text (OCR / vision) — powers local search (C3).
    public var extractedText: String?
    /// Storage paths of the document's pages, in page order (`page-0.jpg…` or `document.pdf`).
    public var pagePaths: [String]
    /// P20-C2 — when set and in the future, this document is SNOOZED off the Family Radar's loud
    /// card until this instant (family tapped "Dismiss" / "Snooze"). Decode-safe (nil = never
    /// dismissed); the AI pipeline never writes it, so it survives re-processing.
    public var radarDismissedUntil: Date?
    /// The family's personal notes on this document, stored as a portable **Markdown string**
    /// (Rich-Text C1). Optional + decode-safe: the AI pipeline never writes it, so it survives
    /// re-processing; older docs omit the field and empty/plain strings render as unformatted text.
    public var notes: String?
    /// The uid of the member who filed it.
    public var uploadedBy: String
    public var createdAt: Date
    public var processingState: DocumentProcessingState

    public init(
        id: String = UUID().uuidString,
        title: String,
        type: DocumentType = .other,
        tags: [String] = [],
        linkedMemberIds: [String] = [],
        linkedPetIds: [String] = [],
        linkedCareItemIds: [String]? = nil,
        linkedProjectItemIds: [String]? = nil,
        docDate: Date? = nil,
        dueDate: Date? = nil,
        expiryDate: Date? = nil,
        amount: Double? = nil,
        vendor: String? = nil,
        summary: String? = nil,
        extractedText: String? = nil,
        pagePaths: [String] = [],
        radarDismissedUntil: Date? = nil,
        notes: String? = nil,
        uploadedBy: String,
        createdAt: Date = Date(),
        processingState: DocumentProcessingState = .pending
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.tags = tags
        self.linkedMemberIds = linkedMemberIds
        self.linkedPetIds = linkedPetIds
        self.linkedCareItemIds = linkedCareItemIds
        self.linkedProjectItemIds = linkedProjectItemIds
        self.docDate = docDate
        self.dueDate = dueDate
        self.expiryDate = expiryDate
        self.amount = amount
        self.vendor = vendor
        self.summary = summary
        self.extractedText = extractedText
        self.pagePaths = pagePaths
        self.radarDismissedUntil = radarDismissedUntil
        self.notes = notes
        self.uploadedBy = uploadedBy
        self.createdAt = createdAt
        self.processingState = processingState
    }

    /// The soonest actionable date driving "attention": the earlier of `dueDate` / `expiryDate`,
    /// or nil when neither is set. Powers the Today "Needs attention" card and detail chips.
    public var soonestActionableDate: Date? {
        [dueDate, expiryDate].compactMap { $0 }.min()
    }

    /// Whole calendar days from `now` to `date` (negative = past-due). Day-granular so "today" is 0.
    public static func dayCount(from now: Date, to date: Date, calendar: Calendar = .current) -> Int {
        let a = calendar.startOfDay(for: now)
        let b = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// True when `soonestActionableDate` is past-due or within `days` days of `now`.
    public func needsAttention(now: Date, within days: Int = 30, calendar: Calendar = .current) -> Bool {
        guard let date = soonestActionableDate else { return false }
        return Self.dayCount(from: now, to: date, calendar: calendar) <= days
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        type = try c.decodeIfPresent(DocumentType.self, forKey: .type) ?? .other
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        linkedMemberIds = try c.decodeIfPresent([String].self, forKey: .linkedMemberIds) ?? []
        linkedPetIds = try c.decodeIfPresent([String].self, forKey: .linkedPetIds) ?? []
        linkedCareItemIds = try c.decodeIfPresent([String].self, forKey: .linkedCareItemIds)
        linkedProjectItemIds = try c.decodeIfPresent([String].self, forKey: .linkedProjectItemIds)
        docDate = try c.decodeIfPresent(Date.self, forKey: .docDate)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        expiryDate = try c.decodeIfPresent(Date.self, forKey: .expiryDate)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        extractedText = try c.decodeIfPresent(String.self, forKey: .extractedText)
        pagePaths = try c.decodeIfPresent([String].self, forKey: .pagePaths) ?? []
        radarDismissedUntil = try c.decodeIfPresent(Date.self, forKey: .radarDismissedUntil)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        uploadedBy = try c.decodeIfPresent(String.self, forKey: .uploadedBy) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        processingState = try c.decodeIfPresent(DocumentProcessingState.self, forKey: .processingState) ?? .pending
    }
}
