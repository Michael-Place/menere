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

    public init(
        cellaredBottleCount: Int = 0,
        distinctWineCount: Int = 0,
        wishlistCount: Int = 0,
        tastingCount: Int = 0,
        drinkSoon: [HomeBottleRow] = [],
        recentTastings: [HomeTastingRow] = []
    ) {
        self.cellaredBottleCount = cellaredBottleCount
        self.distinctWineCount = distinctWineCount
        self.wishlistCount = wishlistCount
        self.tastingCount = tastingCount
        self.drinkSoon = drinkSoon
        self.recentTastings = recentTastings
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
            Text("\(value)")
                .font(.largeTitle.bold().monospacedDigit())
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
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
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DrinkSoonRowView: View {
    let row: HomeBottleRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.producer)
                    .font(.headline)
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
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(window)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("home-drink-soon-row-\(row.id)")
    }
}

struct RecentTastingRowView: View {
    let row: HomeTastingRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.producer)
                    .font(.headline)
                Spacer()
                Text(row.ratingText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(row.dateText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("home-recent-tastings-row-\(row.id)")
    }
}
