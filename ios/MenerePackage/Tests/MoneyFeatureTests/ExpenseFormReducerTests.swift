import ComposableArchitecture
import FamilyDomain
import Foundation
import XCTest

@testable import MoneyFeature

/// `ExpenseFormReducer` (the manual quick-add sheet): the amount gate + delegate payload it builds.
@MainActor
final class ExpenseFormReducerTests: XCTestCase {
    func testAmountParsingGatesSave() {
        var state = ExpenseFormReducer.State()
        XCTAssertNil(state.amount)            // blank
        state.amountText = "abc"
        XCTAssertNil(state.amount)            // garbage
        state.amountText = "0"
        XCTAssertNil(state.amount)            // non-positive
        state.amountText = "84.12"
        XCTAssertEqual(state.amount, 84.12)
        state.amountText = "1,200"
        XCTAssertEqual(state.amount, 1200)    // comma stripped
    }

    func testSaveTappedEmitsBuiltExpense() async {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 12))!
        let store = TestStore(
            initialState: ExpenseFormReducer.State(memberId: "uid-1")
        ) {
            ExpenseFormReducer()
        } withDependencies: {
            $0.uuid = .constant(UUID(2))
            $0.date = .constant(now)
        }

        await store.send(.binding(.set(\.amountText, "84.12"))) { $0.amountText = "84.12" }
        await store.send(.binding(.set(\.vendor, "Green Thumb"))) { $0.vendor = "Green Thumb" }
        await store.send(.binding(.set(\.category, .garden))) { $0.category = .garden }
        await store.send(.binding(.set(\.date, now))) { $0.date = now }

        // Save emits the exact built expense as a delegate payload (uuid + date injected).
        let expected = Expense(
            id: UUID(2).uuidString, amount: 84.12, vendor: "Green Thumb",
            category: .garden, date: now, memberId: "uid-1", source: .manual,
            documentId: nil, notes: nil, createdAt: now
        )
        await store.send(.saveTapped)
        await store.receive(.delegate(.save(expected)))
    }
}
