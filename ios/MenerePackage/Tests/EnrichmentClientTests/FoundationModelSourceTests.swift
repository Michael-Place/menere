// Weak-linked like the source it tests, so the test bundle never strong-links iOS 27-only symbols.
@_weakLinked import FoundationModels
import WineDomain
import XCTest

@testable import EnrichmentClient

/// Offline tests for the on-device AI gap-fill source. The pure tests (gap detection, output masking,
/// merge interaction) carry the contract; the single live test is `XCTSkip`-gated on model availability
/// (the Foundation Models model is typically NOT provisioned on the simulator, so it returns nil).
final class FoundationModelSourceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scannedBase() -> Wine {
        Wine(producer: "Emiliana", name: "Natura", vintage: 2023, grapes: ["Carmenère"], type: .other)
    }

    // MARK: - Gap detection

    /// A descriptive field already filled by an authoritative source must NOT be targeted; only the
    /// genuinely empty ones are.
    func testGapDetectionTargetsOnlyEmptyDescriptiveFields() {
        // Authoritative pass fills `summary` (and `type`); the other three narrative fields stay empty.
        let authoritative = SourceContribution(
            fieldSource: .openFoodFacts, confidence: 0.6, type: .red, summary: "A Chilean Carmenère."
        )
        let wineAfterAuthoritative = mergeEnrichment(base: scannedBase(), contributions: [authoritative], now: now)

        let gaps = FoundationModelSource.emptyDescriptiveFields(of: wineAfterAuthoritative)

        XCTAssertFalse(gaps.contains(.summary), "summary was filled authoritatively — not a gap")
        XCTAssertEqual(gaps, [.drinkingWindow, .foodPairings, .producerNote])
    }

    /// When every descriptive field is filled, there are no gaps (so the second pass is skipped entirely
    /// and `enrich` returns the post-authoritative wine unchanged).
    func testNoGapsWhenAllDescriptiveFieldsFilled() {
        var wine = scannedBase()
        wine.enrichment = Enrichment(
            summary: "x", drinkingWindow: "Drink now", foodPairings: ["Lamb"], producerNote: "y"
        )
        XCTAssertTrue(FoundationModelSource.emptyDescriptiveFields(of: wine).isEmpty)
    }

    // MARK: - Output masking (llm carries only descriptive fields)

    /// The contribution carries ONLY the requested descriptive fields and is always `.llm`/conf 0.4 —
    /// never identity or hard facts (the draft structurally has none).
    func testContributionCarriesOnlyRequestedDescriptiveFields() {
        let draft = WineEnrichmentDraft(
            summary: "A bright, herbal red.",
            drinkingWindow: "Drink now through 2028",
            foodPairings: ["Grilled beef", "Mushroom risotto"],
            producerNote: "Emiliana farms organically in Chile."
        )

        let contribution = try! XCTUnwrap(
            FoundationModelSource.contribution(from: draft, fields: [.summary, .producerNote])
        )

        XCTAssertEqual(contribution.fieldSource, .llm)
        XCTAssertEqual(contribution.confidence, 0.4)
        // Requested fields landed.
        XCTAssertEqual(contribution.summary, "A bright, herbal red.")
        XCTAssertEqual(contribution.producerNote, "Emiliana farms organically in Chile.")
        // Un-requested descriptive fields are masked out even though the draft set them.
        XCTAssertNil(contribution.drinkingWindow)
        XCTAssertNil(contribution.foodPairings)
        // Identity / hard facts can never be carried by the llm source.
        XCTAssertNil(contribution.producer)
        XCTAssertNil(contribution.name)
        XCTAssertNil(contribution.vintage)
        XCTAssertNil(contribution.region)
        XCTAssertNil(contribution.grapes)
        XCTAssertNil(contribution.type)
        XCTAssertNil(contribution.abv)
    }

    /// `foodPairings` is capped and blank entries are dropped.
    func testFoodPairingsCleanedAndCapped() {
        let draft = WineEnrichmentDraft(
            summary: nil, drinkingWindow: nil,
            foodPairings: ["  Beef  ", "", "Lamb", "Pork", "Duck", "Fish", "Cheese"],
            producerNote: nil
        )
        let contribution = try! XCTUnwrap(FoundationModelSource.contribution(from: draft, fields: [.foodPairings]))
        XCTAssertEqual(contribution.foodPairings, ["Beef", "Lamb", "Pork", "Duck", "Fish"])
    }

    /// Nothing usable (blank draft) ⇒ no contribution at all.
    func testNoContributionWhenDraftEmpty() {
        let draft = WineEnrichmentDraft(summary: "   ", drinkingWindow: nil, foodPairings: [], producerNote: "")
        XCTAssertNil(FoundationModelSource.contribution(from: draft, fields: Set(DescriptiveField.allCases)))
    }

    // MARK: - Merge guarantees with an llm contribution present

    /// Even if an llm contribution *also* proposes a `type`/`abv`, the merge must keep the authoritative
    /// values and only let the llm land in the still-empty `summary`.
    func testMergeKeepsAuthoritativeFactsAndOnlyFillsEmptyDescriptive() {
        let authoritative = SourceContribution(fieldSource: .openFoodFacts, confidence: 0.6, type: .red, abv: 14.8)
        let wineAfterAuthoritative = mergeEnrichment(base: scannedBase(), contributions: [authoritative], now: now)

        // A deliberately over-reaching llm contribution (our source never produces type/abv, but prove
        // the merge is the backstop): it must not overwrite the authoritative facts.
        var llm = SourceContribution(fieldSource: .llm, confidence: 0.4, summary: "A juicy Chilean red.")
        llm.type = .white
        llm.abv = 99.0

        let final = mergeEnrichment(base: wineAfterAuthoritative, contributions: [llm], now: now)

        XCTAssertEqual(final.type, .red, "authoritative type survives the llm pass")
        XCTAssertEqual(final.abv, 14.8, "abv is a hard fact — llm can never set/overwrite it")
        XCTAssertEqual(final.enrichment?.summary, "A juicy Chilean red.", "llm fills the empty summary")
        XCTAssertEqual(final.enrichment?.provenance["summary"]?.source, .llm)
        XCTAssertEqual(final.enrichment?.provenance["type"]?.source, .openFoodFacts)
        XCTAssertEqual(final.enrichment?.provenance["abv"]?.source, .openFoodFacts)
    }

    // MARK: - Graceful fallback when the model is unavailable (simulator path)

    /// On the simulator the on-device model is typically not provisioned, so `fetch` must degrade to nil
    /// (leaving the post-authoritative wine untouched). If a model *is* available (real device), we
    /// instead assert the live output stays within contract; otherwise skip.
    func testFetchDegradesGracefullyWhenModelUnavailable() async throws {
        var wine = scannedBase()
        wine.type = .red  // some gaps remain: summary/drinkingWindow/foodPairings/producerNote
        XCTAssertFalse(FoundationModelSource.emptyDescriptiveFields(of: wine).isEmpty)

        let result = await FoundationModelSource.fetch(wine: wine)

        if modelAvailable {
            // Live generation ran — validate the contract rather than the nil path.
            guard let result else {
                throw XCTSkip("Model available but returned no usable text — nothing to assert.")
            }
            XCTAssertEqual(result.fieldSource, .llm)
            XCTAssertNil(result.type, "live llm output must not carry hard facts")
            XCTAssertNil(result.abv)
        } else {
            XCTAssertNil(result, "model unavailable on this host ⇒ graceful nil (expected on the simulator)")
        }
    }

    /// Whether the on-device system model is provisioned on this host.
    private var modelAvailable: Bool {
        guard case .available = SystemLanguageModel.default.availability else { return false }
        return true
    }
}
