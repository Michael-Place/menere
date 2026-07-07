import Foundation

/// The lifecycle stage of a family **initiative / project** (the pool build, Oliver's school hunt) —
/// a richer arc than the lightweight ``ProjectStatus`` used by `.project` FamilyLists. A big
/// undertaking starts as a `dreaming` idea, becomes `researching` (gathering imagery, contractors,
/// quotes), then `deciding`, `inProgress`, and finally `done`.
///
/// Named `ProjectPhase` (not `ProjectStatus`) on purpose: `ProjectStatus` already exists in this
/// module — a 3-case (planning/inProgress/done) enum wired into `ListItem.projectStatus` and the
/// honey-do project lists. This is a distinct, 5-stage arc for the standalone `Project` workspace.
///
/// Decode-safe on `Project.status`: a `nil`/unknown raw value renders under `.dreaming` via
/// `Project.effectivePhase` — see `Project.init(from:)`.
public enum ProjectPhase: String, Codable, CaseIterable, Sendable, Equatable {
    case dreaming
    case researching
    case deciding
    case inProgress
    case done

    public var displayName: String {
        switch self {
        case .dreaming: "Dreaming"
        case .researching: "Researching"
        case .deciding: "Deciding"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }

    public var icon: String {
        switch self {
        case .dreaming: "sparkles"
        case .researching: "magnifyingglass"
        case .deciding: "checklist"
        case .inProgress: "hammer.fill"
        case .done: "checkmark.seal.fill"
        }
    }

    /// Order the phases read in a picker / the workspace header (idea → finished).
    public var sortOrder: Int {
        switch self {
        case .dreaming: 0
        case .researching: 1
        case .deciding: 2
        case .inProgress: 3
        case .done: 4
        }
    }
}

/// A link the family gathers on a project (a contractor's site, a Pinterest board, a listing, a
/// quote PDF). Decode-safe Codable: older/partial docs still resolve.
public struct ProjectLink: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var url: String
    public var title: String

    public init(id: String = UUID().uuidString, url: String, title: String = "") {
        self.id = id
        self.url = url
        self.title = title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    }

    /// The best human label for the link: the given title, else the host, else the raw string.
    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let host = URL(string: url)?.host { return host }
        return url
    }

    /// A tappable `URL`, coercing a bare `example.com` to `https://example.com`.
    public var resolvedURL: URL? {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.contains("://") { return URL(string: raw) }
        return URL(string: "https://\(raw)")
    }
}

/// A **person the family is talking to** on a project — a pool contractor, a school's admissions
/// office, an architect. Rows show name + role/company; phone/email are tappable (`tel:`/`mailto:`),
/// and `linkedDocId` can pin the contact to one of the project's quote documents. Decode-safe
/// Codable so older/partial docs still resolve.
public struct ProjectContact: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// What they are to us — "Contractor", "Admissions", "Architect", "Realtor".
    public var role: String?
    public var company: String?
    public var phone: String?
    public var email: String?
    public var notes: String?
    /// Optional `Document.id` of the quote/brochure this contact is tied to (from the project's docs).
    public var linkedDocId: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        role: String? = nil,
        company: String? = nil,
        phone: String? = nil,
        email: String? = nil,
        notes: String? = nil,
        linkedDocId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.company = company
        self.phone = phone
        self.email = email
        self.notes = notes
        self.linkedDocId = linkedDocId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role)
        company = try c.decodeIfPresent(String.self, forKey: .company)
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        linkedDocId = try c.decodeIfPresent(String.self, forKey: .linkedDocId)
    }

    /// The best secondary line for a row: "Contractor · Blue Haven", role, company (else empty).
    public var subtitle: String {
        let r = role?.trimmingCharacters(in: .whitespacesAndNewlines)
        let co = company?.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = (r?.isEmpty == false) ? r : nil
        let company = (co?.isEmpty == false) ? co : nil
        switch (role, company) {
        case let (role?, company?): return "\(role) · \(company)"
        case let (role?, nil): return role
        case let (nil, company?): return company
        default: return ""
        }
    }

    /// A `tel:` URL for the phone, digits only (keeps a leading `+`), or nil.
    public var phoneURL: URL? {
        guard let phone, !phone.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        return URL(string: "tel:\(digits)")
    }

    /// A `mailto:` URL for the email, or nil.
    public var emailURL: URL? {
        guard let email else { return nil }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@") else { return nil }
        return URL(string: "mailto:\(trimmed)")
    }
}

