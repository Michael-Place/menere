import ComposableArchitecture
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
            insightsSection
            if !store.inboxDocuments.isEmpty { inboxSection }
            categoryBarsSection
            ledgerSection
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
        .sheet(isPresented: $store.showInsights) {
            SpendingInsightsView(store: store)
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
                ForEach(store.summary.lines) { line in
                    CategoryBarRow(line: line, neutralMax: neutralMax)
                }
            }
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
                    ExpenseRow(expense: expense)
                }
                .onDelete { store.send(.deleteExpenses($0)) }
            }
        }
        .listRowBackground(Color.familySurface)
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
                Text(caption(limit: limit))
                    .font(.caption)
                    .foregroundStyle(line.isOverBudget ? Color.terracotta : Color.inkSoft)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("category-bar-\(line.category.rawValue)")
    }

    private var fillColor: Color {
        if line.limit == nil { return .sage }
        return line.isOverBudget ? .terracotta : .bacanGreen
    }

    private func caption(limit: Double) -> String {
        if line.isOverBudget {
            return "over by \(MoneyView.currency(line.overBy)) · budget \(MoneyView.currency(limit))"
        }
        return "\(MoneyView.currency(limit - line.spent)) left of \(MoneyView.currency(limit))"
    }
}

private struct ExpenseRow: View {
    let expense: Expense

    var body: some View {
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
