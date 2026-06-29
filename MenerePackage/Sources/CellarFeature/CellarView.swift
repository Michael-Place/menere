import ComposableArchitecture
import PersistenceClient
import SwiftUI
import UserDomain
import WineDomain

// MARK: - Row model

/// A single cellar entry: the owned `Bottle` joined to its catalog `Wine`, with a drink-window
/// classification computed once at load time so the view (and `visibleRows`) stay pure.
public struct CellarRow: Equatable, Identifiable, Sendable {
    public var id: String { bottle.id }
    public let bottle: Bottle
    public let wine: Wine
    public let drinkStatus: DrinkStatus

    public enum DrinkStatus: String, Equatable, Sendable {
        case hold
        case drinkNow
        case past
        case unknown
    }

    public init(bottle: Bottle, wine: Wine, drinkStatus: DrinkStatus) {
        self.bottle = bottle
        self.wine = wine
        self.drinkStatus = drinkStatus
    }

    public var producer: String { wine.producer }

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

    /// Sort key for vintage; nil vintages sort last.
    public var sortByVintage: Int { wine.vintage ?? Int.max }
}

// MARK: - Drink-window classification

/// Classify a bottle's drink window against the given current `year`.
/// - `.hold` if it isn't ready yet (now < drinkFrom)
/// - `.past` if it's over the hill (now > drinkBy)
/// - `.drinkNow` if within an available window (handles only-from / only-by)
/// - `.unknown` if no window is known
func classify(_ bottle: Bottle, year: Int) -> CellarRow.DrinkStatus {
    switch (bottle.drinkFrom, bottle.drinkBy) {
    case (nil, nil):
        return .unknown
    case let (from?, by?):
        if year < from { return .hold }
        if year > by { return .past }
        return .drinkNow
    case let (from?, nil):
        return year < from ? .hold : .drinkNow
    case let (nil, by?):
        return year > by ? .past : .drinkNow
    }
}

// MARK: - Reducer

@Reducer
public struct CellarReducer {
    @ObservableState
    public struct State: Equatable {
        public var rows: [CellarRow] = []
        public var isLoading = false
        public var loadError: String?
        public var searchText = ""
        public var statusFilter: BottleStatus? = nil   // nil = all
        public var typeFilter: WineType? = nil          // nil = all
        public var sort: SortOption = .recentlyAdded

        public enum SortOption: String, CaseIterable, Equatable, Sendable {
            case recentlyAdded
            case producer
            case vintage
            case drinkWindow
        }

        public init() {}

        /// Search + filters + sort applied in order, derived from `rows`. Keeps the view pure.
        public var visibleRows: [CellarRow] {
            var result = rows

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                result = result.filter { row in
                    var haystack: [String] = [row.wine.producer]
                    if let name = row.wine.name { haystack.append(name) }
                    if let region = row.wine.region {
                        haystack.append(contentsOf: [
                            region.country, region.region, region.subregion, region.appellation,
                        ].compactMap { $0 })
                    }
                    haystack.append(contentsOf: row.wine.grapes)
                    return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
                }
            }

            if let statusFilter {
                result = result.filter { $0.bottle.status == statusFilter }
            }

            if let typeFilter {
                result = result.filter { $0.wine.type == typeFilter }
            }

            switch sort {
            case .recentlyAdded:
                result.sort { $0.bottle.createdAt > $1.bottle.createdAt }
            case .producer:
                result.sort { lhs, rhs in
                    let p = lhs.wine.producer.localizedCaseInsensitiveCompare(rhs.wine.producer)
                    if p != .orderedSame { return p == .orderedAscending }
                    return (lhs.wine.name ?? "").localizedCaseInsensitiveCompare(rhs.wine.name ?? "") == .orderedAscending
                }
            case .vintage:
                result.sort { $0.sortByVintage < $1.sortByVintage }
            case .drinkWindow:
                result.sort { lhs, rhs in
                    let lby = lhs.bottle.drinkBy ?? Int.max
                    let rby = rhs.bottle.drinkBy ?? Int.max
                    if lby != rby { return lby < rby }
                    return (lhs.bottle.drinkFrom ?? Int.max) < (rhs.bottle.drinkFrom ?? Int.max)
                }
            }

            return result
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case loaded([CellarRow])
        case loadFailed(String)
        case binding(BindingAction<State>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                state.isLoading = true
                state.loadError = nil
                @Dependency(\.persistence) var persistence
                @Dependency(\.date) var date
                return .run { send in
                    @Shared(.user) var user
                    guard let uid = user?.id else {
                        await send(.loaded([]))
                        return
                    }
                    do {
                        let bottles = try await persistence.bottles(uid)
                        let wines = try await persistence.wines(bottles.map(\.wineId))
                        let byKey = Dictionary(uniqueKeysWithValues: wines.map { ($0.id, $0) })
                        let year = Calendar.current.component(.year, from: date.now)
                        let rows = bottles.compactMap { b -> CellarRow? in
                            guard let w = byKey[b.wineId] else { return nil }
                            return CellarRow(bottle: b, wine: w, drinkStatus: classify(b, year: year))
                        }
                        await send(.loaded(rows))
                    } catch {
                        await send(.loadFailed(error.localizedDescription))
                    }
                }

            case let .loaded(rows):
                state.isLoading = false
                state.rows = rows
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.loadError = message
                return .none

            case .binding:
                return .none
            }
        }
    }
}

// MARK: - View

public struct CellarView: View {
    @Bindable var store: StoreOf<CellarReducer>

    public init(store: StoreOf<CellarReducer>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.isLoading && store.rows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.loadError {
                ContentUnavailableView(
                    "Couldn't load your cellar",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if store.rows.isEmpty {
                ContentUnavailableView(
                    "No bottles yet",
                    systemImage: "square.stack.3d.up",
                    description: Text("Scan a wine and Add to cellar")
                )
            } else {
                List(store.visibleRows) { row in
                    CellarRowView(row: row)
                        .accessibilityIdentifier("cellar-row-\(row.id)")
                }
            }
        }
        .navigationTitle("Cellar")
        .searchable(text: $store.searchText)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $store.sort) {
                        ForEach(CellarReducer.State.SortOption.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    Picker("Status", selection: $store.statusFilter) {
                        Text("All").tag(BottleStatus?.none)
                        ForEach(BottleStatus.allCases, id: \.self) { status in
                            Text(status.rawValue.capitalized).tag(BottleStatus?.some(status))
                        }
                    }
                    Picker("Type", selection: $store.typeFilter) {
                        Text("All").tag(WineType?.none)
                        ForEach(WineType.allCases, id: \.self) { type in
                            Text(type.rawValue.capitalized).tag(WineType?.some(type))
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("cellar-filter-menu")
            }
        }
        .task { store.send(.task) }
    }
}

private struct CellarRowView: View {
    let row: CellarRow

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

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(row.bottle.status.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())

                if let window = row.drinkWindowText {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 8, height: 8)
                        Text(window)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let name = row.wine.name, !name.isEmpty { parts.append(name) }
        if let vintage = row.wine.vintage { parts.append(String(vintage)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var dotColor: Color {
        switch row.drinkStatus {
        case .drinkNow: .green
        case .hold: .orange
        case .past: .red
        case .unknown: .gray
        }
    }
}

private extension CellarReducer.State.SortOption {
    var label: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .producer: "Producer"
        case .vintage: "Vintage"
        case .drinkWindow: "Drink Window"
        }
    }
}
