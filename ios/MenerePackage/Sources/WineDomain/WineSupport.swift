import Foundation

public enum WineType: String, Codable, Equatable, Sendable, CaseIterable {
    case red, white, rose, sparkling, dessert, fortified, other
}

/// Region hierarchy, coarse → fine. All optional; fill what's known.
public struct Region: Codable, Equatable, Sendable {
    public var country: String?
    public var region: String?
    public var subregion: String?
    public var appellation: String?

    public init(
        country: String? = nil,
        region: String? = nil,
        subregion: String? = nil,
        appellation: String? = nil
    ) {
        self.country = country
        self.region = region
        self.subregion = subregion
        self.appellation = appellation
    }
}

// MARK: - Enrichment + provenance

/// Where a given enriched field came from. Authoritative sources outrank `llm`.
public enum FieldSource: String, Codable, Equatable, Sendable {
    case user           // entered/confirmed by the user
    case ocr            // read off the label by on-device OCR
    case llm            // AI-generated (treat as estimate; never for hard facts like scores)
    case openFoodFacts
    case ttbCola
    case wikidata
    case kroger
}

public struct Provenance: Codable, Equatable, Sendable {
    public var source: FieldSource
    public var confidence: Double   // 0...1
    public var fetchedAt: Date

    public init(source: FieldSource, confidence: Double = 1.0, fetchedAt: Date = Date()) {
        self.source = source
        self.confidence = confidence
        self.fetchedAt = fetchedAt
    }
}

/// Facts gathered on-the-fly about a wine. `provenance` maps a field name → where it came from,
/// so the UI can show "verified" vs "AI estimate" and we can upgrade fields later.
public struct Enrichment: Codable, Equatable, Sendable {
    public var summary: String?
    public var drinkingWindow: String?
    public var foodPairings: [String]
    public var producerNote: String?
    public var provenance: [String: Provenance]

    public init(
        summary: String? = nil,
        drinkingWindow: String? = nil,
        foodPairings: [String] = [],
        producerNote: String? = nil,
        provenance: [String: Provenance] = [:]
    ) {
        self.summary = summary
        self.drinkingWindow = drinkingWindow
        self.foodPairings = foodPairings
        self.producerNote = producerNote
        self.provenance = provenance
    }
}

// MARK: - Tasting note

/// Structured tasting note, loosely modeled on the WSET SAT sections (Appearance / Nose / Palate /
/// Conclusions). Kept as free text for now — the verbatim WSET enum vocabularies are trademarked and
/// require WSET's (usually free) written permission before reproducing them in a shipped app.
public struct SATNote: Codable, Equatable, Sendable {
    public var appearance: String?
    public var nose: String?
    public var palate: String?
    public var conclusions: String?

    public init(
        appearance: String? = nil,
        nose: String? = nil,
        palate: String? = nil,
        conclusions: String? = nil
    ) {
        self.appearance = appearance
        self.nose = nose
        self.palate = palate
        self.conclusions = conclusions
    }
}
