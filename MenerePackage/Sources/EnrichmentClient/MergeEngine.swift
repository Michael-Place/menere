import Foundation
import WineDomain

// MARK: - Source contribution

/// One source's *proposed* field values for a wine. Every field is optional: a source only fills what
/// it actually found. The merge engine combines an ordered list of these into the final `Wine`,
/// recording per-field `Provenance`. This is the unit the merge engine reasons about — keep it pure
/// and free of any networking so it's trivially testable.
public struct SourceContribution: Sendable, Equatable {
    public var fieldSource: FieldSource
    public var confidence: Double

    // Identity / structured facts
    public var producer: String?
    public var name: String?
    public var vintage: Int?
    public var region: Region?
    public var grapes: [String]?
    public var type: WineType?
    public var abv: Double?

    // Enrichment narrative
    public var summary: String?
    public var drinkingWindow: String?
    public var producerNote: String?
    public var foodPairings: [String]?

    public init(
        fieldSource: FieldSource,
        confidence: Double,
        producer: String? = nil,
        name: String? = nil,
        vintage: Int? = nil,
        region: Region? = nil,
        grapes: [String]? = nil,
        type: WineType? = nil,
        abv: Double? = nil,
        summary: String? = nil,
        drinkingWindow: String? = nil,
        producerNote: String? = nil,
        foodPairings: [String]? = nil
    ) {
        self.fieldSource = fieldSource
        self.confidence = confidence
        self.producer = producer
        self.name = name
        self.vintage = vintage
        self.region = region
        self.grapes = grapes
        self.type = type
        self.abv = abv
        self.summary = summary
        self.drinkingWindow = drinkingWindow
        self.producerNote = producerNote
        self.foodPairings = foodPairings
    }

    /// True when this contribution carries no usable proposed field — nothing to merge.
    public var isEmpty: Bool {
        producer == nil && name == nil && vintage == nil && region == nil && grapes == nil
            && type == nil && abv == nil && summary == nil && drinkingWindow == nil
            && producerNote == nil && foodPairings == nil
    }
}

// MARK: - Provenance authority

/// Authority ranking for source override decisions. Higher wins. Encoded as an explicit function so
/// Phase 3/4 sources (already present in `FieldSource`) slot in without touching the merge logic.
///
/// `user` > authoritative { openFoodFacts, ttbCola, wikidata, kroger } (equal tier) > `ocr` > `llm`.
func authorityRank(_ source: FieldSource) -> Int {
    switch source {
    case .user: return 100
    case .openFoodFacts, .ttbCola, .wikidata, .kroger: return 50
    case .ocr: return 20
    case .llm: return 10
    }
}

/// Authoritative tier = the open-data / retail sources we trust for hard facts. Ties between them are
/// broken by confidence.
func isAuthoritative(_ source: FieldSource) -> Bool {
    authorityRank(source) == 50
}

// MARK: - Field keys

/// Provenance map keys — must match the `Wine`/`Enrichment` property names exactly so the UI can look
/// up "where did this field come from" by name.
enum FieldKey {
    static let producer = "producer"
    static let name = "name"
    static let vintage = "vintage"
    static let region = "region"
    static let grapes = "grapes"
    static let type = "type"
    static let abv = "abv"
    static let summary = "summary"
    static let drinkingWindow = "drinkingWindow"
    static let foodPairings = "foodPairings"
    static let producerNote = "producerNote"
}

// MARK: - Merge engine

