import FamilyDomain
import Foundation
import XCTest

/// P9.1 decode-safety for the new `CareItem.lightLevel` field: an older document (written before the
/// field existed) must decode with `lightLevel == nil` — never throw — and a round-trip preserves it.
final class CareItemLightLevelTests: XCTestCase {

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }
    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }

    /// A legacy plant doc that predates `lightLevel` decodes cleanly with `nil`.
    func testDecodesWithoutLightLevel() throws {
        let json = #"""
        {"id":"p1","kind":"plant","name":"Fern","iconSymbol":"leaf.fill","tasks":[],"createdAt":0}
        """#.data(using: .utf8)!
        let item = try makeDecoder().decode(CareItem.self, from: json)
        XCTAssertEqual(item.name, "Fern")
        XCTAssertNil(item.lightLevel)
    }

    /// Set → encode → decode preserves the light level.
    func testLightLevelRoundTrips() throws {
        let original = CareItem(kind: .plant, name: "Monty", lightLevel: "Bright indirect")
        let data = try makeEncoder().encode(original)
        let round = try makeDecoder().decode(CareItem.self, from: data)
        XCTAssertEqual(round.lightLevel, "Bright indirect")
    }

    func testLightLevelChoicesAreStable() {
        XCTAssertEqual(CareItem.lightLevelChoices, ["Low", "Medium", "Bright indirect", "Direct sun"])
    }
}
