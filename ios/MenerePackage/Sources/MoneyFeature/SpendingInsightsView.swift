import ComposableArchitecture
import FamilyDomain
import Foundation
import MenereUI
import SwiftUI

/// P22 — Spending intelligence. A warm, familyCanvas read on where the money goes: an AI "in a
/// nutshell" recap, this-month category breakdown + month-over-month trend, recurring-vendor
/// detection, a one-time/housing callout (so a $41k closing disclosure never skews the month), and a
/// seasonal garden hint where obvious. Reads the pure `SpendingInsights.Report` off the Money store.
struct SpendingInsightsView: View {
    @Bindable var store: StoreOf<MoneyReducer>

    private var report: SpendingInsights.Report { store.report }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    summaryCard
                    if report.isEmptyMonth && report.oneTimeTotal == 0 {
                        emptyState
                    } else {
                        breakdownCard
                        if !report.recurring.isEmpty { recurringCard }
                        if let hint = report.seasonalHint { seasonalCard(hint) }
                        if report.oneTimeTotal > 0 { oneTimeCard }
                        if report.allTimeTotal > 0 { allTimeCard }
                    }
                }
                .padding(16)
            }
            .background(Color.familyCanvas)
            .navigationTitle("Spending insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.showInsights = false }
                        .foregroundStyle(Color.bacanGreen)
                        .accessibilityIdentifier("insights-done-button")
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: AI "in a nutshell" card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("This month, in a nutshell", systemImage: "sparkles")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.bacanGreen)
                Spacer()
                Button { store.send(.refreshSummaryTapped) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.inkSoft)
                }
                .buttonStyle(.pressable)
                .disabled(store.isSummarizing)
                .accessibilityIdentifier("refresh-summary-button")
            }

            if store.isSummarizing && store.spendingSummary == nil {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.inkSoft.opacity(0.18))
                            .frame(height: 12)
                    }
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.inkSoft.opacity(0.18))
                        .frame(width: 160, height: 12)
                }
                .shimmering()
                .accessibilityIdentifier("summary-shimmer")
            } else if let summary = store.spendingSummary {
                Text(summary.summary)
                    .font(.callout)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !summary.insight.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .font(.caption)
                            .foregroundStyle(Color.marigold)
                            .padding(.top, 2)
                        Text(summary.insight)
                            .font(.footnote)
                            .foregroundStyle(Color.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.marigold.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
            } else {
                Text("Tap refresh for a quick recap of where the money went.")
                    .font(.callout)
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .cardChrome()
    }

    // MARK: This-month breakdown + trend

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Where it went")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.ink)
                    Text(MoneyView.monthTitle(store.monthAnchor))
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                }
                Spacer()
                trendChip
            }

            Text(MoneyView.currency(report.total))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ink)

            if report.breakdown.isEmpty {
                Text("Nothing categorized this month yet.")
                    .font(.callout)
                    .foregroundStyle(Color.inkSoft)
            } else {
                ForEach(report.breakdown) { slice in
                    BreakdownBar(slice: slice)
                }
            }
        }
        .cardChrome()
    }

    @ViewBuilder private var trendChip: some View {
        let trend = report.trend
        if trend.hasComparison, trend.isUp || trend.isDown {
            let up = trend.isUp
            HStack(spacing: 4) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.bold))
                Text(MoneyView.currency(abs(trend.delta)))
                    .font(.caption.weight(.semibold).monospacedDigit())
                if let frac = trend.fraction {
                    Text("(\(Self.percent(abs(frac))))")
                        .font(.caption2)
                }
            }
            .foregroundStyle(up ? Color.terracotta : Color.bacanGreen)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background((up ? Color.terracotta : Color.bacanGreen).opacity(0.14), in: Capsule())
        } else if !report.isEmptyMonth {
            Text("vs. last month: no prior spend")
                .font(.caption2)
                .foregroundStyle(Color.inkSoft)
        }
    }

    // MARK: Recurring

    private var recurringCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Looks recurring", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.ink)
            Text("Vendors we've seen in more than one month.")
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
            ForEach(report.recurring) { vendor in
                HStack(spacing: 10) {
                    Image(systemName: vendor.category.symbolName)
                        .foregroundStyle(vendor.category.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vendor.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.ink)
                        Text("\(vendor.monthCount) months · \(vendor.category.displayName)")
                            .font(.caption)
                            .foregroundStyle(Color.inkSoft)
                    }
                    Spacer()
                    Text("~\(MoneyView.currency(vendor.averageAmount))/mo")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.ink)
                }
                .padding(.vertical, 2)
                .accessibilityIdentifier("recurring-\(vendor.id)")
            }
        }
        .cardChrome()
    }

    // MARK: Seasonal

    private func seasonalCard(_ hint: SpendingInsights.SeasonalHint) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "leaf.fill")
                .foregroundStyle(Color.sage)
            Text("This \(hint.season), about \(MoneyView.currency(hint.amount)) has gone into the \(hint.category.displayName.lowercased()).")
                .font(.callout)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .cardChrome()
    }

    // MARK: One-time / Housing

    private var oneTimeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("One-time & housing", systemImage: "house.lodge.fill")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.ink)
                Spacer()
                Text(MoneyView.currency(report.oneTimeTotal))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.inkSoft)
            }
            Text("Big one-offs, kept out of the monthly trend.")
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
            ForEach(report.oneTimeLines) { line in
                HStack(spacing: 10) {
                    Text(line.vendor ?? line.category.displayName)
                        .font(.subheadline)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(MoneyView.currency(line.amount))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.ink)
                }
                .padding(.vertical, 1)
            }
        }
        .cardChrome()
    }

    // MARK: All-time

    private var allTimeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("All-time by category")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.ink)
                Spacer()
                Text(MoneyView.currency(report.allTimeTotal))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.inkSoft)
            }
            Text("Everything logged so far, one-offs excluded.")
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
            ForEach(report.allTimeByCategory) { slice in
                BreakdownBar(slice: slice)
            }
        }
        .cardChrome()
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.pie")
                .font(.largeTitle)
                .foregroundStyle(Color.sage)
            Text("No spending yet this month")
                .font(.headline)
                .foregroundStyle(Color.ink)
            Text("Jot a spend or file a receipt from the Brain, and the picture fills in here.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .cardChrome()
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

// MARK: - Bar

private struct BreakdownBar: View {
    let slice: SpendingInsights.CategoryBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: slice.category.symbolName)
                    .foregroundStyle(slice.category.tint)
                    .frame(width: 22)
                Text(slice.category.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ink)
                Spacer()
                Text(MoneyView.currency(slice.amount))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.ink)
                Text("\(Int((slice.fraction * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.inkSoft)
                    .frame(width: 34, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.inkSoft.opacity(0.12))
                    Capsule()
                        .fill(slice.category.tint)
                        .frame(width: max(4, geo.size.width * slice.fraction))
                }
            }
            .frame(height: 8)
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("breakdown-\(slice.category.rawValue)")
    }
}

// MARK: - Chrome

private extension View {
    /// A soft familySurface card — the insights screen's building block.
    func cardChrome() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 18))
    }
}
