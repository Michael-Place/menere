import ComposableArchitecture
import FamilyDomain
import Foundation
import PersistenceClient
import UserDomain
import XCTest

@testable import ChoresFeature

/// P70 / Bug-2 fix: undoing a one-tap care "mark done" must not leave a stale "watered …" activity
/// entry in Firestore. The mark-done writes an optimistic ``ActivityItem``; the Undo now deletes that
/// same doc via `persistence.deleteActivity(hid:id:)` (best-effort), not just from local state.
///
/// `@Shared(.user)` is fileStorage-backed, so each test pins `defaultFileStorage = .inMemory` and
/// seeds the user (mirrors ``CareItemFormReducerTests``).
@MainActor
final class CareUndoActivityCleanupTests: XCTestCase {

    /// mark-done → Undo deletes the just-written activity doc from Firestore, keyed by the exact id
    /// captured on the mark-done. Also confirms the local activity entry is popped.
    func testUndoDeletesActivityDocFromFirestore() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Migueluh", householdId: "hid-1") }

            let deleted = LockIsolated<[(hid: String, id: String)]>([])

            let item = CareItem(
                kind: .plant, name: "Monty", iconSymbol: "leaf.fill",
                tasks: [CareTask(title: "Water", intervalDays: 7)]
            )
            let taskID = item.tasks[0].id

            var initial = ChoresReducer.State()
            initial.careItems = [item]
            initial.members = [HouseholdMember(id: "uid-1", name: "Migueluh")]

            let store = TestStore(initialState: initial) {
                ChoresReducer()
            } withDependencies: {
                // `writeCareDone` is a convenience over these two closures.
                $0.persistence.saveCareItem = { @Sendable _, _ in }
                $0.persistence.logActivity = { @Sendable _, _ in }
                $0.persistence.deleteActivity = { @Sendable hid, id in
                    deleted.withValue { $0.append((hid, id)) }
                }
            }
            // Focused on the undo→delete wiring, not the exact optimistic-state shape.
            store.exhaustivity = .off

            await store.send(.markCareTaskDone(itemID: item.id, taskID: taskID))

            // The mark-done captured the optimistic activity id in the Undo banner.
            let activityID = store.state.careUndo?.activityID
            XCTAssertNotNil(activityID, "mark-done should record the optimistic activity id for undo")

            await store.send(.undoCareTaskDone)

            // Local pop: the optimistic entry is gone from state…
            XCTAssertFalse(store.state.activity.contains { $0.id == activityID })
            XCTAssertNil(store.state.careUndo)
            // …and it was also deleted from Firestore with the right hid + id (the actual fix).
            XCTAssertEqual(deleted.value.count, 1)
            XCTAssertEqual(deleted.value.first?.hid, "hid-1")
            XCTAssertEqual(deleted.value.first?.id, activityID)
        }
    }

    /// Regression: a mark-done that is NOT undone writes its activity normally and never deletes.
    func testMarkDoneWithoutUndoDoesNotDelete() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Migueluh", householdId: "hid-1") }

            let deleted = LockIsolated<[String]>([])
            let logged = LockIsolated<[ActivityItem]>([])

            let item = CareItem(
                kind: .plant, name: "Monty", iconSymbol: "leaf.fill",
                tasks: [CareTask(title: "Water", intervalDays: 7)]
            )
            let taskID = item.tasks[0].id

            var initial = ChoresReducer.State()
            initial.careItems = [item]
            initial.members = [HouseholdMember(id: "uid-1", name: "Migueluh")]

            let store = TestStore(initialState: initial) {
                ChoresReducer()
            } withDependencies: {
                $0.persistence.saveCareItem = { @Sendable _, _ in }
                $0.persistence.logActivity = { @Sendable _, activity in
                    logged.withValue { $0.append(activity) }
                }
                $0.persistence.deleteActivity = { @Sendable _, id in
                    deleted.withValue { $0.append(id) }
                }
            }
            store.exhaustivity = .off

            await store.send(.markCareTaskDone(itemID: item.id, taskID: taskID))
            // Let the pending auto-dismiss timer settle so the store finishes clean.
            await store.send(.dismissCareUndo)

            XCTAssertEqual(logged.value.count, 1, "mark-done still writes the activity normally")
            XCTAssertTrue(deleted.value.isEmpty, "no undo → nothing deleted")
        }
    }
}
