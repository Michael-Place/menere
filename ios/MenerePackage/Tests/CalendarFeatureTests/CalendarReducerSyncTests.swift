import CalendarSyncClient
import ComposableArchitecture
import FamilyDomain
import Foundation
import PersistenceClient
import UserDomain
import XCTest

@testable import CalendarFeature

/// A reducer-level walk of `.syncNow` with a fully-mocked `CalendarSyncClient` + `PersistenceClient`,
/// exercising all four write paths in one pass: import (create), reconcile (delete), and push. The
/// exact classification is unit-tested in `CalendarSyncEngineTests`; this proves the reducer wires the
/// plan through to the clients.
@MainActor
final class CalendarReducerSyncTests: XCTestCase {

    func testSyncNowDrivesImportDeleteAndPush() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Migueluh", householdId: "hid-1") }

            let now = Calendar.current.startOfDay(for: Date())
            let inWindow = now.addingTimeInterval(60 * 60 * 24 * 3)

            // Existing Firestore state: one manual event to push, one still-present import (anchors the
            // P2.2 trust guard — proves the fetch is the same Apple store), one stale import to delete.
            let manual = FamilyEvent(id: "m1", title: "Famfis checkup", startDate: inWindow, source: .manual)
            let liveImport = FamilyEvent(
                id: "i-live", title: "Piano", startDate: inWindow,
                eventKitIdentifier: "EK-live#1", source: .calendarImport
            )
            let staleImport = FamilyEvent(
                id: "i-old", title: "Gone", startDate: inWindow,
                eventKitIdentifier: "EK-old#1", source: .calendarImport
            )
            let existing = LockIsolated<[FamilyEvent]>([manual, liveImport, staleImport])

            let savedEvents = LockIsolated<[FamilyEvent]>([])
            let deletedIDs = LockIsolated<[String]>([])
            let pushedEvents = LockIsolated<[FamilyEvent]>([])
            let savedPrefs = LockIsolated<[CalendarSyncPrefs]>([])

            var initial = CalendarReducer.State()
            initial.accessStatus = .granted
            initial.prefs = CalendarSyncPrefs(enabled: true, hasCompletedSetup: true)
            initial.visibleMonth = now

            let store = TestStore(initialState: initial) {
                CalendarReducer()
            } withDependencies: {
                $0.persistence.events = { _ in existing.value }
                $0.persistence.members = { _ in [] }
                $0.persistence.calendarSyncPrefs = { _ in nil }
                $0.persistence.saveCalendarSyncPrefs = { _, p in savedPrefs.withValue { $0.append(p) } }
                $0.persistence.saveEvent = { _, e in savedEvents.withValue { $0.append(e) } }
                $0.persistence.deleteEvent = { _, id in deletedIDs.withValue { $0.append(id) } }

                $0.calendarSyncClient.authorizationStatus = { .granted }
                $0.calendarSyncClient.ensureBacanCalendar = { _ in "bacan-1" }
                $0.calendarSyncClient.availableCalendars = { [] }
                $0.calendarSyncClient.fetchWindow = { _, _, _, _ in
                    [
                        // The anchor: still present → makes the fetch trustworthy (P2.2), so reconcile runs.
                        ImportedEvent(dedupKey: "EK-live#1", title: "Piano", startDate: inWindow),
                        // A brand-new Apple occurrence → import (create).
                        ImportedEvent(dedupKey: "EK-new#1", title: "Dentist", startDate: inWindow),
                    ]
                }
                $0.calendarSyncClient.saveEvent = { e, _ in
                    pushedEvents.withValue { $0.append(e) }
                    return "EK-pushed-1"
                }
            }
            store.exhaustivity = .off

            await store.send(.syncNow)
            await store.receive(\.syncFinished)

            // Import: the new Apple occurrence was written as a calendarImport FamilyEvent.
            let created = savedEvents.value.first { $0.eventKitIdentifier == "EK-new#1" }
            XCTAssertNotNil(created, "the imported occurrence should be saved")
            XCTAssertEqual(created?.resolvedSource, .calendarImport)
            XCTAssertEqual(created?.recurrence, RecurrenceOption.none)

            // Reconcile: the vanished import was deleted.
            XCTAssertTrue(deletedIDs.value.contains("i-old"))

            // Push: the manual event was pushed to Apple, and its returned EK id written back.
            XCTAssertEqual(pushedEvents.value.map(\.id), ["m1"])
            let pushedBack = savedEvents.value.first { $0.id == "m1" }
            XCTAssertEqual(pushedBack?.eventKitIdentifier, "EK-pushed-1", "returned EK id persisted back")

            // Prefs advanced (lastSynced + bacan id).
            XCTAssertEqual(savedPrefs.value.last?.bacanCalendarID, "bacan-1")
            XCTAssertNotNil(savedPrefs.value.last?.lastSyncedAt)
        }
    }

    /// Guard: `.syncNow` is inert without calendar access (degrade silently, no client calls).
    func testSyncNoOpWithoutAccess() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", householdId: "hid-1") }

            var initial = CalendarReducer.State()
            initial.accessStatus = .denied
            initial.prefs = CalendarSyncPrefs(enabled: true, hasCompletedSetup: true)

            let store = TestStore(initialState: initial) { CalendarReducer() }
            store.exhaustivity = .off

            await store.send(.syncNow)  // no state change, no effects
            XCTAssertFalse(store.state.isSyncing)
        }
    }
}
