import ComposableArchitecture
import FamilyDomain
import Foundation
import PersistenceClient
import UserDomain
import XCTest

@testable import MoneyFeature

/// `TestStore` coverage for `MoneyReducer`: promoting a Brain document into a correctly-linked
/// expense, the manual quick-add path, and inbox dismissal persisting to the budget config.
///
/// `@Shared(.user)` is fileStorage-backed, so each test pins `defaultFileStorage = .inMemory` and
/// seeds the user (mirrors `CellarReducerTests`).
@MainActor
final class MoneyReducerTests: XCTestCase {
    private func fixedDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// The Kindercare document — a real school doc carrying an amount.
    private var kindercare: FamilyDomain.Document {
        Document(
            id: "doc-kc", title: "Kindercare Fall Registration", type: .school,
            tags: ["kindercare", "childcare", "fees"], amount: 175,
            vendor: "KinderCare - Heather Park", uploadedBy: "uid-1"
        )
    }

    // MARK: Promote from the Brain

    func testFileFromBrainCreatesCorrectlyLinkedExpense() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Migueluh", householdId: "hid-1") }

            let saved = LockIsolated<[Expense]>([])
            let now = fixedDate(2026, 7, 2)

            var state = MoneyReducer.State(monthAnchor: now)
            state.documents = [kindercare]

            let store = TestStore(initialState: state) {
                MoneyReducer()
            } withDependencies: {
                $0.uuid = .constant(UUID(0))
                $0.date = .constant(now)
                $0.persistence.saveExpense = { _, expense in saved.withValue { $0.append(expense) } }
            }

            // Inbox shows the Kindercare doc before filing.
            XCTAssertEqual(store.state.inboxDocuments.map(\.id), ["doc-kc"])

            await store.send(.fileFromBrainTapped(kindercare)) {
                $0.expenses = [
                    Expense(
                        id: UUID(0).uuidString, amount: 175, vendor: "KinderCare - Heather Park",
                        category: .kids, date: now, memberId: nil, source: .receiptScan,
                        documentId: "doc-kc", notes: nil, createdAt: now
                    )
                ]
            }

            // Persisted correctly-linked, and the inbox is now empty (matched on documentId).
            XCTAssertEqual(saved.value.count, 1)
            XCTAssertEqual(saved.value.first?.documentId, "doc-kc")
            XCTAssertEqual(saved.value.first?.category, .kids)
            XCTAssertEqual(saved.value.first?.source, .receiptScan)
            XCTAssertTrue(store.state.inboxDocuments.isEmpty)
            XCTAssertEqual(store.state.summary.total, 175)
        }
    }

    // MARK: Dismiss from the inbox

    func testDismissBrainDocumentPersistsAndHidesIt() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Migueluh", householdId: "hid-1") }

            let savedConfig = LockIsolated<[BudgetConfig]>([])
            var state = MoneyReducer.State(monthAnchor: fixedDate(2026, 7, 2))
            state.documents = [kindercare]

            let store = TestStore(initialState: state) {
                MoneyReducer()
            } withDependencies: {
                $0.persistence.saveBudgetConfig = { _, config in savedConfig.withValue { $0.append(config) } }
            }

            await store.send(.dismissBrainDocument(kindercare)) {
                $0.budgets.dismissedDocumentIds = ["doc-kc"]
            }
            XCTAssertTrue(store.state.inboxDocuments.isEmpty)
            XCTAssertEqual(savedConfig.value.first?.dismissedDocumentIds, ["doc-kc"])
        }
    }

    // MARK: Manual quick-add

    func testManualAddSavesExpense() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Migueluh", householdId: "hid-1") }

            let saved = LockIsolated<[Expense]>([])
            let now = fixedDate(2026, 7, 2)
            let store = TestStore(initialState: MoneyReducer.State(monthAnchor: now)) {
                MoneyReducer()
            } withDependencies: {
                $0.uuid = .constant(UUID(1))
                $0.date = .constant(now)
                $0.persistence.saveExpense = { _, expense in saved.withValue { $0.append(expense) } }
            }
            store.exhaustivity = .off

            // Present the quick-add sheet, then hand the parent the form's save delegate.
            let expense = Expense(
                id: UUID(1).uuidString, amount: 84.12, vendor: "Green Thumb",
                category: .garden, date: now, memberId: "uid-1", source: .manual,
                documentId: nil, notes: nil, createdAt: now
            )
            await store.send(.addTapped)
            await store.send(.addExpense(.presented(.delegate(.save(expense)))))
            XCTAssertEqual(saved.value.first?.amount, 84.12)
            XCTAssertEqual(saved.value.first?.category, .garden)
            XCTAssertEqual(saved.value.first?.source, .manual)
            XCTAssertEqual(store.state.summary.total, 84.12)
        }
    }

    // MARK: Month navigation

    func testMonthNavigationShiftsAnchor() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Migueluh", householdId: "hid-1") }

            let store = TestStore(initialState: MoneyReducer.State(monthAnchor: fixedDate(2026, 7, 15))) {
                MoneyReducer()
            }
            store.exhaustivity = .off
            await store.send(.previousMonthTapped)
            XCTAssertTrue(MoneyRollup.isInMonth(fixedDate(2026, 6, 10), of: store.state.monthAnchor))
            await store.send(.nextMonthTapped)
            await store.send(.nextMonthTapped)
            XCTAssertTrue(MoneyRollup.isInMonth(fixedDate(2026, 8, 10), of: store.state.monthAnchor))
        }
    }
}
