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

    func testVanishedImportInWindowIsDeletedWhenFetchTrusted() {
        // A TRUSTWORTHY fetch = still contains at least one held in-window key (`keeper`), proving it's
        // the same Apple store. Within that fetch, `gone`'s key vanished → genuine Apple-side delete.
        let keeper = FamilyEvent(
            id: "fe-keep", title: "Keeper", startDate: inWindow,
            eventKitIdentifier: "EK-keep#1", source: .calendarImport
        )
        let gone = FamilyEvent(
            id: "fe-gone", title: "Old", startDate: inWindow,
            eventKitIdentifier: "EK-gone#1", source: .calendarImport
        )
        let imported = [ImportedEvent(dedupKey: "EK-keep#1", title: "Keeper", startDate: inWindow)]
        let plan = CalendarSyncEngine.plan(
            existing: [keeper, gone], imported: imported,
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertEqual(plan.toDeleteImportIDs, ["fe-gone"], "only the genuinely-vanished import is deleted")
    }

    // MARK: P2.2 — non-destructive reconcile (the empty-/wrong-calendar fix)

    /// The observed bug: an EMPTY Apple fetch must NEVER delete in-window imports. Empty Apple
    /// Calendar = "nothing to reconcile from," not "delete everything."
    func testEmptyFetchNeverDeletesImports() {
        let imports = (0..<35).map { i in
            FamilyEvent(
                id: "fe-\(i)", title: "Real \(i)", startDate: inWindow,
                eventKitIdentifier: "EK-\(i)#1", source: .calendarImport
            )
        }
        let plan = CalendarSyncEngine.plan(
            existing: imports, imported: [],
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertTrue(plan.toDeleteImportIDs.isEmpty, "empty Apple fetch must delete nothing")
    }

    /// The EXACT observed regression: a NON-EMPTY but untrustworthy fetch (a sim's holidays — none of
    /// which share our imported keys) must not delete a single real import.
    func testUnrelatedNonEmptyFetchNeverDeletesImports() {
        let realImports = (0..<26).map { i in
            FamilyEvent(
                id: "fe-\(i)", title: "Real \(i)", startDate: inWindow,
                eventKitIdentifier: "EK-real-\(i)#1", source: .calendarImport
            )
        }
        // Apple returns only holiday-like events sharing NONE of our keys.
        let holidays = [
            ImportedEvent(dedupKey: "EK-holiday-july4#1", title: "Independence Day", startDate: inWindow),
            ImportedEvent(dedupKey: "EK-holiday-labor#1", title: "Labor Day", startDate: inWindow),
        ]
        let plan = CalendarSyncEngine.plan(
            existing: realImports, imported: holidays,
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertTrue(plan.toDeleteImportIDs.isEmpty, "a fetch sharing no held keys is untrusted → no deletes")
    }

    /// Auth gate: even a trustworthy fetch cannot trigger deletes when the caller reports access is not
    /// granted (`deletionsAllowed: false`).
    func testDeletionsDisallowedSkipsReconcile() {
        let keeper = FamilyEvent(
            id: "fe-keep", title: "Keeper", startDate: inWindow,
            eventKitIdentifier: "EK-keep#1", source: .calendarImport
        )
        let gone = FamilyEvent(
            id: "fe-gone", title: "Old", startDate: inWindow,
            eventKitIdentifier: "EK-gone#1", source: .calendarImport
        )
        let imported = [ImportedEvent(dedupKey: "EK-keep#1", title: "Keeper", startDate: inWindow)]
        let plan = CalendarSyncEngine.plan(
            existing: [keeper, gone], imported: imported,
            windowStart: window.start, windowEnd: window.end,
            deletionsAllowed: false
        )
        XCTAssertTrue(plan.toDeleteImportIDs.isEmpty, "no deletes when access isn't granted")
    }

    /// App-origin events (manual/email, no Apple id) are never deleted by reconcile, even with a
    /// trustworthy fetch that doesn't mention them.
    func testAppOriginEventsNeverDeleted() {
        let anchor = FamilyEvent(
            id: "anchor", title: "Imported anchor", startDate: inWindow,
            eventKitIdentifier: "EK-keep#1", source: .calendarImport
        )
        let manual = FamilyEvent(id: "m1", title: "Bacán-made", startDate: inWindow, source: .manual)
        let email = FamilyEvent(id: "e1", title: "From email", startDate: inWindow, source: nil)
        let imported = [ImportedEvent(dedupKey: "EK-keep#1", title: "Imported anchor", startDate: inWindow)]
        let plan = CalendarSyncEngine.plan(
            existing: [anchor, manual, email], imported: imported,
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertTrue(plan.toDeleteImportIDs.isEmpty, "app-origin events are never reconcile-deleted")
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

    // MARK: P2.3 — mass-deletion circuit breaker (the wrong-calendar wipe fix)

    /// Helper: `n` in-window imported events with stable, distinct dedup keys.
    private func realImports(_ n: Int) -> [FamilyEvent] {
        (0..<n).map { i in
            FamilyEvent(
                id: "fe-\(i)", title: "Real \(i)", startDate: inWindow,
                eventKitIdentifier: "EK-\(i)#1", source: .calendarImport
            )
        }
    }

    /// THE exact observed catastrophe (35→9): we hold 30 in-window imports; Apple hands back 9
    /// totally-unrelated events (a wrong simulator calendar). Reconcile must delete NOTHING, while the
    /// additive import of the 9 new events still runs.
    func testWrongCalendarWith30ImportsAnd9UnrelatedEventsDeletesNothingButStillImports() {
        let existing = realImports(30)
        let wrongCalendar = (0..<9).map { i in
            ImportedEvent(dedupKey: "EK-sim-sample-\(i)#1", title: "Sim Sample \(i)", startDate: inWindow)
        }
        var counter = 0
        let plan = CalendarSyncEngine.plan(
            existing: existing, imported: wrongCalendar,
            windowStart: window.start, windowEnd: window.end,
            makeID: { counter += 1; return "new-\(counter)" }
        )
        XCTAssertEqual(plan.toDeleteImportIDs, [], "the 35→9 scenario: a wrong calendar must delete ZERO real imports")
        XCTAssertEqual(plan.toCreate.count, 9, "additive import still runs — the 9 new events are created")
        XCTAssertEqual(plan.suppressedDeleteCount, 30, "all 30 would-be deletes are recorded as suppressed")
    }

    /// Empty Apple fetch against 30 imports → zero deletes (breaker + trust guard both refuse).
    func testEmptyCalendarWith30ImportsDeletesNothing() {
        let plan = CalendarSyncEngine.plan(
            existing: realImports(30), imported: [],
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertEqual(plan.toDeleteImportIDs, [], "empty Apple fetch must delete nothing")
        XCTAssertEqual(plan.suppressedDeleteCount, 30)
    }

    /// A genuine single deletion still reconciles — the circuit breaker must NOT block a normal small
    /// delete. Apple returns the same 30 minus one (29 shared keys, 1 vanished).
    func testGenuineSingleDeletionStillDeletesExactlyOne() {
        let existing = realImports(30)
        let imported = (1..<30).map { i in
            ImportedEvent(dedupKey: "EK-\(i)#1", title: "Real \(i)", startDate: inWindow)
        }
        let plan = CalendarSyncEngine.plan(
            existing: existing, imported: imported,
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertEqual(plan.toDeleteImportIDs, ["fe-0"], "the one genuinely-vanished import is still deleted")
        XCTAssertEqual(plan.toDeleteImportIDs.count, 1, "exactly one delete — real two-way deletion survives")
        XCTAssertEqual(plan.suppressedDeleteCount, 0, "nothing suppressed on a legitimate small delete")
    }

    /// A genuine handful of deletions (30 minus 2) still runs — two real deletions are under the
    /// breaker's ceiling.
    func testGenuineFewDeletionsStillAllowed() {
        let existing = realImports(30)
        let imported = (2..<30).map { i in
            ImportedEvent(dedupKey: "EK-\(i)#1", title: "Real \(i)", startDate: inWindow)
        }
        let plan = CalendarSyncEngine.plan(
            existing: existing, imported: imported,
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertEqual(Set(plan.toDeleteImportIDs), ["fe-0", "fe-1"], "both genuinely-vanished imports are deleted")
        XCTAssertEqual(plan.toDeleteImportIDs.count, 2)
        XCTAssertEqual(plan.suppressedDeleteCount, 0)
    }

    /// A fetch sharing only a sliver of held keys (1 of 30) is untrusted → no deletes, even though it
    /// isn't strictly the "delete most of them" case.
    func testSliverOverlapFetchIsUntrustedAndDeletesNothing() {
        let existing = realImports(30)
        // Apple shares exactly ONE of our 30 keys (EK-0#1); everything else is unrelated noise.
        let imported = [ImportedEvent(dedupKey: "EK-0#1", title: "Real 0", startDate: inWindow)]
            + (0..<3).map { i in ImportedEvent(dedupKey: "EK-noise-\(i)#1", title: "Noise \(i)", startDate: inWindow) }
        let plan = CalendarSyncEngine.plan(
            existing: existing, imported: imported,
            windowStart: window.start, windowEnd: window.end
        )
        XCTAssertEqual(plan.toDeleteImportIDs, [], "1-of-30 overlap is untrusted → no deletes")
        XCTAssertEqual(plan.toCreate.count, 3, "the 3 unrelated events still import additively")
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
