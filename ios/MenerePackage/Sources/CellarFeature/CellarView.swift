import BottleCardFeature
import ComposableArchitecture
import JournalFeature
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain
import WineDomain

// MARK: - Row model

/// A single bottle we hold: the owned `Bottle` joined to its catalog `Wine`. Built once at load time
/// so the view stays pure. The reframe drops the old drink-window/aging classification — this is now
/// just "a bottle on the holder", not a cellar-managed inventory item.
public struct CellarRow: Equatable, Identifiable, Sendable {
    public var id: String { bottle.id }
    public let bottle: Bottle
    public let wine: Wine

    public init(bottle: Bottle, wine: Wine) {
        self.bottle = bottle
        self.wine = wine
    }

    public var producer: String { wine.producer }

    /// Cuvée name and/or vintage, e.g. "Grand Vin · 2018", "2018", or nil.
    public var nameVintage: String? {
        var parts: [String] = []
        if let name = wine.name, !name.isEmpty { parts.append(name) }
        if let vintage = wine.vintage { parts.append(String(vintage)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Bridge to the semantic red/white/rosé color coding (kept from the old cellar).
    public var typeKind: WineTypeGradient.Kind {
        WineTypeGradient.Kind(rawValue: wine.type.rawValue) ?? .other
    }
}

// MARK: - Tasting row model

/// A single journal entry: the private `Tasting` joined to its catalog `Wine`. Built once at load
/// time so the view stays pure.
public struct TastingRow: Equatable, Identifiable, Sendable {
    public var id: String { tasting.id }
    public let tasting: Tasting
    public let wine: Wine

    public init(tasting: Tasting, wine: Wine) {
        self.tasting = tasting
        self.wine = wine
    }

    public var producer: String { wine.producer }

    /// Cuvée name and/or vintage, e.g. "Grand Vin · 2018", "2018", or nil.
    public var nameVintage: String? {
        var parts: [String] = []
        if let name = wine.name, !name.isEmpty { parts.append(name) }
        if let vintage = wine.vintage { parts.append(String(vintage)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var typeKind: WineTypeGradient.Kind {
        WineTypeGradient.Kind(rawValue: wine.type.rawValue) ?? .other
    }

    public var dateText: String {
        TastingRow.dateFormatter.string(from: tasting.date)
    }

    /// "With whom · Occasion" if either is present, else nil.
    public var context: String? {
        var parts: [String] = []
        if let withWhom = tasting.withWhom, !withWhom.isEmpty { parts.append(withWhom) }
        if let occasion = tasting.occasion, !occasion.isEmpty { parts.append(occasion) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

// MARK: - Reducer

@Reducer
public struct CellarReducer {
    /// Push / present destinations from the Wine root.
    @Reducer(state: .equatable, action: .equatable)
    public enum Destination {
        case wineDetail(BottleCardFeature)
        case tastingDetail(TastingDetailReducer)
        /// "Pour a glass" from an on-hand tile → the shared tasting form (journaling).
        case pourTasting(TastingFormReducer)
    }

    @ObservableState
    public struct State: Equatable {
        @Presents public var destination: Destination.State?
        /// The on-hand tile action sheet (Pour a glass / View bottle).
        @Presents public var pourDialog: ConfirmationDialogState<Action.PourAction>?

        /// Every owned bottle joined to its wine. "On hand" is a VIEW over the cellared subset.
        public var rows: [CellarRow] = []
        /// Every journal entry (tasting) joined to its wine.
        public var tastingRows: [TastingRow] = []
        public var isLoading = false
        public var loadError: String?
        /// Free-text filter over the journal feed.
        public var searchText = ""

        public init() {}

        /// The holder: bottles still on hand (status `.cellared`), newest first. Capped for display in
        /// the strip by the view; the model keeps them all.
        public var onHandRows: [CellarRow] {
            rows
                .filter { $0.bottle.status == .cellared }
                .sorted { $0.bottle.createdAt > $1.bottle.createdAt }
        }

        /// Count for the "N on hand" glance.
        public var onHandCount: Int { onHandRows.reduce(0) { $0 + max($1.bottle.quantity, 1) } }

        /// Count for the "N wines journaled" glance.
        public var journaledCount: Int { tastingRows.count }

        /// True while the user has a non-empty (trimmed) search query.
        public var isSearching: Bool {
            !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Search applied, then newest-first — the journal feed.
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
            result.sort { $0.tasting.date > $1.tasting.date }
            return result
        }

        /// The journal entries logged for a given wine (newest first) — surfaced on the bottle card.
        public func journalEntries(forWineId wineId: String) -> [Tasting] {
            tastingRows
                .filter { $0.wine.id == wineId }
                .map(\.tasting)
                .sorted { $0.date > $1.date }
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case loaded([CellarRow])
        case tastingsLoaded([TastingRow])
        case loadFailed(String)
        case onHandTapped(CellarRow)
        case addBottleTapped
        case journalRowTapped(TastingRow)
        case deleteTastingSwiped(String)
        case pourDialog(PresentationAction<PourAction>)
        case destination(PresentationAction<Destination.Action>)
        case delegate(Delegate)
        case binding(BindingAction<State>)

        /// The on-hand tile menu choices; each carries the tapped row.
        public enum PourAction: Equatable, Sendable {
            case pour(CellarRow)
            case view(CellarRow)
        }

        public enum Delegate: Equatable { case requestScan }
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
                        let cellarRows = bottles.compactMap { b -> CellarRow? in
                            guard let w = byKey[b.wineId] else { return nil }
                            return CellarRow(bottle: b, wine: w)
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

            case let .onHandTapped(row):
                state.pourDialog = ConfirmationDialogState {
                    TextState(row.producer)
                } actions: {
                    ButtonState(action: .pour(row)) { TextState("Pour a glass") }
                    ButtonState(action: .view(row)) { TextState("View bottle") }
                    ButtonState(role: .cancel) { TextState("Cancel") }
                } message: {
                    TextState("Pour a glass to add a journal entry, or peek at the bottle.")
                }
                return .none

            case let .pourDialog(.presented(.pour(row))):
                @Shared(.user) var user
                guard let uid = user?.id, let hid = user?.householdId else { return .none }
                state.destination = .pourTasting(
                    TastingFormReducer.State(wine: row.wine, hid: hid, uid: uid)
                )
                return .none

            case let .pourDialog(.presented(.view(row))):
                state.destination = .wineDetail(
                    BottleCardFeature.State(
                        wine: row.wine,
                        ownedBottle: row.bottle,
                        journalEntries: state.journalEntries(forWineId: row.wine.id)
                    )
                )
                return .none

            case .pourDialog:
                return .none

            case .addBottleTapped:
                return .send(.delegate(.requestScan))

            case let .journalRowTapped(row):
                state.destination = .tastingDetail(
                    TastingDetailReducer.State(tasting: row.tasting, wine: row.wine)
                )
                return .none

            case let .deleteTastingSwiped(id):
                return deleteTastingAndReload(id)

            // Pour form saved → dismiss + reload so the new entry appears at the top of the feed.
            case .destination(.presented(.pourTasting(.delegate(.saved)))):
                state.destination = nil
                return .send(.task)

            case .destination(.presented(.pourTasting(.delegate(.cancelled)))):
                state.destination = nil
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

            case .delegate:
                return .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
        .ifLet(\.$pourDialog, action: \.pourDialog)
    }
}

// MARK: - Mutation + reload helpers

/// Delete a bottle from the household then reload (re-send `.task`). Shared by the detail screen's
/// delegate. On delete error, surfaces `.loadFailed`.
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
/// delegate and the journal-feed swipe action.
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

    /// Shared zoom-transition namespace pairing feed rows to their pushed destinations.
    @Namespace private var zoomNamespace

    /// Bumped whenever a load-error `ContentUnavailableView` appears so its glyph bounces on entry.
    @State private var errorBounce = 0

    public init(store: StoreOf<CellarReducer>) {
        self.store = store
    }

    public var body: some View {
        content
            .wineNavTitle("Wine")
            .searchable(text: $store.searchText, prompt: "Search your journal")
            .searchToolbarBehavior(.minimize)
            .task { store.send(.task) }
            .confirmationDialog($store.scope(state: \.pourDialog, action: \.pourDialog))
            .navigationDestination(
                item: $store.scope(state: \.destination?.wineDetail, action: \.destination.wineDetail)
            ) { detailStore in
                BottleCardView(store: detailStore)
                    .navigationTransition(
                        .zoom(
                            sourceID: detailStore.ownedBottle?.id ?? detailStore.wine.id,
                            in: zoomNamespace
                        )
                    )
            }
            .navigationDestination(
                item: $store.scope(state: \.destination?.tastingDetail, action: \.destination.tastingDetail)
            ) { detailStore in
                TastingDetailView(store: detailStore)
                    .navigationTransition(.zoom(sourceID: detailStore.tasting.id, in: zoomNamespace))
            }
            .sheet(
                item: $store.scope(state: \.destination?.pourTasting, action: \.destination.pourTasting)
            ) { formStore in
                NavigationStack { TastingFormView(store: formStore) }
            }
            // Wine-stack screen: wears the shared Bacán family chrome (familyCanvas + bacanGreen tint).
            .wineChrome()
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.rows.isEmpty && store.tastingRows.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.familyCanvas)
        } else if let error = store.loadError {
            errorState(error)
        } else if store.rows.isEmpty && store.tastingRows.isEmpty {
            emptyState
        } else {
            journalList
        }
    }

    // MARK: Empty / error

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No wine yet", systemImage: "wineglass")
                .symbolEffect(.pulse, options: .repeating)
        } description: {
            Text("Scan a label to keep it on hand and start your journal.")
        } actions: {
            Button("Scan a wine") { store.send(.addBottleTapped) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wine-empty-scan")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.familyCanvas)
        .accessibilityIdentifier("wine-empty")
    }

    private func errorState(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load your wine", systemImage: "exclamationmark.triangle")
                .symbolEffect(.bounce, options: .nonRepeating, value: errorBounce)
        } description: {
            Text(error)
        } actions: {
            Button("Try again") { store.send(.task) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wine-error-retry")
        }
        .onAppear { errorBounce += 1 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.familyCanvas)
        .accessibilityIdentifier("wine-error")
    }

    // MARK: Journal-first list

    private var journalList: some View {
        List {
            // The holder strip — only when NOT searching (search focuses the journal feed).
            if !store.isSearching {
                Section {
                    OnHandStrip(
                        rows: store.onHandRows,
                        onTap: { store.send(.onHandTapped($0)) },
                        onAdd: { store.send(.addBottleTapped) }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    onHandHeader
                }
            }

            journalSection
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .listSectionSpacing(.compact)
    }

    private var onHandHeader: some View {
        HStack {
            Text("On hand")
                .font(.title3.bold())
                .foregroundStyle(Color.ink)
            Spacer()
            if store.onHandCount > 0 {
                Text("\(store.onHandCount)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var journalSection: some View {
        if store.tastingRows.isEmpty {
            Section {
                EmptyJournalHint()
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } header: { journalHeader }
        } else if store.isSearching && store.visibleTastingRows.isEmpty {
            Section {
                ContentUnavailableView.search(text: store.searchText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } else {
            Section {
                ForEach(store.visibleTastingRows) { row in
                    Button {
                        store.send(.journalRowTapped(row))
                    } label: {
                        JournalCardView(row: row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("journal-row-\(row.id)")
                    .matchedTransitionSource(id: row.id, in: zoomNamespace)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.send(.deleteTastingSwiped(row.id))
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("journal-delete-\(row.id)")
                    }
                }
            } header: { journalHeader }
        }
    }

    private var journalHeader: some View {
        HStack {
            Text("Journal")
                .font(.title3.bold())
                .foregroundStyle(Color.ink)
            Spacer()
            if store.journaledCount > 0 {
                Text("\(store.journaledCount) \(store.journaledCount == 1 ? "wine" : "wines") journaled")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .textCase(nil)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}

// MARK: - On-hand strip

/// The holder: a compact horizontal rail of the bottles still on hand, plus a trailing "+" tile that
/// jumps to Scan. Deliberately light — this is a ~6-bottle holder, not an inventory.
private struct OnHandStrip: View {
    let rows: [CellarRow]
    let onTap: (CellarRow) -> Void
    let onAdd: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(rows) { row in
                    Button { onTap(row) } label: { OnHandTile(row: row) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("on-hand-tile-\(row.id)")
                }
                Button { onAdd() } label: { AddTile() }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("on-hand-add")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }
}

private struct OnHandTile: View {
    let row: CellarRow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WineTypeGradient(type: row.typeKind)
                .frame(height: 64)
                .overlay(alignment: .bottomLeading) {
                    if row.bottle.quantity > 1 {
                        Text("×\(row.bottle.quantity)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.black.opacity(0.28)))
                            .padding(6)
                    }
                }
                .overlay {
                    Image(systemName: "wineglass")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.marigold)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.producer)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if let sub = row.nameVintage {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(Color.inkSoft)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 132, alignment: .leading)
        .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.ink.opacity(0.06), radius: 6, y: 3)
    }
}

private struct AddTile: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
            Text("Add")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(Color.bacanGreen)
        .frame(width: 88, height: 128)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.bacanGreen.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.bacanGreen.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
    }
}

// MARK: - Journal card

/// A rich, scannable journal entry: a leading type-color spine (or the tasting's own photo), the
/// wine's identity, a star rating, the note, and when/with-whom it was poured. Newest first.
private struct JournalCardView: View {
    let row: TastingRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.producer)
                        .wineName(.headline)
                    Spacer(minLength: 8)
                    StarRow(value: row.tasting.ratingStars, points: row.tasting.rating100)
                }
                if let sub = row.nameVintage {
                    Text(sub)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let note = row.tasting.note, !note.isEmpty {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
                HStack(spacing: 8) {
                    Label(row.dateText, systemImage: "calendar")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let context = row.context {
                        Text(context)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.ink.opacity(0.06), radius: 7, y: 3)
    }

    /// A photo thumbnail when the entry has one, else a slim type-tinted spine (semantic color coding).
    @ViewBuilder
    private var leading: some View {
        if let url = row.tasting.photoURLs.first {
            BacanImage(url: url, targetSize: CGSize(width: 56, height: 72), contentMode: .fill) {
                WineTypeGradient(type: row.typeKind)
            }
            .frame(width: 56, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            WineTypeGradient(type: row.typeKind)
                .frame(width: 10, height: 72)
                .clipShape(Capsule())
        }
    }
}

/// Compact read-only star rating (half-star aware); falls back to the 100-pt score, else nothing.
struct StarRow: View {
    let value: Double?
    let points: Int?

    var body: some View {
        if let stars = value {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { position in
                    Image(systemName: Self.symbol(for: stars, position: position))
                        .font(.caption)
                        .foregroundStyle(Color.marigold)
                }
            }
            .accessibilityLabel("\(stars) stars")
        } else if let points {
            Text("\(points) pts")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    static func symbol(for value: Double, position: Int) -> String {
        let full = Double(position)
        let half = full - 0.5
        if value >= full { return "star.fill" }
        if value >= half { return "star.leadinghalf.filled" }
        return "star"
    }
}

private struct EmptyJournalHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your journal is empty")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text("Pour a bottle from your holder to write your first note.")
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Previews

#if DEBUG
private enum WinePreview {
    static let margaux = Wine(
        producer: "Château Margaux", name: "Grand Vin", vintage: 2015,
        region: Region(country: "France", region: "Bordeaux", appellation: "Margaux"),
        grapes: ["Cabernet Sauvignon", "Merlot"], type: .red
    )
    static let sancerre = Wine(
        producer: "Domaine Vacheron", name: "Sancerre", vintage: 2022,
        region: Region(country: "France", region: "Loire"),
        grapes: ["Sauvignon Blanc"], type: .white
    )
    static let rose = Wine(
        producer: "Domaine Tempier", name: "Bandol Rosé", vintage: 2023, type: .rose
    )

    static let bottles: [Bottle] = [
        Bottle(id: "b1", wineId: margaux.id, quantity: 2, status: .cellared,
               createdAt: Date(timeIntervalSince1970: 300)),
        Bottle(id: "b2", wineId: sancerre.id, quantity: 1, status: .cellared,
               createdAt: Date(timeIntervalSince1970: 200)),
        Bottle(id: "b3", wineId: rose.id, quantity: 1, status: .cellared,
               createdAt: Date(timeIntervalSince1970: 100)),
    ]

    static let tastings: [Tasting] = [
        Tasting(id: "t1", wineId: margaux.id, date: Date(timeIntervalSince1970: 900),
                ratingStars: 4.5,
                note: "Perfumed and silky — cassis, violet, a long graphite finish. Special night.",
                withWhom: "Valentina", occasion: "Anniversary"),
        Tasting(id: "t2", wineId: sancerre.id, date: Date(timeIntervalSince1970: 800),
                ratingStars: 4.0, note: "Crisp, flinty, so easy on the porch.",
                occasion: "Friday"),
        Tasting(id: "t3", wineId: rose.id, date: Date(timeIntervalSince1970: 700),
                rating100: 91, note: "Bone-dry, herbal. Summer in a glass."),
    ]

    static func store(bottles: [Bottle], tastings: [Tasting]) -> StoreOf<CellarReducer> {
        withDependencies {
            $0.defaultFileStorage = .inMemory
            $0.persistence.bottles = { _ in bottles }
            $0.persistence.tastings = { _ in tastings }
            $0.persistence.wines = { _ in [margaux, sancerre, rose] }
            $0.date = .constant(.now)
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "u", displayName: "Michael", householdId: "h") }
            return Store(initialState: CellarReducer.State()) { CellarReducer() }
        }
    }
}

#Preview("Wine — on hand + journal") {
    NavigationStack {
        CellarView(store: WinePreview.store(
            bottles: WinePreview.bottles, tastings: WinePreview.tastings
        ))
    }
}

#Preview("Wine — holder, empty journal") {
    NavigationStack {
        CellarView(store: WinePreview.store(bottles: WinePreview.bottles, tastings: []))
    }
}

#Preview("Wine — empty") {
    NavigationStack {
        CellarView(store: WinePreview.store(bottles: [], tastings: []))
    }
}
#endif
