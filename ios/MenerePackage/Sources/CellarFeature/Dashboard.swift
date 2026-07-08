import MenereUI
import SwiftUI
import WineDomain

// MARK: - Row models

/// A cellared bottle joined to its catalog `Wine`, surfaced in the dashboard's "Drink soon" section.
public struct HomeBottleRow: Equatable, Identifiable, Sendable {
    public var id: String { bottle.id }
    public let bottle: Bottle
    public let wine: Wine

    public init(bottle: Bottle, wine: Wine) {
        self.bottle = bottle
        self.wine = wine
    }

    public var producer: String { wine.producer }

    /// Cuvée name and/or vintage, e.g. "Clos du Marquis · 2018", "2018", or nil.
    public var nameVintage: String? {
        var parts: [String] = []
        if let name = wine.name, !name.isEmpty { parts.append(name) }
        if let vintage = wine.vintage { parts.append(String(vintage)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Human-facing drink window: prefer the enriched string, else format the bottle's year range.
    public var drinkWindowText: String? {
        if let window = wine.enrichment?.drinkingWindow, !window.isEmpty { return window }
        switch (bottle.drinkFrom, bottle.drinkBy) {
        case let (from?, by?): return "\(from)–\(by)"
        case let (from?, nil): return "From \(from)"
        case let (nil, by?): return "By \(by)"
        case (nil, nil): return nil
        }
    }
}

/// A tasting joined to its catalog `Wine`, surfaced in the dashboard's "Recent tastings" section.
public struct HomeTastingRow: Equatable, Identifiable, Sendable {
    public var id: String { tasting.id }
    public let tasting: Tasting
    public let wine: Wine

    public init(tasting: Tasting, wine: Wine) {
        self.tasting = tasting
        self.wine = wine
    }

    public var producer: String { wine.producer }

    /// Human-facing rating: prefer stars, then 100-point score, else em dash.
    public var ratingText: String {
        if let stars = tasting.ratingStars {
            let trimmed = stars.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(stars))
                : String(stars)
            return "★ \(trimmed)"
        }
        if let pts = tasting.rating100 { return "\(pts) pts" }
        return "—"
    }

    public var dateText: String {
        HomeTastingRow.dateFormatter.string(from: tasting.date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

// MARK: - Dashboard data

/// One slice of the cellar-composition chart: a wine `type` and how many cellared bottles share it.
/// `count` follows the same qty-summed convention as `cellaredBottleCount`.
public struct TypeSlice: Equatable, Sendable, Identifiable {
    public var id: WineType { type }
    public let type: WineType
    public let count: Int

    public init(type: WineType, count: Int) {
        self.type = type
        self.count = count
    }
}

/// The fully-computed dashboard, built once in the load effect so the view stays pure.
public struct DashboardData: Equatable, Sendable {
    /// Sum of `quantity` over bottles with status `.cellared`.
    public var cellaredBottleCount: Int
    /// Distinct `wineId`s across cellared bottles.
    public var distinctWineCount: Int
    /// Count of bottles with status `.wishlist`.
    public var wishlistCount: Int
    /// Total number of tastings.
    public var tastingCount: Int
    /// Cellared, "drink now" bottles, sorted by `drinkBy` ascending (nil last), capped at 5.
    public var drinkSoon: [HomeBottleRow]
    /// Tastings sorted by date descending, capped at 5.
    public var recentTastings: [HomeTastingRow]
    /// Cellared bottles bucketed by wine `type` (qty-summed), sorted by count descending, zeros
    /// dropped. Bottles whose wine is missing from the catalog join are skipped.
    public var typeBreakdown: [TypeSlice]

    public init(
        cellaredBottleCount: Int = 0,
        distinctWineCount: Int = 0,
        wishlistCount: Int = 0,
        tastingCount: Int = 0,
        drinkSoon: [HomeBottleRow] = [],
        recentTastings: [HomeTastingRow] = [],
        typeBreakdown: [TypeSlice] = []
    ) {
        self.cellaredBottleCount = cellaredBottleCount
        self.distinctWineCount = distinctWineCount
        self.wishlistCount = wishlistCount
        self.tastingCount = tastingCount
        self.drinkSoon = drinkSoon
        self.recentTastings = recentTastings
        self.typeBreakdown = typeBreakdown
    }

    public static let empty = DashboardData()

    /// True when there's nothing at all to show.
    public var isEmpty: Bool {
        cellaredBottleCount == 0
            && wishlistCount == 0
            && tastingCount == 0
            && drinkSoon.isEmpty
            && recentTastings.isEmpty
    }
}

// MARK: - Drink-window classification

/// Whether a bottle is in its "drink now" window for the given current `year`.
/// Handles only-from / only-by; both-nil = false (unknown, not drink-now).
func isDrinkNow(_ bottle: Bottle, year: Int) -> Bool {
    switch (bottle.drinkFrom, bottle.drinkBy) {
    case (nil, nil):
        return false
    case let (from?, by?):
        return year >= from && year <= by
    case let (from?, nil):
        return year >= from
    case let (nil, by?):
        return year <= by
    }
}

// MARK: - Dashboard subviews

struct StatTile: View {
    let value: Int
    let caption: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, value: value)
            Text("\(value)")
                .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.menereSnappy, value: value)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .dashboardCard()
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title3.bold())
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct DrinkSoonRowView: View {
    let row: HomeBottleRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.producer)
                    .wineName(.subheadline)
                Spacer()
                Text("×\(row.bottle.quantity)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let nameVintage = row.nameVintage {
                Text(nameVintage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let window = row.drinkWindowText {
                HStack(spacing: 4) {
                    Circle().fill(Color.drinkNow).frame(width: 8, height: 8)
                    Text(window)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .dashboardCard()
        .accessibilityIdentifier("home-drink-soon-row-\(row.id)")
    }
}

struct RecentTastingRowView: View {
    let row: HomeTastingRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.producer)
                    .wineName(.subheadline)
                Spacer()
                Text(row.ratingText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(row.dateText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .dashboardCard()
        .accessibilityIdentifier("home-recent-tastings-row-\(row.id)")
    }
}

/// Compact "what's in my cellar" breakdown: a horizontal `BarMark` per wine type, brand-tinted,
/// with the bottle count annotated at the bar's trailing edge. Bars settle in count-descending
/// order (largest on top). The caller hides this entirely when `slices` is empty.
struct CellarCompositionChart: View {
    let slices: [TypeSlice]

    private var maxCount: Int { max(1, slices.map(\.count).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "By type")
            ForEach(slices) { slice in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(slice.type.displayName)
                            .font(.caption)
                            .foregroundStyle(Color.inkSoft)
                        Spacer()
                        Text("\(slice.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.inkSoft)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.inkSoft.opacity(0.12))
                            Capsule()
                                .fill(slice.type.chartColor)
                                .frame(width: max(8, geo.size.width * (Double(slice.count) / Double(maxCount))))
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
        .dashboardCard()
        .accessibilityIdentifier("home-cellar-composition")
    }
}

private extension View {
    /// Unified dashboard card surface: a `familySurface` card with a soft shadow so tiles read as
    /// raised surfaces against the cream canvas — the same card chrome the rest of Bacán uses. (The
    /// old `secondarySystemBackground` was the same grey as the list, so the cards were invisible and
    /// content looked like floating text.)
    func dashboardCard() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.ink.opacity(0.06), radius: 7, y: 3)
    }
}

private extension WineType {
    /// Display label for the composition chart (rosé keeps its accent).
    var displayName: String {
        switch self {
        case .red: "Red"
        case .white: "White"
        case .rose: "Rosé"
        case .sparkling: "Sparkling"
        case .dessert: "Dessert"
        case .fortified: "Fortified"
        case .other: "Other"
        }
    }

    /// Brand-token tint per type, drawn from the same palette as `WineTypeGradient`.
    var chartColor: Color {
        switch self {
        case .red: .wine
        case .white: .candleGold
        case .rose: .past
        case .sparkling: .candleGold.opacity(0.55)
        case .dessert: .oxblood
        case .fortified: .oxblood.opacity(0.7)
        case .other: .inkSoft
        }
    }
}
