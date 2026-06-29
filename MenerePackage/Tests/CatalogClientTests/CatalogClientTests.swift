import Dependencies
import EnrichmentClient
import PersistenceClient
import WineDomain
import XCTest

@testable import CatalogClient

/// Resolve-logic tests with a fully mocked `PersistenceClient` — no Firebase, no network.
/// `\.catalog` is overridden with `.liveValue` so the real resolve logic runs against the
/// mocked persistence injected in the same scope.
final class CatalogClientResolveTests: XCTestCase {
    /// Cache HIT: returns the cached wine and never upserts.
    func testCacheHitReturnsCachedWithoutUpsert() async throws {
        let candidate = WineCandidate(producer: "Château Margaux", name: nil, vintage: 2015)
        let provisional = try XCTUnwrap(candidate.provisionalWine)
        let cached = Wine(
            producer: "Château Margaux",
            vintage: 2015,
            type: .red,
            abv: 13.5
        )

        let upsertCount = LockIsolated(0)

        let wine = try await withDependencies {
            $0.catalog = .liveValue
            $0.enrichment.enrich = { _, _ in XCTFail("cache hit must not enrich"); return cached }
            $0.persistence.wine = { key in
                XCTAssertEqual(key, provisional.id)
                return cached
            }
            $0.persistence.upsertWine = { _ in upsertCount.withValue { $0 += 1 } }
        } operation: {
            @Dependency(\.catalog) var catalog
            return try await catalog.resolve(candidate)
        }

        XCTAssertEqual(wine, cached)
        XCTAssertEqual(upsertCount.value, 0, "cache hit must not upsert")
    }

    /// Cache MISS: enriches the provisional wine, then upserts and returns the ENRICHED wine
    /// (not the bare provisional). Enrichment is stubbed so this stays offline + deterministic.
    func testCacheMissEnrichesThenUpsertsEnrichedWine() async throws {
        let candidate = WineCandidate(producer: "Domaine Leflaive", name: "Puligny-Montrachet", vintage: 2020)
        let provisional = try XCTUnwrap(candidate.provisionalWine)

        // What the (stubbed) enrichment step produces: same identity, upgraded type + abv + provenance.
        let enrichedStub: Wine = {
            var wine = provisional
            wine.type = .white
            wine.abv = 13.0
            wine.enrichment = Enrichment(provenance: [
                "type": Provenance(source: .wikidata, confidence: 0.7),
                "abv": Provenance(source: .openFoodFacts, confidence: 0.6),
            ])
            return wine
        }()

        let upserted = LockIsolated<Wine?>(nil)
        let enrichInput = LockIsolated<Wine?>(nil)

        let wine = try await withDependencies {
            $0.catalog = .liveValue
            $0.persistence.wine = { _ in nil }
            $0.persistence.upsertWine = { wine in upserted.setValue(wine) }
            $0.enrichment.enrich = { input, _ in
                enrichInput.setValue(input)
                return enrichedStub
            }
        } operation: {
            @Dependency(\.catalog) var catalog
            return try await catalog.resolve(candidate)
        }

        // The bare provisional is what gets handed to enrichment...
        assertSameIdentity(try XCTUnwrap(enrichInput.value), provisional)
        // ...and the ENRICHED wine is what's returned + persisted.
        XCTAssertEqual(wine, enrichedStub, "resolve must return the enriched wine")
        let upsertedWine = try XCTUnwrap(upserted.value, "cache miss must upsert")
        XCTAssertEqual(upsertedWine, enrichedStub, "must persist the enriched wine, not the bare provisional")
        XCTAssertEqual(upsertedWine.type, .white)
        XCTAssertEqual(upsertedWine.abv, 13.0)
        XCTAssertFalse(upsertedWine.enrichment?.provenance.isEmpty ?? true, "provenance must be populated")
    }

    /// Candidate with no producer can't form a canonical key — throws `insufficientIdentity`.
    func testNilProducerThrowsInsufficientIdentity() async throws {
        let candidate = WineCandidate(producer: nil, barcode: "0123456789012", source: .barcode)
        XCTAssertNil(candidate.provisionalWine)

        let upsertCount = LockIsolated(0)

        await withDependencies {
            $0.catalog = .liveValue
            $0.persistence.wine = { _ in XCTFail("must not look up"); return nil }
            $0.persistence.upsertWine = { _ in upsertCount.withValue { $0 += 1 } }
        } operation: {
            @Dependency(\.catalog) var catalog
            do {
                _ = try await catalog.resolve(candidate)
                XCTFail("expected insufficientIdentity")
            } catch CatalogError.insufficientIdentity {
                // expected
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(upsertCount.value, 0, "must not upsert without identity")
    }

    private func assertSameIdentity(
        _ lhs: Wine,
        _ rhs: Wine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.id, rhs.id, "canonical id", file: file, line: line)
        XCTAssertEqual(lhs.producer, rhs.producer, "producer", file: file, line: line)
        XCTAssertEqual(lhs.name, rhs.name, "name", file: file, line: line)
        XCTAssertEqual(lhs.vintage, rhs.vintage, "vintage", file: file, line: line)
    }
}
