import ComposableArchitecture
import DocsFeature
import FamilyDomain
import Foundation
import MenereUI
import SwiftUI

public struct MoneyView: View {
    @Bindable var store: StoreOf<MoneyReducer>

    public init(store: StoreOf<MoneyReducer>) {
        self.store = store
    }

    public var body: some View {
        List {
            monthHeaderSection
            if !store.budgetAlerts.isEmpty { budgetAlertsSection }
            insightsSection
            if !store.inboxDocuments.isEmpty { inboxSection }
            categoryBarsSection
            goalsSection
            ledgerSection
            bankSyncSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Money")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.send(.insightsOpened) } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("spending-insights-button")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.send(.editBudgetsTapped) } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("edit-budgets-button")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.send(.addTapped) } label: {
                    Image(systemName: "plus").appearBounce()
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("add-expense-button")
            }
        }
        .task { store.send(.task) }
        .successHaptic(store.expenses.count)
        .sheet(item: $store.scope(state: \.addExpense, action: \.addExpense)) { formStore in
            ExpenseFormView(store: formStore)
        }
        .sheet(item: $store.scope(state: \.budgetEditor, action: \.budgetEditor)) { editorStore in
            BudgetEditorView(store: editorStore)
        }
        .sheet(item: $store.scope(state: \.goalEditor, action: \.goalEditor)) { editorStore in
            GoalEditorView(store: editorStore)
        }
        .sheet(isPresented: $store.showInsights) {
            SpendingInsightsView(store: store)
        }
        .navigationDestination(
            item: $store.scope(state: \.docDetail, action: \.docDetail)
        ) { detailStore in
            DocumentDetailView(store: detailStore)
        }
    }

    // MARK: Insights entry card

    private var insightsSection: some View {
        Section {
            Button { store.send(.insightsOpened) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(Color.bacanGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spending insights")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.ink)
                        Text(insightsSubtitle)
                            .font(.caption)
                            .foregroundStyle(Color.inkSoft)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.inkSoft)
                }
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("spending-insights-card")
        }
        .listRowBackground(Color.familySurface)
    }

    private var insightsSubtitle: String {
        let report = store.report
        if !report.recurring.isEmpty {
            return "Breakdown, trend & \(report.recurring.count) recurring"
        }
        if report.trend.hasComparison, report.trend.isUp || report.trend.isDown {
            return report.trend.isUp ? "Where it went + you're up vs. last month" : "Where it went + you're down vs. last month"
        }
        return "Where it went, trends & recurring charges"
    }

    // MARK: Month header + total

    private var monthHeaderSection: some View {
        Section {
            VStack(spacing: 14) {
                HStack {
                    Button { store.send(.previousMonthTapped) } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.bacanGreen)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("prev-month-button")
                    Spacer()
                    Text(Self.monthTitle(store.monthAnchor))
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Button { store.send(.nextMonthTapped) } label: {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.bacanGreen)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("next-month-button")
                }

                VStack(spacing: 2) {
                    Text(Self.currency(store.summary.total))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("month-total")
                    Text("spent this month")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSoft)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .listRowBackground(Color.familySurface)
    }

    // MARK: New from the Brain

    private var inboxSection: some View {
        Section {
            ForEach(store.inboxDocuments) { doc in
                BrainInboxRow(
                    doc: doc,
                    onFile: { store.send(.fileFromBrainTapped(doc)) },
                    onDismiss: { store.send(.dismissBrainDocument(doc)) }
                )
            }
        } header: {
            Text("New from the Brain")
                .foregroundStyle(Color.inkSoft)
        } footer: {
            Text("Receipts the Family Brain spotted — file them in one tap.")
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
        }
        .listRowBackground(Color.familySurface)
    }

    // MARK: Category bars

    private var categoryBarsSection: some View {
        Section("Where it went") {
            if store.summary.isEmpty {
                Text("Nothing logged yet this month. Tap + to jot a spend, or file one from the Brain above.")
                    .font(.callout)
                    .foregroundStyle(Color.inkSoft)
            } else {
                let neutralMax = store.summary.maxSpend
                let progress = store.monthProgress
                ForEach(store.summary.lines) { line in
                    CategoryBarRow(line: line, neutralMax: neutralMax, monthProgress: progress)
                }
            }
        }
        .listRowBackground(Color.familySurface)
    }

    // MARK: Budget alerts

    private var budgetAlertsSection: some View {
        Section {
            ForEach(store.budgetAlerts) { alert in
                BudgetAlertRow(alert: alert)
            }
        } header: {
            Label("Heads up", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.terracotta)
        } footer: {
            Text("A gentle nudge — a category is over, or on pace to be. Tap the sliders to adjust a budget.")
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
        }
        .listRowBackground(Color.familySurface)
    }

    // MARK: Savings goals

    private var goalsSection: some View {
        Section {
            if store.sortedGoals.isEmpty {
                Button { store.send(.addGoalTapped) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "target")
                            .font(.title3)
                            .foregroundStyle(Color.bacanGreen)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start a savings goal")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(Color.ink)
                            Text("A vacation, a rainy-day jar, the next big thing.")
                                .font(.caption)
                                .foregroundStyle(Color.inkSoft)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.bacanGreen)
                    }
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("add-goal-empty-button")
            } else {
                ForEach(store.sortedGoals) { goal in
                    Button { store.send(.goalTapped(goal)) } label: {
                        GoalRow(goal: goal, now: store.referenceDate)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("goal-row-\(goal.id)")
                }
                .onDelete { store.send(.deleteGoals($0)) }
            }
        } header: {
            HStack {
                Text("Savings goals").foregroundStyle(Color.inkSoft)
                Spacer()
                if !store.sortedGoals.isEmpty {
                    Button { store.send(.addGoalTapped) } label: {
                        Image(systemName: "plus")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Color.bacanGreen)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("add-goal-button")
                }
            }
        }
        .listRowBackground(Color.familySurface)
    }

    // MARK: Bank sync (Plaid — coming soon)

    private var bankSyncSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "building.columns.fill")
                    .font(.title3)
                    .foregroundStyle(Color.sky)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Connect a bank")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.ink)
                        Text("Coming soon")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.marigold.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.marigold)
                    }
                    Text("Once set up, transactions import themselves — no more jotting each spend. Needs a quick one-time Plaid connection.")
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .accessibilityIdentifier("connect-bank-row")
        }
        .listRowBackground(Color.familySurface)
    }

    // MARK: Ledger

    private var ledgerSection: some View {
        Section("Expenses") {
            if store.monthExpenses.isEmpty {
                Text("No expenses this month.")
                    .font(.callout)
                    .foregroundStyle(Color.inkSoft)
            } else {
                ForEach(store.monthExpenses) { expense in
                    ExpenseRow(
                        expense: expense,
                        sourceDocTitle: sourceDocTitle(for: expense),
                        onOpenSource: { store.send(.expenseDocTapped(expense)) }
                    )
                }
                .onDelete { store.send(.deleteExpenses($0)) }
            }
        }
        .listRowBackground(Color.familySurface)
    }

    /// Title of the Brain document an expense was promoted from (P24 backlink), if it's still around.
    private func sourceDocTitle(for expense: Expense) -> String? {
        guard let docId = expense.documentId else { return nil }
        return store.documents.first { $0.id == docId }?.title
    }

    // MARK: Formatting

    static func monthTitle(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMMM yyyy"
        return df.string(from: date)
    }

    static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value == value.rounded() ? 0 : 2)))
    }
}

