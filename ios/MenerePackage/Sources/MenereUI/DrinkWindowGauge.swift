import SwiftUI

/// A living drink-window gauge: a horizontal capacity bar showing where "now" sits between a wine's
/// `from` and `by` drinking years, tinted + captioned by status (Hold / In its window / Drink soon /
/// Past its best).
///
/// Pure inputs (`Int` years + the current year) so it has no domain dependency — D3 can reuse it on
/// cellar rows. The status thresholds mirror `CellarFeature.classify(_:year:)`.
public struct DrinkWindowGauge: View {
    /// Where "now" falls relative to the window. Sage = drink, Slate = hold, Faded rose = past.
    public enum Status: Equatable, Sendable {
        case hold       // not ready yet (now < from)
        case drinkNow   // comfortably inside the window
        case drinkSoon  // inside, but near the end
        case past       // over the hill (now > by)

        /// Brand semantic tint.
        public var tint: Color {
            switch self {
            case .hold: return .hold
            case .drinkNow, .drinkSoon: return .drinkNow
            case .past: return .past
            }
        }

        /// Brand-voice caption.
        public var voice: String {
            switch self {
            case .hold: return "Hold a while"
            case .drinkNow: return "In its window"
            case .drinkSoon: return "Drink soon"
            case .past: return "Past its best"
            }
        }
    }

    let from: Int
    let by: Int
    let currentYear: Int

    public init(from: Int, by: Int, currentYear: Int) {
        self.from = from
        self.by = by
        self.currentYear = currentYear
    }

    /// Status of `currentYear` against the window. Treats the final ~20% of the span as "drink soon".
    public var status: Status {
        if currentYear < from { return .hold }
        if currentYear > by { return .past }
        let span = max(by - from, 1)
        let remaining = by - currentYear
        return Double(remaining) <= Double(span) * 0.2 ? .drinkSoon : .drinkNow
    }

    /// `currentYear` clamped into the gauge range so the needle never overflows the bar.
    private var clampedYear: Double {
        Double(min(max(currentYear, from), by))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Drink window", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleOnly)
                Spacer(minLength: 8)
                Text(status.voice)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.tint)
                    .contentTransition(.opacity)
            }
            if by > from {
                Gauge(value: clampedYear, in: Double(from)...Double(by)) {
                    Text("Drink window")
                } currentValueLabel: {
                    Text(String(currentYear)).monospacedDigit()
                } minimumValueLabel: {
                    Text(String(from)).font(.caption2).monospacedDigit()
                } maximumValueLabel: {
                    Text(String(by)).font(.caption2).monospacedDigit()
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(status.tint)
                .animation(.menereSnappy, value: clampedYear)
            } else {
                // Degenerate / single-year window — no meaningful range to plot.
                Text("\(from)–\(by)")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drink window \(from) to \(by). \(status.voice).")
    }
}

#if DEBUG
#Preview("Drink window — states") {
    VStack(spacing: 28) {
        DrinkWindowGauge(from: 2030, by: 2040, currentYear: 2026)   // hold
        DrinkWindowGauge(from: 2022, by: 2032, currentYear: 2026)   // in its window
        DrinkWindowGauge(from: 2020, by: 2027, currentYear: 2026)   // drink soon
        DrinkWindowGauge(from: 2010, by: 2020, currentYear: 2026)   // past
    }
    .padding()
    .background(Color.familyCanvas)
}
#endif
