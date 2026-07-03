import CalendarSyncClient
import FamilyDomain
import Foundation
import XCTest

@testable import CalendarFeature

/// Unit coverage for the pure three-phase planner. These are where the three Fambo flaw-fixes are
/// proven deterministically (the E2E sim run confirms them end-to-end).
final class CalendarSyncEngineTests: XCTestCase {
    let cal = Calendar.current
    lazy var visibleMonth = cal.startOfDay(for: Date())
    lazy var window = CalendarSyncEngine.window(for: visibleMonth)
    /// A date safely inside the window.
    lazy var inWindow = window.start.addingTimeInterval(60 * 60 * 24 * 5)

    // MARK: Flaw #1 — recurring import expands to one event per occurrence

    func testImportsEachOccurrenceAsIndividualNonRecurringEvent() {
        let week1 = inWindow
        let week2 = week1.addingTimeInterval(7 * 24 * 3600)
        let imported = [
            ImportedEvent(dedupKey: "EK-s#1", title: "Piano", startDate: week1),
            ImportedEvent(dedupKey: "EK-s#2", title: "Piano", startDate: week2),
        ]
        var counter = 0
        let plan = CalendarSyncEngine.plan(
            existing: [], imported: imported,
            windowStart: window.start, windowEnd: window.end,
            makeID: { counter += 1; return "new-\(counter)" }
        )
        XCTAssertEqual(plan.toCreate.count, 2, "two occurrences → two FamilyEvents (not collapsed)")
        for e in plan.toCreate {
            XCTAssertEqual(e.resolvedSource, .calendarImport)
            XCTAssertEqual(e.recurrence, .none, "imported instances are never re-expanded")
        }
        XCTAssertEqual(Set(plan.toCreate.compactMap(\.eventKitIdentifier)).count, 2, "distinct dedup keys")
    }

    // MARK: Flaw #2 — edited Apple events propagate

    func testEditedImportProducesAnUpdate() {
        let key = "EK-a#1"
        let existing = FamilyEvent(
            id: "fe-1", title: "Dentist", startDate: inWindow,
            eventKitIdentifier: key, source: .calendarImport
        )
        let imported = [ImportedEvent(dedupKey: key, title: "Dentist (moved)", startDate: inWindow.addingTimeInterval(3600))]
        let plan = CalendarSyncEngine.plan(
            existing: [existing], imported: imported,
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertTrue(plan.toCreate.isEmpty)
        XCTAssertEqual(plan.toUpdate.count, 1)
        XCTAssertEqual(plan.toUpdate.first?.id, "fe-1", "same FamilyEvent id, refreshed fields")
        XCTAssertEqual(plan.toUpdate.first?.title, "Dentist (moved)")
        XCTAssertEqual(plan.toUpdate.first?.startDate, inWindow.addingTimeInterval(3600))
    }

    func testUnchangedImportIsNoOp() {
        let key = "EK-a#1"
        let existing = FamilyEvent(
            id: "fe-1", title: "Dentist", startDate: inWindow, endDate: nil, isAllDay: false,
            location: nil, notes: nil, eventKitIdentifier: key, source: .calendarImport
        )
        let imported = [ImportedEvent(dedupKey: key, title: "Dentist", startDate: inWindow)]
        let plan = CalendarSyncEngine.plan(
            existing: [existing], imported: imported,
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertTrue(plan.isEmpty, "identical import → nothing to write")
    }

    // MARK: Phase 3 — deletion reconcile

    func testVanishedImportInWindowIsDeleted() {
        let existing = FamilyEvent(
            id: "fe-gone", title: "Old", startDate: inWindow,
            eventKitIdentifier: "EK-gone#1", source: .calendarImport
        )
        let plan = CalendarSyncEngine.plan(
            existing: [existing], imported: [],
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertEqual(plan.toDeleteImportIDs, ["fe-gone"])
    }

    func testOutOfWindowImportIsNotDeleted() {
        let outside = window.end.addingTimeInterval(60 * 60 * 24 * 60)  // ~2 months past window end
        let existing = FamilyEvent(
            id: "fe-far", title: "Future", startDate: outside,
            eventKitIdentifier: "EK-far#1", source: .calendarImport
        )
        let plan = CalendarSyncEngine.plan(
            existing: [existing], imported: [],
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertTrue(plan.toDeleteImportIDs.isEmpty, "imports outside the synced window must survive")
    }

    // MARK: Push — manual/email → Apple

    func testManualEventInWindowIsPushed() {
        let manual = FamilyEvent(id: "m1", title: "Famfis checkup", startDate: inWindow, source: .manual)
        let email = FamilyEvent(id: "e1", title: "School play", startDate: inWindow, source: nil) // nil→manual
        let imported = FamilyEvent(
            id: "i1", title: "Meeting", startDate: inWindow,
            eventKitIdentifier: "EK-x#1", source: .calendarImport
        )
        let plan = CalendarSyncEngine.plan(
            existing: [manual, email, imported], imported: [],
            windowStart: window.start, windowEnd: window.end
        )
        let pushIDs = Set(plan.toPush.map(\.id))
        XCTAssertTrue(pushIDs.contains("m1"))
        XCTAssertTrue(pushIDs.contains("e1"), "nil-source (email) events resolve to manual and push")
        XCTAssertFalse(pushIDs.contains("i1"), "imported events are never pushed back (loop prevention)")
    }

    func testRecurringManualEventPushedAsSingleEventPreservingRecurrence() {
        let weekly = FamilyEvent(
            id: "w1", title: "Trash night", startDate: inWindow, recurrence: .weekly, source: .manual
        )
        let plan = CalendarSyncEngine.plan(
            existing: [weekly], imported: [],
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertEqual(plan.toPush.count, 1, "one EKEvent + rule, not one-per-occurrence")
        XCTAssertEqual(plan.toPush.first?.recurrence, .weekly)
    }

    // MARK: Window

    func testWindowSpansMonthPlusMinusOne() {
        let (start, end) = CalendarSyncEngine.window(for: visibleMonth)
        let monthInterval = cal.dateInterval(of: .month, for: visibleMonth)!
        XCTAssertLessThan(start, monthInterval.start, "starts before this month (−1 month)")
        XCTAssertGreaterThan(end, monthInterval.end, "ends after this month (+1 month)")
    }
}
