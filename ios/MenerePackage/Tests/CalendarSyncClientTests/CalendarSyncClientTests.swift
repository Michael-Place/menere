import EventKit
import FamilyDomain
import Foundation
import XCTest

@testable import CalendarSyncClient

final class CalendarSyncClientTests: XCTestCase {

    // MARK: RecurrenceOption → EventKit mapping (Fambo flaw #3 fix)

    func testRecurrenceMappingFrequencyAndInterval() {
        XCTAssertNil(RecurrenceOption.none.ekFrequencyAndInterval)

        let daily = RecurrenceOption.daily.ekFrequencyAndInterval
        XCTAssertEqual(daily?.frequency, .daily)
        XCTAssertEqual(daily?.interval, 1)

        let weekly = RecurrenceOption.weekly.ekFrequencyAndInterval
        XCTAssertEqual(weekly?.frequency, .weekly)
        XCTAssertEqual(weekly?.interval, 1)

        // biweekly is the interesting one: weekly frequency with interval 2.
        let biweekly = RecurrenceOption.biweekly.ekFrequencyAndInterval
        XCTAssertEqual(biweekly?.frequency, .weekly)
        XCTAssertEqual(biweekly?.interval, 2)

        let monthly = RecurrenceOption.monthly.ekFrequencyAndInterval
        XCTAssertEqual(monthly?.frequency, .monthly)
        XCTAssertEqual(monthly?.interval, 1)

        let yearly = RecurrenceOption.yearly.ekFrequencyAndInterval
        XCTAssertEqual(yearly?.frequency, .yearly)
        XCTAssertEqual(yearly?.interval, 1)
    }

    func testRecurrenceRuleBuildsForEachOption() {
        XCTAssertNil(RecurrenceOption.none.ekRecurrenceRule)
        for option in [RecurrenceOption.daily, .weekly, .biweekly, .monthly, .yearly] {
            let rule = option.ekRecurrenceRule
            XCTAssertNotNil(rule, "\(option) should build a rule")
            XCTAssertEqual(rule?.frequency, option.ekFrequencyAndInterval?.frequency)
            XCTAssertEqual(rule?.interval, option.ekFrequencyAndInterval?.interval)
        }
    }

    // MARK: Dedup key (Fambo flaw #1 fix — per-occurrence uniqueness)

    func testDedupKeyIsStableForSameOccurrence() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let a = CalendarSyncKey.dedupKey(eventIdentifier: "EK-123", occurrenceStart: start)
        let b = CalendarSyncKey.dedupKey(eventIdentifier: "EK-123", occurrenceStart: start)
        XCTAssertEqual(a, b, "same event + same start → identical key (stable across syncs)")
        XCTAssertTrue(a.hasPrefix("EK-123#"))
    }

    func testDedupKeyDiffersPerOccurrenceOfSameSeries() {
        // A recurring EK series: same eventIdentifier, different occurrence starts → distinct keys.
        let week1 = Date(timeIntervalSince1970: 1_700_000_000)
        let week2 = week1.addingTimeInterval(7 * 24 * 3600)
        let week3 = week2.addingTimeInterval(7 * 24 * 3600)
        let keys = Set([
            CalendarSyncKey.dedupKey(eventIdentifier: "EK-series", occurrenceStart: week1),
            CalendarSyncKey.dedupKey(eventIdentifier: "EK-series", occurrenceStart: week2),
            CalendarSyncKey.dedupKey(eventIdentifier: "EK-series", occurrenceStart: week3),
        ])
        XCTAssertEqual(keys.count, 3, "three occurrences of one series must yield three distinct keys")
    }
}
