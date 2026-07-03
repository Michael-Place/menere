import FamilyDomain
import Foundation
import XCTest

/// Decode-safety for the two P2.1 fields. The binding decision: a `FamilyEvent` written WITHOUT a
/// `source` (legacy events + the email→events Cloud Function) must resolve to `.manual` so it pushes
/// to Apple Calendar.
final class FamilyEventDecodeTests: XCTestCase {
    private func decode(_ json: [String: Any]) throws -> FamilyEvent {
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(FamilyEvent.self, from: data)
    }

    private let baseStart = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970

    func testNilSourceResolvesToManual() throws {
        let event = try decode([
            "id": "e1", "title": "School play", "startDate": baseStart,
            "isAllDay": false, "recurrence": "none", "assigneeIDs": [],
            "createdAt": baseStart, "updatedAt": baseStart,
        ])
        XCTAssertNil(event.source)
        XCTAssertEqual(event.resolvedSource, .manual, "no source → manual → pushes to Apple")
        XCTAssertNil(event.eventKitIdentifier)
    }

    func testCalendarImportSourceDecodes() throws {
        let event = try decode([
            "id": "e2", "title": "Dentist", "startDate": baseStart,
            "isAllDay": false, "recurrence": "none", "assigneeIDs": [],
            "createdAt": baseStart, "updatedAt": baseStart,
            "source": "calendar_import", "eventKitIdentifier": "EK-123#2023-11-14T...",
        ])
        XCTAssertEqual(event.source, .calendarImport)
        XCTAssertEqual(event.resolvedSource, .calendarImport)
        XCTAssertEqual(event.eventKitIdentifier, "EK-123#2023-11-14T...")
    }

    func testExplicitEmailSourceDecodes() throws {
        let event = try decode([
            "id": "e3", "title": "PTA meeting", "startDate": baseStart,
            "source": "email",
        ])
        XCTAssertEqual(event.source, .email)
        XCTAssertEqual(event.resolvedSource, .email)
    }

    func testRoundTripPreservesFields() throws {
        let original = FamilyEvent(
            id: "e4", title: "Trash night", startDate: Date(timeIntervalSince1970: 1_700_000_000),
            recurrence: .weekly, eventKitIdentifier: "EK-9#x", source: .manual
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FamilyEvent.self, from: data)
        XCTAssertEqual(decoded.eventKitIdentifier, "EK-9#x")
        XCTAssertEqual(decoded.source, .manual)
        XCTAssertEqual(decoded.recurrence, .weekly)
    }
}
