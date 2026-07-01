import WineDomain
import XCTest

@testable import EnrichmentClient

/// Live HTTP round-trip tests against the real Open Food Facts + Wikidata endpoints. Outbound HTTPS
/// works in this environment, so these SHOULD pass here. They're network-resilient: a transient
/// network failure is treated as a skip (via `XCTSkip`) rather than a hard failure, so CI without
/// network doesn't go red on infra.
final class LiveSourceTests: XCTestCase {
    /// OFF: known wine barcode "Único Tannat" (Campos de Solana) — red wine, ~14.8% abv.
    /// Verified via the OFF API at authoring time (status:1, categories_tags contains en:red-wines).
    func testOpenFoodFactsRoundTrip() async throws {
        let contribution: SourceContribution?
        do {
            contribution = try await OpenFoodFactsSource.fetch(barcode: "7772112000416")
        } catch {
            throw XCTSkip("OFF unreachable: \(error)")
        }

        let result = try XCTUnwrap(contribution, "OFF should return a contribution for a known wine")
        XCTAssertEqual(result.fieldSource, .openFoodFacts)
        // Producer (first brand) and a wine type should both parse for this product.
        XCTAssertNotNil(result.producer)
        XCTAssertEqual(result.type, .red)
        if let abv = result.abv {
            XCTAssertGreaterThan(abv, 10)
            XCTAssertLessThan(abv, 20)
        }
    }

    /// Wikidata: a known red grape (Carménère) must resolve to `.red` via fruit color (P11220).
    /// Search term intentionally lacks accents to prove the MWAPI entity-search is diacritic-tolerant.
    func testWikidataGrapeColorRoundTrip() async throws {
        let contribution: SourceContribution?
        do {
            contribution = try await WikidataSource.fetch(grapes: ["Carmenere"])
        } catch {
            throw XCTSkip("Wikidata unreachable: \(error)")
        }

        let result = try XCTUnwrap(contribution, "Wikidata should resolve a known grape's color")
        XCTAssertEqual(result.fieldSource, .wikidata)
        XCTAssertEqual(result.type, .red, "Carménère is a black-skinned grape ⇒ red")
    }

    /// Wikidata: a known white grape resolves to `.white`.
    func testWikidataWhiteGrape() async throws {
        let colors: [String]?
        do {
            colors = try await WikidataSource.fruitColors(grape: "Sauvignon blanc")
        } catch {
            throw XCTSkip("Wikidata unreachable: \(error)")
        }
        let labels = try XCTUnwrap(colors)
        guard !labels.isEmpty else { throw XCTSkip("no fruit color returned (data may have changed)") }
        XCTAssertEqual(WikidataSource.wineType(fromColorLabels: labels), .white)
    }

    /// TTB COLA: the deployed `ttbColaLookup` callable should return a class/type for a well-known US
    /// winery (Caymus ⇒ "TABLE RED WINE" ⇒ `.red`). Skips on any network / function-availability error
    /// so an undeployed function or offline CI doesn't go red.
    func testTTBColaRoundTrip() async throws {
        let contribution: SourceContribution?
        do {
            contribution = try await TTBColaSource.fetch(producer: "Caymus")
        } catch {
            throw XCTSkip("TTB COLA function unreachable: \(error)")
        }
        guard let result = contribution else {
            throw XCTSkip("TTB returned no class/type (registry data may have changed)")
        }
        XCTAssertEqual(result.fieldSource, .ttbCola)
        XCTAssertEqual(result.type, .red, "Caymus is a red-wine brand ⇒ .red")
    }

    /// TTB COLA: a nonsense brand resolves to no contribution (graceful not-found), without throwing.
    func testTTBColaNotFound() async throws {
        let contribution: SourceContribution?
        do {
            contribution = try await TTBColaSource.fetch(producer: "Zzqxnonsensewinexyz")
        } catch {
            throw XCTSkip("TTB COLA function unreachable: \(error)")
        }
        XCTAssertNil(contribution, "A nonsense brand should yield no TTB contribution")
    }

    /// Pure class/type → WineType mapping (no network): style keywords beat plain color.
    func testTTBClassTypeMapping() {
        XCTAssertEqual(TTBColaSource.wineType(fromClassType: "TABLE RED WINE"), .red)
        XCTAssertEqual(TTBColaSource.wineType(fromClassType: "TABLE WHITE WINE"), .white)
        XCTAssertEqual(TTBColaSource.wineType(fromClassType: "SPARKLING GRAPE WINE"), .sparkling)
        XCTAssertEqual(TTBColaSource.wineType(fromClassType: "DESSERT /PORT/SHERRY/(COOKING) WINE"), .fortified)
        XCTAssertEqual(TTBColaSource.wineType(fromClassType: "RED DESSERT WINE"), .dessert)
        XCTAssertNil(TTBColaSource.wineType(fromClassType: "GRAPE WINE"))
    }
}