/// One checklist item on a project ("Call three pool builders", "Tour Montessori open house").
public struct ProjectTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var isDone: Bool

    public init(id: String = UUID().uuidString, title: String, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isDone = isDone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
    }
}

/// A **family initiative workspace** — a rich gathering-place for one big undertaking (building a
/// pool, moving Oliver to a real school). PR1 of the Projects roadmap: the workspace MVP. A project
/// gathers an inspiration board (photos), linked Family-Brain documents (via `Document.projectIds`),
/// links, a task checklist, and free-form notes.
///
/// Persisted at `households/{hid}/projects/{id}`. Cover + board photos live in Storage under
/// `households/{hid}/projects/{id}/…` (paths recorded here). Every optional is decode-safe so the
/// schema can grow (contacts, budget, AI brief in later PRs) without breaking older docs.
public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Storage path of the hero/cover image, if set.
    public var coverImagePath: String?
    public var status: ProjectPhase
    /// An optional target / deadline the family is working toward (pool ready by summer).
    public var targetDate: Date?
    /// A one-line summary of what this project is.
    public var summary: String?
    public var createdAt: Date
    /// Gathered links (contractors, boards, listings, quotes).
    public var links: [ProjectLink]?
    /// The project's checklist.
    public var tasks: [ProjectTask]?
    /// Free-form notes, stored as portable **Markdown** (round-trips through ``RichNoteEditor``).
    public var notes: String?
    /// Storage paths of the inspiration-board photos, in order.
    public var photoPaths: [String]?
    /// The people the family is talking to on this project (contractors, admissions, realtors).
    /// PR3 — decode-safe optional so older projects still resolve.
    public var contacts: [ProjectContact]?
    /// An optional budget the family is working toward — compared against the gathered quotes in the
    /// workspace's Budget section. PR3 — decode-safe optional.
    public var budgetTarget: Double?

    public init(
        id: String = UUID().uuidString,
        name: String,
        coverImagePath: String? = nil,
        status: ProjectPhase = .dreaming,
        targetDate: Date? = nil,
        summary: String? = nil,
        createdAt: Date = Date(),
        links: [ProjectLink]? = nil,
        tasks: [ProjectTask]? = nil,
        notes: String? = nil,
        photoPaths: [String]? = nil,
        contacts: [ProjectContact]? = nil,
        budgetTarget: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.coverImagePath = coverImagePath
        self.status = status
        self.targetDate = targetDate
        self.summary = summary
        self.createdAt = createdAt
        self.links = links
        self.tasks = tasks
        self.notes = notes
        self.photoPaths = photoPaths
        self.contacts = contacts
        self.budgetTarget = budgetTarget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        coverImagePath = try c.decodeIfPresent(String.self, forKey: .coverImagePath)
        // Decode-safe status: unknown / missing raw value → `.dreaming`.
        status = (try? c.decodeIfPresent(ProjectPhase.self, forKey: .status)) ?? .dreaming
        targetDate = try c.decodeIfPresent(Date.self, forKey: .targetDate)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        links = try c.decodeIfPresent([ProjectLink].self, forKey: .links)
        tasks = try c.decodeIfPresent([ProjectTask].self, forKey: .tasks)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        photoPaths = try c.decodeIfPresent([String].self, forKey: .photoPaths)
        contacts = try c.decodeIfPresent([ProjectContact].self, forKey: .contacts)
        budgetTarget = try c.decodeIfPresent(Double.self, forKey: .budgetTarget)
    }

    /// The phase (kept as a computed twin of the decode fallback for call-site symmetry).
    public var effectivePhase: ProjectPhase { status }

    /// Progress across the task checklist as a 0…1 fraction (nil when there are no tasks).
    public var taskProgress: Double? {
        guard let tasks, !tasks.isEmpty else { return nil }
        return Double(tasks.filter(\.isDone).count) / Double(tasks.count)
    }

    /// A short "3 of 5 done" hint for the card, or nil when there are no tasks.
    public var taskSummary: String? {
        guard let tasks, !tasks.isEmpty else { return nil }
        return "\(tasks.filter(\.isDone).count) of \(tasks.count) done"
    }
}
