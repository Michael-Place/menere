import XCTest
import WineDomain
@testable import IdentifyClient

/// Pure-function tests for `wineCandidate(fromIdentifyResponse:)` — the mapping from the
/// `identifyLabel` Cloud Function callable payload into a `WineCandidate`. No network, deterministic.
///
/// Note: `WineCandidate` carries no `type` field, so the response `type` is parsed/validated by the
/// mapper but cannot be observed on the result; these tests feed the various `type` values to confirm
/// the mapper handles them while asserting the fields that ARE stored.
final class IdentifyResponseMappingTests: XCTestCase {

    // 1. Full response → every field mapped.
    func testFullResponseMapsAllFields() {
        let dict: [String: Any] = [
            "producer": "Château Margaux",
            "name": "Grand Vin",
            "vintage": 2015,
            "region": [
                "country": "France",
                "region": "Bordeaux",
                "subregion": "Médoc",
                "appellation": "Margaux",
            ],
            "grapes": ["Cabernet Sauvignon", "Merlot"],
            "type": "red",
            "confidence": 0.92,
        ]

        let c = wineCandidate(fromIdentifyResponse: dict)

        XCTAssertEqual(c.producer, "Château Margaux")
        XCTAssertEqual(c.name, "Grand Vin")
        XCTAssertEqual(c.vintage, 2015)
        XCTAssertEqual(c.region?.country, "France")
        XCTAssertEqual(c.region?.region, "Bordeaux")
        XCTAssertEqual(c.region?.subregion, "Médoc")
        XCTAssertEqual(c.region?.appellation, "Margaux")
        XCTAssertEqual(c.grapes, ["Cabernet Sauvignon", "Merlot"])
        XCTAssertEqual(c.confidence, 0.92)
        XCTAssertEqual(c.source, .label)
        XCTAssertEqual(c.rawText, [])
        XCTAssertNil(c.barcode)
    }

    // 2a. Explicit JSON nulls (NSNull) → optionals nil, defaults applied.
    func testNullValuesYieldNilAndDefaults() {
        let dict: [String: Any] = [
            "producer": NSNull(),
            "name": NSNull(),
            "vintage": NSNull(),
            "region": [
                "country": NSNull(),
                "region": NSNull(),
                "subregion": NSNull(),
                "appellation": NSNull(),
            ],
            "grapes": NSNull(),
            "type": NSNull(),
            "confidence": NSNull(),
        ]

        let c = wineCandidate(fromIdentifyResponse: dict)

        XCTAssertNil(c.producer)
        XCTAssertNil(c.name)
        XCTAssertNil(c.vintage)
        XCTAssertNil(c.region)
        XCTAssertEqual(c.grapes, [])
        XCTAssertEqual(c.confidence, 0.9)   // default
        XCTAssertEqual(c.source, .label)
        XCTAssertEqual(c.rawText, [])
    }

    // 2b. Entirely missing keys → same nil / default behavior.
    func testMissingKeysYieldNilAndDefaults() {
        let dict: [String: Any] = [:]

        let c = wineCandidate(fromIdentifyResponse: dict)

        XCTAssertNil(c.producer)
        XCTAssertNil(c.name)
        XCTAssertNil(c.vintage)
        XCTAssertNil(c.region)
        XCTAssertEqual(c.grapes, [])
        XCTAssertEqual(c.confidence, 0.9)
        XCTAssertEqual(c.source, .label)
    }

    // 3. Region with only `appellation` present → region != nil with only appellation set.
    func testPartialRegionKeepsOnlyPresentSubfields() {
        let dict: [String: Any] = [
            "region": [
                "country": NSNull(),
                "region": "",
                "appellation": "Chablis",
            ],
        ]

        let c = wineCandidate(fromIdentifyResponse: dict)

        XCTAssertNotNil(c.region)
        XCTAssertNil(c.region?.country)
        XCTAssertNil(c.region?.region)
        XCTAssertNil(c.region?.subregion)
        XCTAssertEqual(c.region?.appellation, "Chablis")
    }

    // 4. type "unknown" / empty strings → empty/whitespace strings dropped; mapper still succeeds.
    func testUnknownTypeAndBlankStringsDropped() {
        let dict: [String: Any] = [
            "producer": "   ",       // whitespace only → nil
            "name": "",              // empty → nil
            "grapes": ["", "  ", "Syrah"],
            "type": "unknown",
            "confidence": 0.5,
        ]

        let c = wineCandidate(fromIdentifyResponse: dict)

        XCTAssertNil(c.producer)
        XCTAssertNil(c.name)
        XCTAssertEqual(c.grapes, ["Syrah"])
        XCTAssertEqual(c.confidence, 0.5)
    }

    // 5. vintage + confidence arriving as NSNumber (as FirebaseFunctions may decode JSON numbers).
    func testNumericFieldsAsNSNumber() {
        let dict: [String: Any] = [
            "vintage": NSNumber(value: 2019),
            "confidence": NSNumber(value: 0.77),
        ]

        let c = wineCandidate(fromIdentifyResponse: dict)

        XCTAssertEqual(c.vintage, 2019)
        XCTAssertEqual(c.confidence, 0.77)
    }
}
