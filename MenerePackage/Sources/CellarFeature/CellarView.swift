import BottleCardFeature
import ComposableArchitecture
import JournalFeature
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

// MARK: - Tasting row model

/// A single tasting-history entry: the private `Tasting` joined to its catalog `Wine`. Built once at
/// load time so the view (and `visibleTastingRows`) stay pure.
public struct TastingRow: Equatable, Identifiable, Sendable {
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
        TastingRow.dateFormatter.string(from: tasting.date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
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
    /// Push destinations from the cellar.
    @Reducer(state: .equatable, action: .equatable)
    public enum Destination {
        case wineDetail(BottleCardFeature)
        case tastingDetail(TastingDetailReducer)
    }

    @ObservableState
    public struct State: Equatable {
        @Presents public var destination: Destination.State?
        public var rows: [CellarRow] = []
        public var isLoading = false
        public var loadError: String?
        public var searchText = ""
        public var statusFilter: BottleStatus? = nil   // nil = all
        public var typeFilter: WineType? = nil          // nil = all
        public var sort: SortOption = .recentlyAdded

        // History segment
        public var segment: Segment = .cellar
        public var tastingRows: [TastingRow] = []
        public var minRating: Double? = nil             // e.g. 4.0 = "4★+"; nil = any
        public var grapeFilter: String? = nil           // nil = all grapes
        public var historySort: HistorySort = .dateNewest

        public enum Segment: String, CaseIterable, Equatable, Sendable {
            case cellar
            case history
        }

        public enum SortOption: String, CaseIterable, Equatable, Sendable {
            case recentlyAdded
            case producer
            case vintage
            case drinkWindow
        }

        public enum HistorySort: String, CaseIterable, Equatable, Sendable {
            case dateNewest
            case dateOldest
            case ratingHigh
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

        /// Sorted unique grapes across all tasting rows (for the grape Picker).
        public var availableGrapes: [String] {
            Array(Set(tastingRows.flatMap { $0.wine.grapes }))
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        /// Search + history filters + sort applied in order, derived from `tastingRows`.
        public var visibleTastingRows: [TastingRow] {
            var result = tastingRows

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
                    if let note = row.tasting.note { haystack.append(note) }
                    if let withWhom = row.tasting.withWhom { haystack.append(withWhom) }
                    if let occasion = row.tasting.occasion { haystack.append(occasion) }
                    return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
                }
            }

            if let minRating {
                result = result.filter {
                    guard let stars = $0.tasting.ratingStars else { return false }
                    return stars >= minRating
                }
            }

            if let grapeFilter {
                result = result.filter { $0.wine.grapes.contains(grapeFilter) }
            }

            switch historySort {
            case .dateNewest:
                result.sort { $0.tasting.date > $1.tasting.date }
            case .dateOldest:
                result.sort { $0.tasting.date < $1.tasting.date }
            case .ratingHigh:
                result.sort { lhs, rhs in
                    let l = lhs.tasting.ratingStars ?? -1
                    let r = rhs.tasting.ratingStars ?? -1
                    if l != r { return l > r }
                    return lhs.tasting.date > rhs.tasting.date
                }
            }

            return result
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case loaded([CellarRow])
        case tastingsLoaded([TastingRow])
        case loadFailed(String)
        case wineRowTapped(CellarRow)
        case tastingRowTapped(TastingRow)
        case destination(PresentationAction<Destination.Action>)
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
                    guard let hid = user?.householdId else {
                        await send(.loaded([]))
                        await send(.tastingsLoaded([]))
                        return
                    }
                    do {
                        let bottles = try await persistence.bottles(hid)
                        let tastings = try await persistence.tastings(hid)
                        // Union the wine ids needed by both lists into one batch fetch.
                        let wineIds = Array(Set(bottles.map(\.wineId) + tastings.map(\.wineId)))
                        let wines = try await persistence.wines(wineIds)
                        let byKey = Dictionary(uniqueKeysWithValues: wines.map { ($0.id, $0) })
                        let year = Calendar.current.component(.year, from: date.now)
                        let cellarRows = bottles.compactMap { b -> CellarRow? in
                            guard let w = byKey[b.wineId] else { return nil }
                            return CellarRow(bottle: b, wine: w, drinkStatus: classify(b, year: year))
                        }
                        let tastingRows = tastings.compactMap { t -> TastingRow? in
                            guard let w = byKey[t.wineId] else { return nil }
                            return TastingRow(tasting: t, wine: w)
                        }
                        await send(.loaded(cellarRows))
                        await send(.tastingsLoaded(tastingRows))
                    } catch {
                        await send(.loadFailed(error.localizedDescription))
                    }
                }

            case let .loaded(rows):
                state.isLoading = false
                state.rows = rows
                return .none

            case let .tastingsLoaded(rows):
                state.tastingRows = rows
                return .none

            case let .loadFailed(message):
                state.isLoading = false
                state.loadError = message
                return .none

            case let .wineRowTapped(row):
                state.destination = .wineDetail(
                    BottleCardFeature.State(wine: row.wine, ownedBottle: row.bottle)
                )
                return .none

            case let .tastingRowTapped(row):
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

            case .binding:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }
}

// MARK: - Mutation + reload helpers

/// Delete a bottle from the household then reload the cellar (re-send `.task`). Shared by the detail
/// screen's delegate and (later, UX2b) the Cellar swipe action. On delete error, surfaces
/// `.loadFailed`. Reading `@Shared(.user)` here mirrors the `.task` load effect.
func deleteBottleAndReload(_ id: String) -> Effect<CellarReducer.Action> {
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
/// delegate and (later, UX2b) the History swipe action.
func deleteTastingAndReload(_ id: String) -> Effect<CellarReducer.Action> {
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

public struct CellarView: View {
    @Bindable var store: StoreOf<CellarReducer>

    public init(store: StoreOf<CellarReducer>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $store.segment) {
                ForEach(CellarReducer.State.Segment.allCases, id: \.self) { segment in
                    Text(segment.label).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityIdentifier("cellar-segment")

            switch store.segment {
            case .cellar:
                cellarContent
            case .history:
                historyContent
            }
        }
        .navigationTitle(store.segment == .history ? "History" : "Cellar")
        .searchable(text: $store.searchText)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                switch store.segment {
                case .cellar:
                    cellarFilterMenu
                case .history:
                    historyFilterMenu
                }
            }
        }
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

    // MARK: Cellar segment

    @ViewBuilder
    private var cellarContent: some View {
        if store.isLoading && store.rows.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.loadError {
            ContentUnavailableView {
                Label("Couldn't load your cellar", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { store.send(.task) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("cellar-error-retry")
            }
            .accessibilityIdentifier("cellar-error")
        } else if store.rows.isEmpty {
            ContentUnavailableView(
                "No bottles yet",
                systemImage: "square.stack.3d.up",
                description: Text("Scan a wine and Add to cellar")
            )
        } else {
            List(store.visibleRows) { row in
                Button {
                    store.send(.wineRowTapped(row))
                } label: {
                    CellarRowView(row: row)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cellar-row-\(row.id)")
            }
        }
    }

    private var cellarFilterMenu: some View {
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

    // MARK: History segment

    @ViewBuilder
    private var historyContent: some View {
        if store.isLoading && store.tastingRows.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.loadError {
            ContentUnavailableView {
                Label("Couldn't load your history", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { store.send(.task) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("cellar-history-error-retry")
            }
            .accessibilityIdentifier("cellar-history-error")
        } else if store.tastingRows.isEmpty {
            ContentUnavailableView(
                "No tastings yet",
                systemImage: "wineglass",
                description: Text("Log one from a bottle card")
            )
        } else {
            List(store.visibleTastingRows) { row in
                Button {
                    store.send(.tastingRowTapped(row))
                } label: {
                    TastingRowView(row: row)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history-row-\(row.id)")
            }
        }
    }

    private var historyFilterMenu: some View {
        Menu {
            Picker("Min rating", selection: $store.minRating) {
                Text("Any").tag(Double?.none)
                Text("3★+").tag(Double?.some(3))
                Text("4★+").tag(Double?.some(4))
                Text("4.5★+").tag(Double?.some(4.5))
            }
            Picker("Grape", selection: $store.grapeFilter) {
                Text("All").tag(String?.none)
                ForEach(store.availableGrapes, id: \.self) { grape in
                    Text(grape).tag(String?.some(grape))
                }
            }
            Picker("Sort", selection: $store.historySort) {
                ForEach(CellarReducer.State.HistorySort.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("history-filter-menu")
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

private struct TastingRowView: View {
    let row: TastingRow

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

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let note = row.tasting.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text(row.dateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let context {
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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

    private var context: String? {
        var parts: [String] = []
        if let withWhom = row.tasting.withWhom, !withWhom.isEmpty { parts.append(withWhom) }
        if let occasion = row.tasting.occasion, !occasion.isEmpty { parts.append(occasion) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private extension CellarReducer.State.Segment {
    var label: String {
        switch self {
        case .cellar: "Cellar"
        case .history: "History"
        }
    }
}

private extension CellarReducer.State.HistorySort {
    var label: String {
        switch self {
        case .dateNewest: "Newest"
        case .dateOldest: "Oldest"
        case .ratingHigh: "Highest Rated"
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
