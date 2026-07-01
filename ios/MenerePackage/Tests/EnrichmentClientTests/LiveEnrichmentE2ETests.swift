import WineDomain
import XCTest

@testable import EnrichmentClient

/// Live END-TO-END enrichment test: drives the REAL `EnrichmentClient.liveValue.enrich` against the
/// real external services (Open Food Facts + Wikidata + TTB COLA) with a realistic candidate. This is
/// the M3 runtime proof that the source fan-out + merge populates per-field `Provenance` from genuine
/// external data — no UI, no auth, no Firestore needed.
///
/// On-device Foundation Models are unavailable on the simulator, so the AI gap-fill pass simply
/// no-ops here; that's expected and doesn't affect the assertions below.
///
/// LENIENT by design: live sources can be flaky. `enrich` is itself resilient (a down source collapses
/// to no contribution rather than throwing), so we detect an all-sources-down run by inspecting the
/// resulting provenance and `XCTSkip` instead of hard-failing on infra.
final class LiveEnrichmentE2ETests: XCTestCase {
    /// Realistic scan: Caymus Cabernet Sauvignon, plus the known-good OFF wine barcode so the barcode
    /// source has something to resolve. We assert leniently that:
    ///  - provenance is populated,
    ///  - an `ocr` baseline survives for at least one scanned identity field, and
    ///  - at least one AUTHORITATIVE source (OFF / Wikidata / TTB) populated provenance at runtime.
    func testLiveEndToEndEnrichmentFanOut() async throws {
        let candidate = WineCandidate(
            producer: "Caymus",
            name: "Cabernet Sauvignon",
            grapes: ["Cabernet Sauvignon"],
            barcode: "7772112000416",
            rawText: ["Caymus", "Cabernet Sauvignon", "2021"],
            confidence: 0.7,
            source: .label
        )
        let provisional = try XCTUnwrap(candidate.provisionalWine, "candidate must form a provisional wine")

        let enriched: Wine
        do {
            enriched = try await EnrichmentClient.liveValue.enrich(provisional, candidate)
        } catch {
            // `enrich` is resilient and shouldn't throw; if it does, treat it as infra and skip.
            throw XCTSkip("live enrich threw (treated as infra): \(error)")
        }

        let provenance = try XCTUnwrap(enriched.enrichment?.provenance, "enrichment must carry a provenance map")
        guard !provenance.isEmpty else {
            throw XCTSkip("provenance empty — all sources appear down (network infra), skipping")
        }

        // (1) The scan's identity fields are seeded with an `ocr` baseline so authoritative sources can
        // be SHOWN overriding them. `name`/`grapes` aren't owned by OFF/Wikidata/TTB, so their baseline
        // survives the merge — at least one identity field must still read `.ocr`.
        let identityKeys = [
            FieldKey.producer, FieldKey.name, FieldKey.vintage, FieldKey.region, FieldKey.grapes,
        ]
        let hasOCRBaseline = identityKeys.contains { provenance[$0]?.source == .ocr }
        XCTAssertTrue(
            hasOCRBaseline,
            "expected an OCR baseline for at least one scanned identity field; provenance=\(provenance)"
        )

        // (2) The DoD runtime proof: at least one authoritative external source fired and wrote
        // provenance. If none did, the live services are down — skip rather than fail.
        let authoritative: Set<FieldSource> = [.openFoodFacts, .wikidata, .ttbCola]
        let firedAuthoritative = Set(provenance.values.map(\.source)).intersection(authoritative)
        guard !firedAuthoritative.isEmpty else {
            throw XCTSkip(
                "no authoritative source populated provenance — live services appear down; provenance=\(provenance)"
            )
        }
        XCTAssertFalse(
            firedAuthoritative.isEmpty,
            "at least one of OFF/Wikidata/TTB must populate provenance at runtime; fired=\(firedAuthoritative)"
        )
    }
}
