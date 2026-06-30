import BottleCardFeature
import ComposableArchitecture
import JournalFeature
import PersistenceClient
import SwiftUI
import UserDomain
import WineDomain

// MARK: - Row models

/// A cellared bottle joined to its catalog `Wine`, surfaced in the "Drink soon" section.
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

/// A tasting joined to its catalog `Wine`, surfaced in the "Recent tastings" section.
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

/// The fully-computed Home dashboard, built once in the load effect so the view stays pure.
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
private func isDrinkNow(_ bottle: Bottle, year: Int) -> Bool {
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

// MARK: - Reducer

@Reducer
public struct HomeReducer {
    /// Push destinations from the dashboard.
    @Reducer(state: .equatable, action: .equatable)
    public enum Destination {
        case wineDetail(BottleCardFeature)
        case tastingDetail(TastingDetailReducer)
    }

    @ObservableState
    public struct State: Equatable {
        @Presents public var destination: Destination.State?
        public var data: DashboardData = .empty
        public var isLoading = false
        public var loadError: String?
        public init() {}
    }

    public enum Action: Equatable {
        case task
        case loaded(DashboardData)
        case loadFailed(String)
        case drinkSoonRowTapped(HomeBottleRow)
        case recentTastingRowTapped(HomeTastingRow)
        case destination(PresentationAction<Destination.Action>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                state.isLoading = true
                state.loadError = nil
                @Dependency(\.persistence) var persistence
                @Dependency(\.date) var date
                return .run { send in
                    @Shared(.user) var user
                    guard let hid = user?.householdId else {
                        await send(.loaded(.empty))
                        return
                    }
                    do {
                        let bottles = try await persistence.bottles(hid)
                        let tastings = try await persistence.tastings(hid)
                        let keys = Set(bottles.map(\.wineId) + tastings.map(\.wineId))
                        let wines = try await persistence.wines(Array(keys))
                        let byKey = Dictionary(uniqueKeysWithValues: wines.map { ($0.id, $0) })
                        let year = Calendar.current.component(.year, from: date.now)

                        let cellared = bottles.filter { $0.status == .cellared }
                        let cellaredBottleCount = cellared.reduce(0) { $0 + $1.quantity }
                        let distinctWineCount = Set(cellared.map(\.wineId)).count
                        let wishlistCount = bottles.filter { $0.status == .wishlist }.count
                        let tastingCount = tastings.count

                        let drinkSoon = cellared
                            .filter { isDrinkNow($0, year: year) && byKey[$0.wineId] != nil }
                            .sorted { ($0.drinkBy ?? .max) < ($1.drinkBy ?? .max) }
                            .prefix(5)
                            .map { HomeBottleRow(bottle: $0, wine: byKey[$0.wineId]!) }

                        let recentTastings = tastings
                            .filter { byKey[$0.wineId] != nil }
                            .sorted { $0.date > $1.date }
                            .prefix(5)
                            .map { HomeTastingRow(tasting: $0, wine: byKey[$0.wineId]!) }

                        let data = DashboardData(
                            cellaredBottleCount: cellaredBottleCount,
                            distinctWineCount: distinctWineCount,
                            wishlistCount: wishlistCount,
                            tastingCount: tastingCount,
                            drinkSoon: Array(drinkSoon),
                            recentTastings: Array(recentTastings)
                        )
                        await send(.loaded(data))
                    } catch {
                        await send(.loadFailed(error.localizedDescription))
                    }
                }

            case let .loaded(data):
                state.isLoading = false
                state.data = data
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.loadError = message
                return .none

            case let .drinkSoonRowTapped(row):
                state.destination = .wineDetail(
                    BottleCardFeature.State(wine: row.wine, ownedBottle: row.bottle)
                )
                return .none

            case let .recentTastingRowTapped(row):
                state.destination = .tastingDetail(
                    TastingDetailReducer.State(tasting: row.tasting, wine: row.wine)
                )
                return .none

            case let .destination(.presented(.wineDetail(.delegate(.bottleDeleted(id))))):
                state.destination = nil
                return deleteBottleAndReload(id)

            case .destination(.presented(.wineDetail(.delegate(.bottleUpdated)))):
                state.destination = nil
                return .send(.task)

            case let .destination(.presented(.tastingDetail(.delegate(.tastingDeleted(id))))):
                state.destination = nil
                return deleteTastingAndReload(id)

            case .destination(.presented(.tastingDetail(.delegate(.tastingUpdated)))):
                state.destination = nil
                return .send(.task)

            case .destination:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }
}

// MARK: - Mutation + reload helpers

/// Delete a bottle from the household then reload the dashboard (re-send `.task`). Shared by the
/// detail screen's delegate and (later, UX2b) the Home swipe action. On delete error, surfaces
/// `.loadFailed`. Reading `@Shared(.user)` here mirrors the `.task` load effect.
func deleteBottleAndReload(_ id: String) -> Effect<HomeReducer.Action> {
    @Dependency(\.persistence) var persistence
    return .run { send in
        @Shared(.user) var user
        if let hid = user?.householdId {
            do {
                try await persistence.deleteBottle(hid, id)
            } catch {
                await send(.loadFailed(error.localizedDescription))
                return
            }
        }
        await send(.task)
    }
}

/// Delete a tasting from the household then reload (re-send `.task`). Shared by the detail screen's
/// delegate and (later, UX2b) a Home swipe action.
func deleteTastingAndReload(_ id: String) -> Effect<HomeReducer.Action> {
    @Dependency(\.persistence) var persistence
    return .run { send in
        @Shared(.user) var user
        if let hid = user?.householdId {
            do {
                try await persistence.deleteTasting(hid, id)
            } catch {
                await send(.loadFailed(error.localizedDescription))
                return
            }
        }
        await send(.task)
    }
}

// MARK: - View

public struct HomeView: View {
    @Bindable var store: StoreOf<HomeReducer>

    public init(store: StoreOf<HomeReducer>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.isLoading && store.data == .empty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.loadError {
                ContentUnavailableView {
                    Label("Couldn't load your dashboard", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { store.send(.task) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("home-error-retry")
                }
                .accessibilityIdentifier("home-error")
            } else if store.data.isEmpty {
                ContentUnavailableView(
                    "Your cellar is empty",
                    systemImage: "wineglass",
                    description: Text("Scan a bottle to start your cellar.")
                )
            } else {
                dashboard
            }
        }
        .navigationTitle("Home")
        .task { store.send(.task) }
        .navigationDestination(
            item: $store.scope(state: \.destination?.wineDetail, action: \.destination.wineDetail)
        ) { detailStore in
            BottleCardView(store: detailStore)
        }
        .navigationDestination(
            item: $store.scope(state: \.destination?.tastingDetail, action: \.destination.tastingDetail)
        ) { detailStore in
            TastingDetailView(store: detailStore)
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statTiles
                drinkSoonSection
                recentTastingsSection
            }
            .padding()
        }
    }

    // MARK: Stat tiles

    private var statTiles: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                value: store.data.cellaredBottleCount,
                caption: "Cellared",
                systemImage: "square.stack.3d.up"
            )
            .accessibilityIdentifier("home-stat-cellared")
            StatTile(
                value: store.data.distinctWineCount,
                caption: "Wines",
                systemImage: "drop"
            )
            .accessibilityIdentifier("home-stat-wines")
            StatTile(
                value: store.data.tastingCount,
                caption: "Tastings",
                systemImage: "wineglass"
            )
            .accessibilityIdentifier("home-stat-tastings")
            StatTile(
                value: store.data.wishlistCount,
                caption: "Wishlist",
                systemImage: "heart"
            )
            .accessibilityIdentifier("home-stat-wishlist")
        }
    }

    // MARK: Drink soon

    private var drinkSoonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Drink soon")
            if store.data.drinkSoon.isEmpty {
                EmptyHint(text: "Nothing in its window right now.")
            } else {
                VStack(spacing: 8) {
                    ForEach(store.data.drinkSoon) { row in
                        Button {
                            store.send(.drinkSoonRowTapped(row))
                        } label: {
                            DrinkSoonRowView(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .accessibilityIdentifier("home-drink-soon")
    }

    // MARK: Recent tastings

    private var recentTastingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recent tastings")
            if store.data.recentTastings.isEmpty {
                EmptyHint(text: "Log a tasting to see it here.")
            } else {
                VStack(spacing: 8) {
                    ForEach(store.data.recentTastings) { row in
                        Button {
                            store.send(.recentTastingRowTapped(row))
                        } label: {
                            RecentTastingRowView(row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .accessibilityIdentifier("home-recent-tastings")
    }
}

// MARK: - Subviews

private struct StatTile: View {
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

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title3.bold())
    }
}

private struct EmptyHint: View {
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

private struct DrinkSoonRowView: View {
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

private struct RecentTastingRowView: View {
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