/// Pure provenance-merge. Takes a base `Wine` (already carrying the scan's OCR fields) plus an ordered
/// list of source contributions and produces the enriched `Wine` with a populated
/// `enrichment.provenance` map.
///
/// Rules (enforced exactly):
/// - Authority: `user` > authoritative tier (tie-break by confidence) > `ocr` > `llm`.
/// - The incoming `Wine`'s populated scan fields (producer/name/vintage/region/grapes) are seeded with
///   an `ocr` baseline so authoritative sources can be *shown* to override them.
/// - A field is written only if the incoming source outranks the recorded provenance, or that field is
///   currently empty/unset; on an authoritative tie, higher confidence wins; `user` is never overwritten.
/// - Hard facts (`abv`) may only come from authoritative sources, never `llm`.
/// - `WineType.other` counts as empty, so an authoritative type upgrades it.
public func mergeEnrichment(
    base: Wine,
    contributions: [SourceContribution],
    ocrBaselineConfidence: Double = 1.0,
    now: Date = Date()
) -> Wine {
    var wine = base
    var enrichment = base.enrichment ?? Enrichment()
    var provenance = enrichment.provenance

    // 1) Seed an `ocr` baseline for scan fields already present on the incoming wine. These came off
    //    the label, so authoritative sources should be able to override (and be shown overriding) them.
    func seed(_ key: String, present: Bool) {
        guard present, provenance[key] == nil else { return }
        provenance[key] = Provenance(source: .ocr, confidence: ocrBaselineConfidence, fetchedAt: now)
    }
    seed(FieldKey.producer, present: !isStringEmpty(wine.producer))
    seed(FieldKey.name, present: !isOptionalStringEmpty(wine.name))
    seed(FieldKey.vintage, present: wine.vintage != nil)
    seed(FieldKey.region, present: !isRegionEmpty(wine.region))
    seed(FieldKey.grapes, present: !wine.grapes.isEmpty)

    // 2) Apply each contribution in order.
    for contribution in contributions {
        let source = contribution.fieldSource
        let confidence = contribution.confidence

        // Decide + write a single field. `currentlyEmpty` lets `.other`/nil/"" be upgraded freely.
        func apply(
            _ key: String,
            proposed: Bool,           // does this contribution propose the field at all?
            currentlyEmpty: Bool,
            hardFact: Bool = false,
            write: () -> Void
        ) {
            guard proposed else { return }
            // Hard facts may only come from authoritative sources (never llm/ocr).
            if hardFact, !isAuthoritative(source) { return }

            if let existing = provenance[key] {
                // Never overwrite a user-entered field.
                if existing.source == .user { return }
                if !currentlyEmpty {
                    let newRank = authorityRank(source)
                    let oldRank = authorityRank(existing.source)
                    if newRank < oldRank { return }
                    if newRank == oldRank {
                        // Same tier: only a strictly higher confidence authoritative source wins.
                        guard isAuthoritative(source), confidence > existing.confidence else { return }
                    }
                }
                // currentlyEmpty == true falls through to write (fill the gap).
            }
            write()
            provenance[key] = Provenance(source: source, confidence: confidence, fetchedAt: now)
        }

        apply(FieldKey.producer, proposed: contribution.producer != nil,
              currentlyEmpty: isStringEmpty(wine.producer)) {
            wine.producer = contribution.producer!
        }
        apply(FieldKey.name, proposed: contribution.name != nil,
              currentlyEmpty: isOptionalStringEmpty(wine.name)) {
            wine.name = contribution.name
        }
        apply(FieldKey.vintage, proposed: contribution.vintage != nil,
              currentlyEmpty: wine.vintage == nil) {
            wine.vintage = contribution.vintage
        }
        apply(FieldKey.region, proposed: contribution.region != nil,
              currentlyEmpty: isRegionEmpty(wine.region)) {
            wine.region = contribution.region
        }
        apply(FieldKey.grapes, proposed: contribution.grapes != nil,
              currentlyEmpty: wine.grapes.isEmpty) {
            wine.grapes = contribution.grapes ?? []
        }
        apply(FieldKey.type, proposed: contribution.type != nil,
              currentlyEmpty: wine.type == .other) {
            wine.type = contribution.type ?? .other
        }
        apply(FieldKey.abv, proposed: contribution.abv != nil,
              currentlyEmpty: wine.abv == nil, hardFact: true) {
            wine.abv = contribution.abv
        }

        apply(FieldKey.summary, proposed: contribution.summary != nil,
              currentlyEmpty: isOptionalStringEmpty(enrichment.summary)) {
            enrichment.summary = contribution.summary
        }
        apply(FieldKey.drinkingWindow, proposed: contribution.drinkingWindow != nil,
              currentlyEmpty: isOptionalStringEmpty(enrichment.drinkingWindow)) {
            enrichment.drinkingWindow = contribution.drinkingWindow
        }
        apply(FieldKey.producerNote, proposed: contribution.producerNote != nil,
              currentlyEmpty: isOptionalStringEmpty(enrichment.producerNote)) {
            enrichment.producerNote = contribution.producerNote
        }
        apply(FieldKey.foodPairings, proposed: contribution.foodPairings != nil,
              currentlyEmpty: enrichment.foodPairings.isEmpty) {
            enrichment.foodPairings = contribution.foodPairings ?? []
        }
    }

    enrichment.provenance = provenance
    wine.enrichment = enrichment
    return wine
}

// MARK: - Emptiness helpers

private func isStringEmpty(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func isOptionalStringEmpty(_ value: String?) -> Bool {
    guard let value else { return true }
    return isStringEmpty(value)
}

private func isRegionEmpty(_ region: Region?) -> Bool {
    guard let region else { return true }
    return isOptionalStringEmpty(region.country)
        && isOptionalStringEmpty(region.region)
        && isOptionalStringEmpty(region.subregion)
        && isOptionalStringEmpty(region.appellation)
}
