import WineDomain
import XCTest

@testable import EnrichmentClient

/// Pure, offline tests for the provenance-merge engine — the load-bearing deliverable. No networking.
final class MergeEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Base wine carrying scan fields (these become the `ocr` baseline).
    private func scannedBase() -> Wine {
        Wine(
            producer: "Campos de Solana",
            name: "Único Tannat",
            vintage: 2019,
            region: nil,
            grapes: ["Tannat"],
            type: .other
        )
    }

    // MARK: Authoritative overrides the ocr baseline

    func testAuthoritativeOverridesOcrBaseline() {
        let base = scannedBase()
        let contribution = SourceContribution(
            fieldSource: .openFoodFacts, confidence: 0.6, producer: "Bodega Real"
        )

        let merged = mergeEnrichment(base: base, contributions: [contribution], now: now)

        XCTAssertEqual(merged.producer, "Bodega Real")
        XCTAssertEqual(merged.enrichment?.provenance["producer"]?.source, .openFoodFacts)
    }

    // MARK: Empty field gets filled

    func testEmptyFieldGetsFilled() {
        let base = scannedBase()  // type == .other, abv == nil
        let contribution = SourceContribution(
            fieldSource: .openFoodFacts, confidence: 0.6, type: .red, abv: 14.8
        )

        let merged = mergeEnrichment(base: base, contributions: [contribution], now: now)

        XCTAssertEqual(merged.type, .red)
        XCTAssertEqual(merged.abv, 14.8)
        XCTAssertEqual(merged.enrichment?.provenance["type"]?.source, .openFoodFacts)
        XCTAssertEqual(merged.enrichment?.provenance["abv"]?.source, .openFoodFacts)
    }

    // MARK: .other type upgraded by authoritative type

    func testOtherTypeUpgradedByAuthoritative() {
        var base = scannedBase()
        base.type = .other
        // Pre-seed an ocr-provenanced .other (simulating the baseline) — .other must count as empty.
        let contribution = SourceContribution(fieldSource: .wikidata, confidence: 0.7, type: .red)

        let merged = mergeEnrichment(base: base, contributions: [contribution], now: now)

        XCTAssertEqual(merged.type, .red)
        XCTAssertEqual(merged.enrichment?.provenance["type"]?.source, .wikidata)
    }

    // MARK: user field is never overwritten

    func testUserFieldNeverOverwritten() {
        var base = scannedBase()
        base.producer = "User Producer"
        base.enrichment = Enrichment(provenance: [
            "producer": Provenance(source: .user, confidence: 1.0, fetchedAt: now),
        ])
        let contribution = SourceContribution(
            fieldSource: .openFoodFacts, confidence: 0.95, producer: "OFF Producer"
        )

        let merged = mergeEnrichment(base: base, contributions: [contribution], now: now)

        XCTAssertEqual(merged.producer, "User Producer", "user field must survive")
        XCTAssertEqual(merged.enrichment?.provenance["producer"]?.source, .user)
    }

    // MARK: abv rejected from llm, accepted from authoritative

    func testAbvRejectedFromLLM() {
        let base = scannedBase()
        let llm = SourceContribution(fieldSource: .llm, confidence: 0.99, abv: 99.0)

        let merged = mergeEnrichment(base: base, contributions: [llm], now: now)

        XCTAssertNil(merged.abv, "abv is a hard fact — never from llm")
        XCTAssertNil(merged.enrichment?.provenance["abv"])
    }

    func testAbvAcceptedFromAuthoritative() {
        let base = scannedBase()
        let off = SourceContribution(fieldSource: .openFoodFacts, confidence: 0.6, abv: 14.8)

        let merged = mergeEnrichment(base: base, contributions: [off], now: now)

        XCTAssertEqual(merged.abv, 14.8)
        XCTAssertEqual(merged.enrichment?.provenance["abv"]?.source, .openFoodFacts)
    }

    // MARK: equal authoritative tier broken by confidence

    func testEqualTierTieBrokenByConfidence() {
        let base = scannedBase()  // type == .other
        let lower = SourceContribution(fieldSource: .openFoodFacts, confidence: 0.6, type: .red)
        let higher = SourceContribution(fieldSource: .wikidata, confidence: 0.7, type: .white)

        // Apply lower first, then higher — higher confidence on equal tier must win.
        let merged = mergeEnrichment(base: base, contributions: [lower, higher], now: now)

        XCTAssertEqual(merged.type, .white)
        XCTAssertEqual(merged.enrichment?.provenance["type"]?.source, .wikidata)
        XCTAssertEqual(merged.enrichment?.provenance["type"]?.confidence, 0.7)
    }

    func testEqualTierLowerConfidenceDoesNotOverride() {
        let base = scannedBase()
        let higher = SourceContribution(fieldSource: .wikidata, confidence: 0.7, type: .white)
        let lower = SourceContribution(fieldSource: .openFoodFacts, confidence: 0.6, type: .red)

        // Higher first; the later lower-confidence authoritative source must NOT override it.
        let merged = mergeEnrichment(base: base, contributions: [higher, lower], now: now)

        XCTAssertEqual(merged.type, .white)
        XCTAssertEqual(merged.enrichment?.provenance["type"]?.source, .wikidata)
    }

    // MARK: provenance recorded per field with correct source

    func testProvenanceRecordedPerField() {
        let base = scannedBase()
        let off = SourceContribution(
            fieldSource: .openFoodFacts, confidence: 0.6, producer: "Bodega", abv: 14.0
        )
        let wikidata = SourceContribution(fieldSource: .wikidata, confidence: 0.7, type: .red)

        let merged = mergeEnrichment(base: base, contributions: [off, wikidata], now: now)
        let prov = try! XCTUnwrap(merged.enrichment?.provenance)

        XCTAssertEqual(prov["producer"]?.source, .openFoodFacts)
        XCTAssertEqual(prov["abv"]?.source, .openFoodFacts)
        XCTAssertEqual(prov["type"]?.source, .wikidata)
        // Scan fields that no source touched keep their ocr baseline.
        XCTAssertEqual(prov["name"]?.source, .ocr)
        XCTAssertEqual(prov["vintage"]?.source, .ocr)
        XCTAssertEqual(prov["grapes"]?.source, .ocr)
        // fetchedAt stamped with the injected clock.
        XCTAssertEqual(prov["type"]?.fetchedAt, now)
    }

    // MARK: ocr baseline only seeds present fields

    func testOcrBaselineOnlySeedsPresentFields() {
        let base = Wine(producer: "Solo Producer", type: .other)  // no name/vintage/region/grapes
        let merged = mergeEnrichment(base: base, contributions: [], now: now)
        let prov = merged.enrichment?.provenance ?? [:]

        XCTAssertEqual(prov["producer"]?.source, .ocr)
        XCTAssertNil(prov["name"], "absent scan fields are not seeded")
        XCTAssertNil(prov["vintage"])
        XCTAssertNil(prov["grapes"])
        XCTAssertNil(prov["type"], ".other is empty — not seeded")
    }
}
