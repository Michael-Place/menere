import AnalyticsClient
import ComposableArchitecture
import DocsFeature
import FamilyDomain
import Foundation
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

/// Money — expense tracking + budgets (P13, phase 1: ingestion-ladder rungs 1+2).
///
/// A *lens* on money, not a pipeline: the Family Brain already extracts vendor/amount/docDate from
/// receipts, so phase 1 promotes those into expenses ("New from the Brain" inbox) and adds a manual
/// quick-add. Rolls up a month at a time with category bars vs optional budgets.
@Reducer
public struct MoneyReducer {
    @ObservableState
    public struct State: Equatable {
        var expenses: [Expense] = []
        var documents: [FamilyDomain.Document] = []
        var budgets: BudgetConfig = .init()
        /// First-of-month anchor the screen shows / navigates. Defaults to the current month.
        var monthAnchor: Date = Date()
        var isLoading = false
        var currentUid: String?

        // P22.1 — forward-looking spend.
        /// "Now" reference for the recurring-bill forecast (set on `.task`; keeps the projection
        /// deterministic + testable rather than reading `Date()` inside a derived property).
        var referenceDate: Date = Date()
        /// Intended future spend rolled up from the family's wishlist/gift/project lists (read-only).
        var planned: PlannedSpending.Rollup = .empty
        /// V1-C — the MEAL→GROCERY→MONEY loop: this week's grocery bill estimated off the meal plan
        /// (read-only; an honest ballpark, surfaced in the "Planned / wishlist" card).
        var groceriesPlanned: GroceryCostEstimator.Estimate = .empty

        // P22 — Spending intelligence.
        /// Whether the spending-insights sheet is presented.
        var showInsights = false
        /// The AI "This month, in a nutshell" recap (nil until generated for the current month).
        var spendingSummary: SpendingSummary?
        /// True while the `summarizeSpending` call is in flight (drives the shimmer).
        var isSummarizing = false

        @Presents var addExpense: ExpenseFormReducer.State?
        @Presents var budgetEditor: BudgetEditorReducer.State?
        /// The source Family-Brain document a promoted expense links back to (P24 backlink).
        @Presents var docDetail: DocumentDetailReducer.State?

        public init(monthAnchor: Date = Date()) {
            self.monthAnchor = monthAnchor
        }

        // MARK: Derived

        /// The rolled-up summary for the anchored month (spend + budgets by category).
        var summary: MoneyRollup.MonthSummary {
            MoneyRollup.summary(expenses: expenses, budgets: budgets, month: monthAnchor)
        }

        /// This month's expenses, newest first — the deletable ledger below the bars.
        var monthExpenses: [Expense] {
            expenses
                .filter { MoneyRollup.isInMonth($0.date, of: monthAnchor) }
                .sorted { $0.date > $1.date }
        }

        /// The P22 spending-intelligence report for the anchored month + the whole history
        /// (Expenses ⊕ amount-bearing Brain docs, deduped, categorized, one-time-bucketed).
        var report: SpendingInsights.Report {
            SpendingInsights.report(expenses: expenses, documents: documents, month: monthAnchor)
        }

        /// "Coming up" — the next expected charge for each recurring vendor, soonest first. Projects
        /// off `report.recurring` so it mirrors the "Looks recurring" list. It's an estimate.
        var forecast: [SpendingForecast.Upcoming] {
            SpendingForecast.upcoming(
                expenses: expenses,
                documents: documents,
                recurring: report.recurring,
                now: referenceDate
            )
        }

