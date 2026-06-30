import MenereUI
import SwiftUI
import WineDomain

// MARK: - Provenance field keys

/// The exact field-name keys the enrichment merge engine writes into
/// `Enrichment.provenance` (mirrors `MergeEngine`'s `Field` constants). The card reads provenance
/// for a fact by looking up the matching key.
public enum ProvenanceField {
    public static let producer = "producer"
    public static let name = "name"
    public static let vintage = "vintage"
    public static let region = "region"
    public static let grapes = "grapes"
    public static let type = "type"
    public static let abv = "abv"
    public static let summary = "summary"
    public static let drinkingWindow = "drinkingWindow"
    public static let foodPairings = "foodPairings"
    public static let producerNote = "producerNote"
}

// MARK: - Badge style (pure mapping)

/// A semantic tint for a provenance badge. Kept source-of-truth simple + `Equatable` so the
/// `FieldSource → badge` mapping is unit-testable without touching SwiftUI `Color`.
public enum ProvenanceTint: Equatable, Sendable {
    case verified    // authoritative open-data / regulatory source
    case aiEstimate  // AI-generated, treat as estimate
    case scanned     // read off the label by OCR
    case user        // entered/confirmed by the user
}

/// Pure description of a provenance badge: human label, SF Symbol, and semantic tint.
/// Derived purely from a `FieldSource`; the SwiftUI `Color` lives in the view layer.
public struct ProvenanceBadgeStyle: Equatable, Sendable {
    public let label: String
    public let systemImage: String
    public let tint: ProvenanceTint

    public init(label: String, systemImage: String, tint: ProvenanceTint) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
    }

    public static let verified = ProvenanceBadgeStyle(
        label: "Verified", systemImage: "checkmark.seal.fill", tint: .verified
    )
    public static let aiEstimate = ProvenanceBadgeStyle(
        label: "AI estimate", systemImage: "sparkles", tint: .aiEstimate
    )
    public static let scanned = ProvenanceBadgeStyle(
        label: "Scanned", systemImage: "text.viewfinder", tint: .scanned
    )
    public static let you = ProvenanceBadgeStyle(
        label: "You", systemImage: "person.fill", tint: .user
    )

    /// PURE mapping from a `FieldSource` to its badge style.
    /// Authoritative open-data / regulatory sources → "Verified"; `llm` → "AI estimate";
    /// `ocr` → "Scanned"; `user` → "You".
    public init(source: FieldSource) {
        switch source {
        case .openFoodFacts, .wikidata, .ttbCola, .kroger:
            self = .verified
        case .llm:
            self = .aiEstimate
        case .ocr:
            self = .scanned
        case .user:
            self = .you
        }
    }
}

public extension ProvenanceTint {
    /// View-layer color for the tint. Uses the Menere brand palette.
    var color: Color {
        switch self {
        case .verified: return .candleGold   // brand "verified = gold"
        case .aiEstimate: return .hold        // AI estimate = slate
        case .scanned: return .inkSoft        // read off the label
        case .user: return .wine              // user-confirmed = brand red
        }
    }
}

// MARK: - Wine provenance lookup (pure)

public extension Wine {
    /// The badge style for an enriched field, or `nil` when there is no provenance entry for that
    /// field (in which case the card shows no badge). `field` is one of `ProvenanceField`.
    func provenanceBadge(for field: String) -> ProvenanceBadgeStyle? {
        guard let source = enrichment?.provenance[field]?.source else { return nil }
        return ProvenanceBadgeStyle(source: source)
    }
}

// MARK: - Badge view

/// Small pill rendering a `ProvenanceBadgeStyle` (icon + label, tinted).
public struct ProvenanceBadge: View {
    let style: ProvenanceBadgeStyle

    /// One-shot trigger for the verified-seal bounce: flips on appear so the seal pops the moment a
    /// "Verified" field resolves into view. No-op for non-verified tints.
    @State private var appeared = false

    public init(style: ProvenanceBadgeStyle) {
        self.style = style
    }

    public var body: some View {
        Label(style.label, systemImage: style.systemImage)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(style.tint.color)
            .symbolEffect(.bounce, value: style.tint == .verified && appeared)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(style.tint.color.opacity(0.12))
            )
            .accessibilityLabel("Source: \(style.label)")
            .onAppear { appeared = true }
    }
}