// MARK: - Rows

private struct BrainInboxRow: View {
    let doc: FamilyDomain.Document
    let onFile: () -> Void
    let onDismiss: () -> Void

    private var suggested: ExpenseCategory { doc.suggestedExpenseCategory }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: suggested.symbolName)
                    .foregroundStyle(suggested.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button(action: onFile) {
                    Label("File it", systemImage: "tray.and.arrow.down.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.bacanGreen.opacity(0.16), in: Capsule())
                        .foregroundStyle(Color.bacanGreen)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("file-it-button")

                Button(action: onDismiss) {
                    Text("Not an expense")
                        .font(.subheadline)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .foregroundStyle(Color.inkSoft)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("dismiss-brain-button")
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let amount = MoneyView.currency(doc.amount ?? 0)
        if let vendor = doc.vendor, !vendor.isEmpty {
            return "\(vendor) · \(amount) · \(suggested.displayName)"
        }
        return "\(amount) · \(suggested.displayName)"
    }
}

private struct CategoryBarRow: View {
    let line: MoneyRollup.CategoryLine
    let neutralMax: Double
    /// 0…1 of the month elapsed — powers the "trending over" projection when a budget is set.
    var monthProgress: Double = 1

    private var status: BudgetStatus {
        guard let limit = line.limit else { return .under }
        return BudgetAlerts.status(spent: line.spent, limit: limit, monthProgress: monthProgress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: line.category.symbolName)
                    .foregroundStyle(line.category.tint)
                    .frame(width: 22)
                Text(line.category.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ink)
                Spacer()
                Text(MoneyView.currency(line.spent))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.ink)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.inkSoft.opacity(0.12))
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(4, geo.size.width * line.fillFraction(neutralMax: neutralMax)))
                }
            }
            .frame(height: 9)

            if let limit = line.limit {
                HStack(spacing: 5) {
                    if status == .trendingOver {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                    }
                    Text(caption(limit: limit))
                }
                .font(.caption)
                .foregroundStyle(captionColor)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("category-bar-\(line.category.rawValue)")
    }

    private var fillColor: Color {
        switch status {
        case .over: return .terracotta
        case .trendingOver: return .marigold
        case .under: return line.limit == nil ? .sage : .bacanGreen
        }
    }

    private var captionColor: Color {
        switch status {
        case .over: return .terracotta
        case .trendingOver: return .marigold
        case .under: return .inkSoft
        }
    }

    private func caption(limit: Double) -> String {
        switch status {
        case .over:
            return "over by \(MoneyView.currency(line.overBy)) · budget \(MoneyView.currency(limit))"
        case .trendingOver:
            let projected = BudgetAlerts.projected(spent: line.spent, monthProgress: monthProgress)
            return "on pace for ~\(MoneyView.currency(projected)) · budget \(MoneyView.currency(limit))"
        case .under:
            return "\(MoneyView.currency(limit - line.spent)) left of \(MoneyView.currency(limit))"
        }
    }
}