        /// "New from the Brain": documents carrying an amount that aren't yet an expense and haven't
        /// been dismissed. Matches on `documentId`, so filing one makes it drop out of the inbox.
        var inboxDocuments: [FamilyDomain.Document] {
            let linked = Set(expenses.compactMap(\.documentId))
            let dismissed = Set(budgets.dismissedDocumentIds)
            return documents
                .filter { doc in
                    guard let amount = doc.amount, amount > 0 else { return false }
                    return !linked.contains(doc.id) && !dismissed.contains(doc.id)
                }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case expensesLoaded([Expense])
        case documentsLoaded([FamilyDomain.Document])
        case budgetsLoaded(BudgetConfig?)
        case plannedLoaded(PlannedSpending.Rollup)
        case groceriesPlannedLoaded(GroceryCostEstimator.Estimate)
        case previousMonthTapped
        case nextMonthTapped
        case insightsOpened
        case generateSummary
        case summaryResponse(SpendingSummary?)
        case refreshSummaryTapped
        case addTapped
        case editBudgetsTapped
        case fileFromBrainTapped(FamilyDomain.Document)
        case dismissBrainDocument(FamilyDomain.Document)
        case deleteExpenses(IndexSet)
        case expenseDocTapped(Expense)
        case addExpense(PresentationAction<ExpenseFormReducer.Action>)
        case budgetEditor(PresentationAction<BudgetEditorReducer.Action>)
        case docDetail(PresentationAction<DocumentDetailReducer.Action>)
        case binding(BindingAction<State>)
    }

    public init() {}

    @Dependency(\.persistence) var persistence
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date
    @Dependency(\.analytics) var analytics   // P25 telemetry (fire-and-forget)
    @Dependency(\.spending) var spendingClient // P22 AI monthly summary

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    private func uid() -> String? {
        @Shared(.user) var user
        return user?.id
    }

