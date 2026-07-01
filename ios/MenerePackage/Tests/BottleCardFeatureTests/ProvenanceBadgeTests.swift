import Testing
import WineDomain
@testable import BottleCardFeature

@Suite("Provenance badge mapping")
struct ProvenanceBadgeMappingTests {
    @Test("Authoritative sources map to Verified")
    func authoritativeSourcesAreVerified() {
        for source in [FieldSource.openFoodFacts, .wikidata, .ttbCola, .kroger] {
            let style = ProvenanceBadgeStyle(source: source)
            #expect(style == .verified)
            #expect(style.label == "Verified")
            #expect(style.tint == .verified)
            #expect(style.systemImage == "checkmark.seal.fill")
        }
    }

    @Test("LLM maps to AI estimate")
    func llmIsAIEstimate() {
        let style = ProvenanceBadgeStyle(source: .llm)
        #expect(style == .aiEstimate)
        #expect(style.label == "AI estimate")
        #expect(style.tint == .aiEstimate)
        #expect(style.systemImage == "sparkles")
    }

    @Test("OCR maps to Scanned")
    func ocrIsScanned() {
        let style = ProvenanceBadgeStyle(source: .ocr)
        #expect(style == .scanned)
        #expect(style.label == "Scanned")
        #expect(style.tint == .scanned)
        #expect(style.systemImage == "text.viewfinder")
    }

    @Test("User maps to You")
    func userIsYou() {
        let style = ProvenanceBadgeStyle(source: .user)
        #expect(style == .you)
        #expect(style.label == "You")
        #expect(style.tint == .user)
        #expect(style.systemImage == "person.fill")
    }
}

@Suite("Wine provenance lookup")
struct WineProvenanceLookupTests {
    private let wine = Wine(
        producer: "Test Estate",
        name: "Cuvée",
        vintage: 2019,
        enrichment: Enrichment(
            provenance: [
                ProvenanceField.region: Provenance(source: .wikidata),
                ProvenanceField.abv: Provenance(source: .ttbCola),
                ProvenanceField.summary: Provenance(source: .llm),
                ProvenanceField.grapes: Provenance(source: .ocr),
                ProvenanceField.foodPairings: Provenance(source: .user),
            ]
        )
    )

    @Test("Each enriched field resolves to the correct badge")
    func fieldsResolveToBadges() {
        #expect(wine.provenanceBadge(for: ProvenanceField.region) == .verified)
        #expect(wine.provenanceBadge(for: ProvenanceField.abv) == .verified)
        #expect(wine.provenanceBadge(for: ProvenanceField.summary) == .aiEstimate)
        #expect(wine.provenanceBadge(for: ProvenanceField.grapes) == .scanned)
        #expect(wine.provenanceBadge(for: ProvenanceField.foodPairings) == .you)
    }

    @Test("A field with no provenance entry returns nil (no badge)")
    func missingFieldReturnsNil() {
        #expect(wine.provenanceBadge(for: ProvenanceField.producerNote) == nil)
        #expect(wine.provenanceBadge(for: ProvenanceField.type) == nil)
    }

    @Test("A wine with no enrichment returns nil for every field")
    func noEnrichmentReturnsNil() {
        let bare = Wine(producer: "Bare", vintage: 2020)
        #expect(bare.provenanceBadge(for: ProvenanceField.region) == nil)
        #expect(bare.provenanceBadge(for: ProvenanceField.summary) == nil)
    }
}
