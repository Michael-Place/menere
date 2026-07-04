import Foundation

/// A spending category. Small, opinionated taxonomy (per the P13 roadmap) — the family can re-file.
/// Carries a user-facing display name + an SF Symbol; tints are mapped in the UI layer (MoneyFeature)
/// to keep `FamilyDomain` UI-free, matching the `DocumentType` convention.
public enum ExpenseCategory: String, Codable, CaseIterable, Sendable, Equatable {
    case groceries
    case dining
    case kids
    case house
    case garden
    case pets
    case fun
    case other

    public var displayName: String {
        switch self {
        case .groceries: "Groceries"
        case .dining: "Dining"
        case .kids: "Kids"
        case .house: "House"
        case .garden: "Garden"
        case .pets: "Pets"
        case .fun: "Fun"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .groceries: "cart.fill"
        case .dining: "fork.knife"
        case .kids: "figure.and.child.holdinghands"
        case .house: "house.fill"
        case .garden: "leaf.fill"
        case .pets: "pawprint.fill"
        case .fun: "party.popper.fill"
        case .other: "tag.fill"
        }
    }

    /// Keyword → category map used to auto-suggest a category when promoting a Family-Brain receipt
    /// (P13 ingestion ladder, rung 1). Deliberately simple + deterministic: we lowercase the doc's
    /// signals (tags + vendor + title + type) and take the first category whose keywords appear.
    /// Order matters — more specific buckets (kids, garden, pets) are checked before broad ones.
    static let keywordMap: [(ExpenseCategory, [String])] = [
        (.kids, ["kindercare", "childcare", "daycare", "school", "tuition", "kid", "child", "preschool", "diaper"]),
        (.garden, ["garden", "plant", "nursery", "landscap", "soil", "mulch", "seed", "greenhouse"]),
        (.pets, ["vet", "veterinar", "pet", "dog", "cat", "kibble", "groomer"]),
        (.groceries, ["grocery", "groceries", "supermarket", "costco", "market", "trader joe", "whole foods", "safeway"]),
        (.dining, ["restaurant", "dining", "cafe", "coffee", "takeout", "bar & grill", "pizzeria", "diner"]),
        (.house, ["hardware", "home depot", "lowes", "repair", "plumb", "electric", "furnitur", "appliance", "utility", "utilities", "septic", "home maintenance", "hvac", "roof", "handyman"]),
        (.fun, ["movie", "cinema", "toy", "game", "entertainment", "concert", "museum", "amusement"]),
    ]

    /// Suggest a category from arbitrary text signals (tags, vendor, title, type). Falls back to
    /// `.other` when nothing matches. Pure + case-insensitive so it's trivially testable.
    public static func suggested(from signals: [String]) -> ExpenseCategory {
        let hay = signals.map { $0.lowercased() }.joined(separator: " ")
        for (category, keywords) in keywordMap {
            if keywords.contains(where: { hay.contains($0) }) { return category }
        }
        return .other
    }
}

/// How an expense entered the ledger. Mirrors the ingestion ladder — rungs 1+2 for now
/// (`receiptScan` = promoted from a Family-Brain document; `manual` = quick-add). Later rungs
/// (email, statement, bank sync) will add cases without churn.
public enum ExpenseSource: String, Codable, Sendable, Equatable {
    case receiptScan
    case manual
}

/// A single spend. Persisted at `households/{hid}/expenses/{id}`.
///
/// `documentId` links back to the Family-Brain `Document` it was promoted from (rung 1), which also
/// gates the "New from the Brain" inbox — a document with a linked expense no longer nags.
/// Decode-safe: hand-written / partial docs still resolve (amount is the only hard field).
public struct Expense: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var amount: Double
    public var vendor: String?
    public var category: ExpenseCategory
    public var date: Date
    /// The `HouseholdMember.id` (uid) who spent it, if attributed.
    public var memberId: String?
    public var source: ExpenseSource
    /// The Family-Brain `Document.id` this was promoted from (rung 1), if any.
    public var documentId: String?
    public var notes: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        amount: Double,
        vendor: String? = nil,
        category: ExpenseCategory = .other,
        date: Date = Date(),
        memberId: String? = nil,
        source: ExpenseSource = .manual,
        documentId: String? = nil,
        notes: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.amount = amount
        self.vendor = vendor
        self.category = category
        self.date = date
        self.memberId = memberId
        self.source = source
        self.documentId = documentId
        self.notes = notes
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)
        // `try?` on the enums keeps decoding forward-compatible: an unknown category/source string
        // (written by a newer client) degrades to a sensible default rather than failing the whole doc.
        category = (try? c.decodeIfPresent(ExpenseCategory.self, forKey: .category)) ?? .other
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        memberId = try c.decodeIfPresent(String.self, forKey: .memberId)
        source = (try? c.decodeIfPresent(ExpenseSource.self, forKey: .source)) ?? .manual
        documentId = try c.decodeIfPresent(String.self, forKey: .documentId)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Build an `Expense` by promoting a Family-Brain `Document` (P13 ingestion ladder, rung 1).
    /// Pulls `amount` / `vendor` / `docDate` straight off the extracted doc, auto-suggests a category
    /// from the doc's signals, links back via `documentId`, and stamps the source as `.receiptScan`.
    /// `docDate` is the printed date when known, otherwise `now`.
    // SEAM (P14): agent tools — log_expense builds an Expense the same way from a tool payload.
    public static func promoting(
        document doc: Document,
        id: String = UUID().uuidString,
        now: Date = Date()
    ) -> Expense {
        Expense(
            id: id,
            amount: doc.amount ?? 0,
            vendor: doc.vendor,
            category: doc.suggestedExpenseCategory,
            date: doc.docDate ?? now,
            memberId: nil,
            source: .receiptScan,
            documentId: doc.id,
            notes: nil,
            createdAt: now
        )
    }
}

public extension Document {
    /// The category we'd suggest if this document were promoted to an expense — from its tags,
    /// vendor, title, and type. Powers the one-tap "File it" in the Money inbox.
    var suggestedExpenseCategory: ExpenseCategory {
        ExpenseCategory.suggested(from: tags + [vendor ?? "", title, type.displayName])
    }
}

/// Optional per-household budgets, persisted at `households/{hid}/config/budgets` (an absent doc
/// simply means "no budgets set"). `limits` is keyed by `ExpenseCategory.rawValue`.
/// `dismissedDocumentIds` remembers Brain documents the family marked "Not an expense" so the inbox
/// stops nagging. Decode-safe: an empty `{}` doc still resolves.
public struct BudgetConfig: Codable, Equatable, Sendable {
    /// `ExpenseCategory.rawValue` → monthly limit (dollars).
    public var limits: [String: Double]
    /// Brain `Document.id`s dismissed from the "New from the Brain" inbox.
    public var dismissedDocumentIds: [String]

    public init(limits: [String: Double] = [:], dismissedDocumentIds: [String] = []) {
        self.limits = limits
        self.dismissedDocumentIds = dismissedDocumentIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limits = try c.decodeIfPresent([String: Double].self, forKey: .limits) ?? [:]
        dismissedDocumentIds = try c.decodeIfPresent([String].self, forKey: .dismissedDocumentIds) ?? []
    }

    /// The limit for a category, if one is set (and > 0).
    public func limit(for category: ExpenseCategory) -> Double? {
        guard let value = limits[category.rawValue], value > 0 else { return nil }
        return value
    }
}