    /// Start of the calendar week containing `date` — the window for the meal-plan grocery estimate
    /// (mirrors `RecipesReducer.startOfWeek`, so Kitchen and Money price the same week).
    static func startOfWeek(_ date: Date) -> Date {
        let cal = Calendar.current
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                state.currentUid = uid()
                state.referenceDate = date.now
                let weekStart = MoneyReducer.startOfWeek(state.referenceDate)
                guard let hid = hid() else { return .none }
                state.isLoading = true
                return .run { send in
                    async let expenses = persistence.expenses(hid)
                    async let documents = persistence.documents(hid)
                    async let budgets = persistence.budgetConfig(hid)
                    await send(.expensesLoaded((try? await expenses) ?? []))
                    await send(.documentsLoaded((try? await documents) ?? []))
                    await send(.budgetsLoaded(try? await budgets))

                    // Planned-spending rollup — read-only over the wishlist/gift/project lists.
                    let lists = ((try? await persistence.lists(hid)) ?? [])
                        .filter { $0.isWishlist || $0.isGift || $0.isProject }
                    var itemsByList: [String: [ListItem]] = [:]
                    for list in lists {
                        itemsByList[list.id] = (try? await persistence.listItems(hid, list.id)) ?? []
                    }
                    await send(.plannedLoaded(PlannedSpending.rollup(lists: lists, itemsByList: itemsByList)))

                    // V1-C — the MEAL→GROCERY→MONEY loop: estimate this week's grocery bill from the
                    // meal plan (read-only; reuses the exact ingredient set the Kitchen shops for).
                    async let recipes = persistence.recipes(hid)
                    async let mealPlan = persistence.mealPlan(hid)
                    let estimate = GroceryCostEstimator.weeklyEstimate(
                        recipes: (try? await recipes) ?? [],
                        mealPlan: (try? await mealPlan) ?? [],
                        weekStart: weekStart
                    )
                    await send(.groceriesPlannedLoaded(estimate))
                }

            case let .expensesLoaded(expenses):
                state.isLoading = false
                state.expenses = expenses
                return .none

            case let .documentsLoaded(documents):
                state.documents = documents
                return .none

            case let .budgetsLoaded(budgets):
                if let budgets { state.budgets = budgets }
                return .none

            case let .plannedLoaded(planned):
                state.planned = planned
                return .none

            case let .groceriesPlannedLoaded(estimate):
                state.groceriesPlanned = estimate
                return .none

            case .previousMonthTapped:
                state.monthAnchor = MoneyRollup.shiftMonth(state.monthAnchor, by: -1)
                state.spendingSummary = nil // month changed — recap no longer applies
                return .none

            case .nextMonthTapped:
                state.monthAnchor = MoneyRollup.shiftMonth(state.monthAnchor, by: 1)
                state.spendingSummary = nil
                return .none

            case .insightsOpened:
                state.showInsights = true
                analytics.log("spending_insights_opened")
                if !state.forecast.isEmpty || !state.planned.isEmpty || !state.groceriesPlanned.isEmpty { analytics.log("money_forecast_viewed") }
                // Kick off the AI recap once per month view (refresh regenerates).
                guard state.spendingSummary == nil, !state.isSummarizing else { return .none }
                return .send(.generateSummary)

            case .generateSummary:
                guard !state.isSummarizing else { return .none }
                state.isSummarizing = true
                let month = MoneyView.monthTitle(state.monthAnchor)
                let lines = state.report.monthLines.map(SpendingLinePayload.init(line:))
                return .run { send in
                    let result = try? await spendingClient.summarize(month, lines)
                    await send(.summaryResponse(result))
                }

            case let .summaryResponse(summary):
                state.isSummarizing = false
                if let summary {
                    state.spendingSummary = summary
                    analytics.log("spending_summary_generated")
                }
                return .none

            case .refreshSummaryTapped:
                return .send(.generateSummary)

            case .addTapped:
                state.addExpense = ExpenseFormReducer.State(
                    date: date.now,
                    memberId: state.currentUid
                )
                return .none

            case .editBudgetsTapped:
                state.budgetEditor = BudgetEditorReducer.State(config: state.budgets)
                return .none

            case let .fileFromBrainTapped(doc):
                guard let hid = hid() else { return .none }
                analytics.log("expense_logged", ["source": "brain"])
                let expense = Expense.promoting(document: doc, id: uuid().uuidString, now: date.now)
                state.expenses.append(expense)
                return .run { _ in
                    try await persistence.saveExpense(hid, expense)
                }

            case let .dismissBrainDocument(doc):
                guard let hid = hid() else { return .none }
                guard !state.budgets.dismissedDocumentIds.contains(doc.id) else { return .none }
                state.budgets.dismissedDocumentIds.append(doc.id)
                let config = state.budgets
                return .run { _ in
                    try await persistence.saveBudgetConfig(hid, config)
                }

            case let .deleteExpenses(offsets):
                guard let hid = hid() else { return .none }
                let monthExpenses = state.monthExpenses
                let toDelete = offsets.map { monthExpenses[$0] }
                let deleteIDs = Set(toDelete.map(\.id))
                state.expenses.removeAll { deleteIDs.contains($0.id) }
                return .run { _ in
                    for expense in toDelete { try await persistence.deleteExpense(hid, expense.id) }
                }

            case let .expenseDocTapped(expense):
                guard let docId = expense.documentId,
                      let doc = state.documents.first(where: { $0.id == docId }) else { return .none }
                analytics.log("related_item_tapped", ["kind": "expense_source"])
                state.docDetail = DocumentDetailReducer.State(doc: doc)
                return .none

            case .docDetail:
                return .none

            case let .addExpense(.presented(.delegate(.save(expense)))):
                guard let hid = hid() else { state.addExpense = nil; return .none }
                analytics.log("expense_logged", ["source": "manual"])
                state.addExpense = nil
                state.expenses.append(expense)
                return .run { _ in
                    try await persistence.saveExpense(hid, expense)
                }

            case .addExpense(.presented(.delegate(.cancel))):
                state.addExpense = nil
                return .none

            case .addExpense:
                return .none

            case let .budgetEditor(.presented(.delegate(.save(config)))):
                guard let hid = hid() else { state.budgetEditor = nil; return .none }
                state.budgetEditor = nil
                state.budgets = config
                return .run { _ in
                    try await persistence.saveBudgetConfig(hid, config)
                }

            case .budgetEditor(.presented(.delegate(.cancel))):
                state.budgetEditor = nil
                return .none

            case .budgetEditor:
                return .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$addExpense, action: \.addExpense) {
            ExpenseFormReducer()
        }
        .ifLet(\.$budgetEditor, action: \.budgetEditor) {
            BudgetEditorReducer()
        }
        .ifLet(\.$docDetail, action: \.docDetail) {
            DocumentDetailReducer()
        }
    }
}

public extension ExpenseCategory {
    /// Family-palette tint for a category (kept in the UI layer so `FamilyDomain` stays UI-free,
    /// mirroring `DocumentType`'s tint mapping in DocsFeature).
    var tint: Color {
        switch self {
        case .groceries: .bacanGreen
        case .dining: .terracotta
        case .kids: .sky
        case .house: .inkSoft
        case .garden: .sage
        case .pets: .marigold
        case .fun: .marigold
        case .other: .inkSoft
        }
    }
}
