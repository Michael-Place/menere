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
        docDate: Date? = nil,
        dueDate: Date? = nil,
        expiryDate: Date? = nil,
        amount: Double? = nil,
        vendor: String? = nil,
        summary: String? = nil,
        extractedText: String? = nil,
        pagePaths: [String] = [],
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
        self.docDate = docDate
        self.dueDate = dueDate
        self.expiryDate = expiryDate
        self.amount = amount
        self.vendor = vendor
        self.summary = summary
        self.extractedText = extractedText
        self.pagePaths = pagePaths
        self.uploadedBy = uploadedBy
        self.createdAt = createdAt
        self.processingState = processingState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        type = try c.decodeIfPresent(DocumentType.self, forKey: .type) ?? .other
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        linkedMemberIds = try c.decodeIfPresent([String].self, forKey: .linkedMemberIds) ?? []
        linkedPetIds = try c.decodeIfPresent([String].self, forKey: .linkedPetIds) ?? []
        docDate = try c.decodeIfPresent(Date.self, forKey: .docDate)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        expiryDate = try c.decodeIfPresent(Date.self, forKey: .expiryDate)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        extractedText = try c.decodeIfPresent(String.self, forKey: .extractedText)
        pagePaths = try c.decodeIfPresent([String].self, forKey: .pagePaths) ?? []
        uploadedBy = try c.decodeIfPresent(String.self, forKey: .uploadedBy) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        processingState = try c.decodeIfPresent(DocumentProcessingState.self, forKey: .processingState) ?? .pending
    }
}
