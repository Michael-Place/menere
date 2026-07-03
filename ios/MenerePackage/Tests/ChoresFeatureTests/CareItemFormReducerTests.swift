import ComposableArchitecture
import FamilyDomain
import Foundation
import PersistenceClient
import StorageClient
import UserDomain
import XCTest

@testable import ChoresFeature

/// `TestStore` coverage for the plant save path — including the **P9.1 regression**: a plant that was
/// identified (species filled) but never explicitly named must still save, because "Identify from
/// photo" fills `species`, not `name`. Before the fix, `saveTapped` silently `return .none`'d on a
/// blank name — which read to Michael as "Save doesn't work for adding new plants."
///
/// `@Shared(.user)` is fileStorage-backed, so each test pins `defaultFileStorage = .inMemory` and
/// seeds the user (mirrors `MoneyReducerTests`).
@MainActor
final class CareItemFormReducerTests: XCTestCase {

    /// THE regression test. New plant, `species` filled by identify, `name` left blank → Save falls
    /// back to the species and persists. (Pre-fix: no save, no delegate — the exact bug.)
    func testSaveWithBlankNameFallsBackToIdentifiedSpecies() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Migueluh", householdId: "hid-1") }

            let saved = LockIsolated<[CareItem]>([])
            var item = CareItem(
                kind: .plant, name: "", iconSymbol: "leaf.fill",
                tasks: [CareTask(title: "Water", intervalDays: 7)]
            )
            item.species = "Monstera / Swiss cheese plant"   // filled by Identify; name left blank

            let store = TestStore(initialState: CareItemFormReducer.State(item: item, isEditing: false)) {
                CareItemFormReducer()
            } withDependencies: {
                $0.persistence.saveCareItem = { _, i in saved.withValue { $0.append(i) } }
                $0.dismiss = DismissEffect {}
            }

            await store.send(.saveTapped) {
                $0.item.name = "Monstera / Swiss cheese plant"   // ← the fix's fallback mutation
            }
            await store.receive(.delegate(.didChange))

            XCTAssertEqual(saved.value.count, 1)
            XCTAssertEqual(saved.value.first?.name, "Monstera / Swiss cheese plant")
            XCTAssertEqual(saved.value.first?.kind, .plant)
        }
    }

    /// Happy path: an explicitly-named new plant saves untouched (name is NOT overwritten by species).
    func testSaveWithNameSavesNormally() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", householdId: "hid-1") }

            let saved = LockIsolated<[CareItem]>([])
            var item = CareItem(
                kind: .plant, name: "Monty", iconSymbol: "leaf.fill",
                tasks: [CareTask(title: "Water", intervalDays: 7)]
            )
            item.species = "Monstera deliciosa"

            let store = TestStore(initialState: CareItemFormReducer.State(item: item, isEditing: false)) {
                CareItemFormReducer()
            } withDependencies: {
                $0.persistence.saveCareItem = { _, i in saved.withValue { $0.append(i) } }
                $0.dismiss = DismissEffect {}
            }

            await store.send(.saveTapped)   // no state mutation — name already present
            await store.receive(.delegate(.didChange))

            XCTAssertEqual(saved.value.first?.name, "Monty")            // nickname wins
            XCTAssertEqual(saved.value.first?.species, "Monstera deliciosa")
        }
    }

    /// Guard still holds when there is genuinely nothing to name the item by (no name, no species):
    /// Save no-ops rather than persisting a nameless plant.
    func testSaveWithNoNameNoSpeciesNoOps() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", householdId: "hid-1") }

            let saved = LockIsolated<[CareItem]>([])
            let item = CareItem(kind: .plant, name: "", iconSymbol: "leaf.fill", tasks: [])

            let store = TestStore(initialState: CareItemFormReducer.State(item: item, isEditing: false)) {
                CareItemFormReducer()
            } withDependencies: {
                $0.persistence.saveCareItem = { _, i in saved.withValue { $0.append(i) } }
                $0.dismiss = DismissEffect {}
            }

            await store.send(.saveTapped)   // guard fails → no effect, no delegate
            XCTAssertTrue(saved.value.isEmpty)
        }
    }
}