// MARK: - Budget alert row

private struct BudgetAlertRow: View {
    let alert: BudgetAlert

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: alert.category.symbolName)
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.category.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.ink)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(alert.status == .over ? "Over" : "Trending")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tint.opacity(0.16), in: Capsule())
                .foregroundStyle(tint)
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("budget-alert-\(alert.category.rawValue)")
    }

    private var tint: Color { alert.status == .over ? .terracotta : .marigold }

    private var message: String {
        if alert.status == .over {
            return "\(MoneyView.currency(alert.spent)) spent · \(MoneyView.currency(alert.overBy)) over the \(MoneyView.currency(alert.limit)) budget."
        }
        return "\(MoneyView.currency(alert.spent)) so far, on pace for ~\(MoneyView.currency(alert.projected)) vs a \(MoneyView.currency(alert.limit)) budget."
    }
}

// MARK: - Savings goal row

private struct GoalRow: View {
    let goal: SavingsGoal
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: goal.symbol ?? "banknote.fill")
                    .font(.title3)
                    .foregroundStyle(goal.isComplete ? Color.bacanGreen : Color.marigold)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
                }
                Spacer()
                Text("\(Int((goal.progress * 100).rounded()))%")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(goal.isComplete ? Color.bacanGreen : Color.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.inkSoft.opacity(0.12))
                    Capsule()
                        .fill(goal.isComplete ? Color.bacanGreen : Color.marigold)
                        .frame(width: max(4, geo.size.width * goal.progress))
                }
            }
            .frame(height: 9)
            HStack {
                Text("\(MoneyView.currency(goal.savedAmount)) of \(MoneyView.currency(goal.targetAmount))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.inkSoft)
                Spacer()
                Text(trailingCaption)
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if goal.isComplete { return "Funded — nice work!" }
        return "\(MoneyView.currency(goal.remaining)) to go"
    }

    private var subtitleColor: Color { goal.isComplete ? .bacanGreen : .inkSoft }

    private var trailingCaption: String {
        if goal.isComplete { return "Done" }
        if let eta = goal.etaDate(from: now) {
            let behind = goal.isBehindPace(now: now)
            return (behind ? "behind — " : "on pace · ") + "~\(Self.etaFormatter.string(from: eta))"
        }
        if let target = goal.targetDate {
            return "by \(Self.etaFormatter.string(from: target))"
        }
        return "no deadline"
    }

    static let etaFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MMM yyyy"
        return df
    }()
}

private struct ExpenseRow: View {
    let expense: Expense
    /// Title of the Brain document this expense was promoted from (P24 backlink), if any.
    var sourceDocTitle: String?
    /// Open the source document detail.
    var onOpenSource: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: expense.category.symbolName)
                    .foregroundStyle(expense.category.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.ink)
                    HStack(spacing: 6) {
                        Text(expense.category.displayName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(expense.category.tint.opacity(0.15), in: Capsule())
                            .foregroundStyle(expense.category.tint)
                        Text(Self.dayFormatter.string(from: expense.date))
                            .font(.caption)
                            .foregroundStyle(Color.inkSoft)
                    }
                }
                Spacer()
                Text(MoneyView.currency(expense.amount))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.ink)
            }

            if let sourceDocTitle {
                Button(action: onOpenSource) {
                    HStack(spacing: 5) {
                        Image(systemName: "brain")
                            .font(.caption2)
                        Text("From: \(sourceDocTitle)")
                            .font(.caption)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.sky)
                    .padding(.leading, 38)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("expense-source-doc")
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        if let vendor = expense.vendor, !vendor.isEmpty { return vendor }
        if let notes = expense.notes, !notes.isEmpty { return notes }
        return expense.category.displayName
    }

    static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df
    }()
}
