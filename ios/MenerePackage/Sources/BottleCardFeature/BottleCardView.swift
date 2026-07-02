import ComposableArchitecture
import JournalFeature
import MenereUI
import SwiftUI
import UIKit
import WineDomain

/// The bottle card — a tasteful, scrollable render of a resolved `Wine` with per-field provenance
/// badges. This is the app's "wow moment" after a scan resolves.
public struct BottleCardView: View {
    @Bindable var store: StoreOf<BottleCardFeature>

    /// Current wall-clock — sourced the same way as the cellar's drink-window classification
    /// (`Calendar.current.component(.year, from: date.now)`), so the gauge agrees with the cellar.
    @Dependency(\.date.now) private var now

    public init(store: StoreOf<BottleCardFeature>) {
        self.store = store
    }

    /// Convenience for callers (e.g. ScanFeature) that hold a fully-built feature state — used for the
    /// progressive reveal (identity + captured image + `isResolving`).
    public init(state: BottleCardFeature.State) {
        self.store = Store(initialState: state) {
            BottleCardFeature()
        }
    }

    /// Low-plumbing convenience for callers that just have a resolved `Wine`.
    public init(wine: Wine) {
        self.init(state: BottleCardFeature.State(wine: wine))
    }

    /// Owned-mode convenience: renders a `Wine` joined to the user's cellar `Bottle` — shows cellar
    /// facts and suppresses Add-to-cellar.
    public init(wine: Wine, ownedBottle: Bottle) {
        self.init(state: BottleCardFeature.State(wine: wine, ownedBottle: ownedBottle))
    }

    private var wine: Wine { store.wine }
    /// Whether enrichment is still resolving — drives the shimmer placeholders for enrichment rows.
    private var isResolving: Bool { store.isResolving }
    /// The current calendar year, used to position the drink-window gauge needle.
    private var currentYear: Int { Calendar.current.component(.year, from: now) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroBlock
                factsBlock
                ownedCellarBlock
                drinkWindowBlock
                summaryBlock
                pairingsBlock
                producerNoteBlock
                legend
                actionsBlock
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .animation(.menereBouncy, value: isResolving)
        .overlay { SealStamp(trigger: store.sealStamp) }
        .successHaptic(store.sealStamp)
        .task { store.send(.task) }
        .sheet(item: $store.scope(state: \.destination?.addToCellar, action: \.destination.addToCellar)) { formStore in
            NavigationStack { BottleFormView(store: formStore) }
        }
        .sheet(item: $store.scope(state: \.destination?.logTasting, action: \.destination.logTasting)) { formStore in
            NavigationStack { TastingFormView(store: formStore) }
        }
        .sheet(item: $store.scope(state: \.destination?.editBottle, action: \.destination.editBottle)) { formStore in
            NavigationStack { BottleFormView(store: formStore) }
        }
        .confirmationDialog($store.scope(state: \.confirmDelete, action: \.confirmDelete))
        // Wine-stack screen: keep the parchment "Cellar & Candlelight" chrome (the global family
        // appearance must not leak in here).
        .wineChrome()
    }

    // MARK: - Actions

    /// "Add to cellar" / "Log a tasting" — the M5 journaling entry points. Hidden while enrichment is
    /// still resolving (no point journaling an unresolved wine).
    @ViewBuilder private var actionsBlock: some View {
        if !isResolving {
            VStack(spacing: 12) {
                if store.ownedBottle == nil {
                    Button { store.send(.addToCellarTapped) } label: {
                        Label("Add to cellar", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("add-to-cellar-button")
                }
                Button { store.send(.logTastingTapped) } label: {
                    Label("Log a tasting", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("log-tasting-button")
                if store.ownedBottle != nil {
                    Button { store.send(.editTapped) } label: {
                        Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("edit-bottle-button")
                    Button(role: .destructive) { store.send(.deleteTapped) } label: {
                        Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("delete-bottle-button")
                }
            }
        }
    }

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            labelImage
            VStack(alignment: .leading, spacing: 6) {
                Text(wine.producer)
                    .wineName(.largeTitle)
                    .accessibilityIdentifier("bottle-card-producer")
                if let name = wine.name, !name.isEmpty {
                    Text(name)
                        .cuvee()
                }
                if let vintage = wine.vintage {
                    Text(String(vintage))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.menereBouncy, value: vintage)
                }
            }
        }
    }

    @ViewBuilder
    private var labelImage: some View {
        // M4 Phase 2: prefer the in-memory captured label image (the bytes just scanned) so the card
        // shows the user's actual bottle the instant it appears. Fall back to a persisted
        // `labelImageURL` (later milestone) and finally a graceful placeholder. M4 only DISPLAYS the
        // local image — it is not uploaded to Storage here.
        ZStack {
            if let data = store.imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if let url = wine.labelImageURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    gradientPlaceholder
                }
            } else {
                gradientPlaceholder
            }
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// No label image yet → a soft, wine-type-tinted mesh behind a centered wineglass. Replaces the
    /// former flat gray placeholder so even unenriched cards feel branded.
    private var gradientPlaceholder: some View {
        WineTypeGradient(type: WineTypeGradient.Kind(rawValue: wine.type.rawValue) ?? .other)
            .overlay {
                Image(systemName: "wineglass")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.candleGold)
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            }
    }

    // MARK: - Facts

    @ViewBuilder
    private var factsBlock: some View {
        let region = regionSummary
        // Region + grapes are scan *identity* (known immediately); style + ABV are *enrichment*.
        let hasIdentityFacts = region != nil || !wine.grapes.isEmpty
        let hasEnrichmentFacts = wine.type != .other || wine.abv != nil
        if hasIdentityFacts || hasEnrichmentFacts || isResolving {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    if let region {
                        factRow(
                            title: "Region",
                            badgeField: ProvenanceField.region,
                            icon: "map"
                        ) {
                            Text(region)
                        }
                    }
                    if !wine.grapes.isEmpty {
                        factRow(
                            title: "Grapes",
                            badgeField: ProvenanceField.grapes,
                            icon: "leaf"
                        ) {
                            ChipFlow(items: wine.grapes)
                        }
                    }
                    if isResolving {
                        // Enrichment still in flight: shimmer skeletons in place of style + ABV.
                        placeholderFactRow(title: "Style", icon: "wineglass", sample: "Red")
                        placeholderFactRow(title: "ABV", icon: "percent", sample: "13.5%")
                    } else {
                        if wine.type != .other {
                            factRow(
                                title: "Style",
                                badgeField: ProvenanceField.type,
                                icon: "wineglass"
                            ) {
                                Text(humanizedType)
                            }
                        }
                        if let abv = wine.abv {
                            factRow(
                                title: "ABV",
                                badgeField: ProvenanceField.abv,
                                icon: "percent"
                            ) {
                                Text(abvText(abv))
                                    .contentTransition(.numericText())
                                    .animation(.menereBouncy, value: abv)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A labeled fact row: title + optional provenance badge, then content.
    private func factRow<Content: View>(
        title: String,
        badgeField: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleOnly)
                Spacer(minLength: 8)
                if let badge = wine.provenanceBadge(for: badgeField) {
                    ProvenanceBadge(style: badge)
                }
            }
            content()
                .font(.body)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Owned cellar facts

    /// When the card renders an owned bottle, surface the user's known cellar facts (quantity, status,
    /// drink window, storage, store, price, purchase date). Each row appears only if present. Nil
    /// `ownedBottle` (scan path) renders nothing.
    @ViewBuilder private var ownedCellarBlock: some View {
        if let bottle = store.ownedBottle {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("In your cellar")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    cellarFactRow(title: "Quantity", icon: "number") { Text("×\(bottle.quantity)") }
                    cellarFactRow(title: "Status", icon: "tag") {
                        Text(bottle.status.rawValue.capitalized)
                    }
                    // Full numeric window is rendered as the living gauge in `drinkWindowBlock`; here
                    // we only surface a partial (from-only / by-only) window as text to avoid dupes.
                    if bottle.drinkFrom == nil || bottle.drinkBy == nil,
                       let window = ownedDrinkWindowText(bottle) {
                        cellarFactRow(title: "Drink window", icon: "calendar") { Text(window) }
                    }
                    if let location = bottle.storageLocation, !location.isEmpty {
                        cellarFactRow(title: "Storage", icon: "archivebox") { Text(location) }
                    }
                    if let store = bottle.store, !store.isEmpty {
                        cellarFactRow(title: "Store", icon: "cart") { Text(store) }
                    }
                    if let priceText = ownedPriceText(bottle) {
                        cellarFactRow(title: "Price", icon: "creditcard") { Text(priceText) }
                    }
                    if let date = bottle.purchaseDate {
                        cellarFactRow(title: "Purchased", icon: "bag") {
                            Text(Self.purchaseDateFormatter.string(from: date))
                        }
                    }
                }
            }
        }
    }

    /// A labeled cellar-fact row: title (no provenance badge — these are user-entered facts), value.
    private func cellarFactRow<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleOnly)
            content()
                .font(.body)
                .foregroundStyle(.primary)
        }
    }

    private func ownedDrinkWindowText(_ bottle: Bottle) -> String? {
        switch (bottle.drinkFrom, bottle.drinkBy) {
        case let (from?, by?): return "\(from)–\(by)"
        case let (from?, nil): return "From \(from)"
        case let (nil, by?): return "By \(by)"
        case (nil, nil): return nil
        }
    }

    private func ownedPriceText(_ bottle: Bottle) -> String? {
        guard let price = bottle.price else { return nil }
        let rounded = (price * 100).rounded() / 100
        let amount = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(rounded)
        if let currency = bottle.currency, !currency.isEmpty {
            return "\(amount) \(currency)"
        }
        return amount
    }

    private static let purchaseDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: - Resolving placeholders (shimmer)

    /// A skeleton fact row shown while enrichment resolves: the field label stays solid (it's known),
    /// the value is a redacted, shimmering placeholder.
    private func placeholderFactRow(title: String, icon: String, sample: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleOnly)
            Text(sample)
                .font(.body)
                .foregroundStyle(.primary)
                .redacted(reason: .placeholder)
                .shimmering()
        }
    }

    /// A solid section header (the title is known) for a resolving placeholder block.
    private func placeholderHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    /// A few redacted, shimmering text lines standing in for prose enrichment (summary / note). The
    /// last line is shorter so the skeleton reads like a paragraph.
    private func placeholderLines(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Text(String(repeating: "wine ", count: index == count - 1 ? 4 : 9))
                    .font(.body)
            }
        }
        .foregroundStyle(.primary)
        .redacted(reason: .placeholder)
        .shimmering()
    }

    // MARK: - Drink window

    @ViewBuilder
    private var drinkWindowBlock: some View {
        if isResolving {
            Card {
                placeholderFactRow(title: "Drink window", icon: "calendar", sample: "2025–2050")
            }
        } else if let from = store.ownedBottle?.drinkFrom, let by = store.ownedBottle?.drinkBy {
            // Owned bottle with a numeric window → the living gauge (it carries its own label + status).
            Card {
                DrinkWindowGauge(from: from, by: by, currentYear: currentYear)
            }
        } else if let window = wine.enrichment?.drinkingWindow, !window.isEmpty {
            Card {
                factRow(
                    title: "Drink window",
                    badgeField: ProvenanceField.drinkingWindow,
                    icon: "calendar"
                ) {
                    Text(window)
                }
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summaryBlock: some View {
        if isResolving {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    placeholderHeader("Tasting summary")
                    placeholderLines(3)
                }
            }
        } else if let summary = wine.enrichment?.summary, !summary.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Tasting summary", badgeField: ProvenanceField.summary)
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    // MARK: - Pairings

    @ViewBuilder
    private var pairingsBlock: some View {
        if isResolving {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    placeholderHeader("Food pairings")
                    ChipFlow(items: ["Roast lamb", "Aged cheese", "Mushrooms"])
                        .redacted(reason: .placeholder)
                        .shimmering()
                }
            }
        } else if let pairings = wine.enrichment?.foodPairings, !pairings.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Food pairings", badgeField: ProvenanceField.foodPairings)
                    ChipFlow(items: pairings)
                }
            }
        }
    }

    // MARK: - Producer note

    @ViewBuilder
    private var producerNoteBlock: some View {
        if isResolving {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    placeholderHeader("From the producer")
                    placeholderLines(2)
                }
            }
        } else if let note = wine.enrichment?.producerNote, !note.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("From the producer", badgeField: ProvenanceField.producerNote)
                    Text(note)
                        .font(.body)
                        .italic()
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, badgeField: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let badge = wine.provenanceBadge(for: badgeField) {
                ProvenanceBadge(style: badge)
            }
        }
    }

    // MARK: - Legend

    @ViewBuilder
    private var legend: some View {
        // Only show the legend once resolved and there's at least one enriched field to explain.
        if !isResolving, wine.enrichment?.provenance.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                Text("Where facts come from")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ChipFlow(spacing: 8, rowSpacing: 6) {
                    ProvenanceBadge(style: .verified)
                    ProvenanceBadge(style: .aiEstimate)
                    ProvenanceBadge(style: .scanned)
                    ProvenanceBadge(style: .you)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Derived

    private var regionSummary: String? {
        guard let region = wine.region else { return nil }
        let parts = [region.country, region.region, region.subregion, region.appellation]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var humanizedType: String {
        switch wine.type {
        case .red: "Red"
        case .white: "White"
        case .rose: "Rosé"
        case .sparkling: "Sparkling"
        case .dessert: "Dessert"
        case .fortified: "Fortified"
        case .other: "Other"
        }
    }

    private func abvText(_ abv: Double) -> String {
        let rounded = (abv * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))%"
        }
        return "\(rounded)%"
    }
}

// MARK: - Card container

/// Rounded surface used for each grouped section. Centralizes the card chrome.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.surfaceMenere)
            )
    }
}

// MARK: - Chip flow (wrapping tags)

/// A simple wrapping layout for chips/tags (grapes, pairings, legend). Uses the `Layout` protocol.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + rowSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: maxWidth == .infinity ? totalWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let maxX = bounds.maxX
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Convenience wrapper rendering either string items as chips, or arbitrary chip content.
private struct ChipFlow<Content: View>: View {
    let spacing: CGFloat
    let rowSpacing: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat = 8, rowSpacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.content = content()
    }

    var body: some View {
        FlowLayout(spacing: spacing, rowSpacing: rowSpacing) {
            content
        }
    }
}

private extension ChipFlow where Content == ForEach<[IndexedChip], Int, Chip> {
    init(items: [String], spacing: CGFloat = 8, rowSpacing: CGFloat = 8) {
        let indexed = items.enumerated().map { IndexedChip(id: $0.offset, text: $0.element) }
        self.init(spacing: spacing, rowSpacing: rowSpacing) {
            ForEach(indexed, id: \.id) { Chip(text: $0.text) }
        }
    }
}

private struct IndexedChip: Hashable {
    let id: Int
    let text: String
}

/// A single tag pill.
private struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color(.tertiarySystemFill))
            )
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Richly enriched") {
    BottleCardView(wine: BottleCardFixtures.richlyEnriched)
}

#Preview("Identity only") {
    BottleCardView(wine: BottleCardFixtures.identityOnly)
}

#Preview("Partially enriched") {
    BottleCardView(wine: BottleCardFixtures.partiallyEnriched)
}

// Progressive reveal: identity known, enrichment still resolving → shimmer placeholders, with the
// captured label image already shown.
#Preview("Resolving (shimmer + image)") {
    BottleCardView(
        state: BottleCardFeature.State(
            wine: BottleCardFixtures.resolvingIdentity,
            candidate: nil,
            imageData: BottleCardFixtures.sampleLabelImageData,
            isResolving: true
        )
    )
}

// The same card resolved: real enrichment + provenance badges, captured image shown.
#Preview("Resolved (enriched + image)") {
    BottleCardView(
        state: BottleCardFeature.State(
            wine: BottleCardFixtures.richlyEnriched,
            imageData: BottleCardFixtures.sampleLabelImageData,
            isResolving: false
        )
    )
}
#endif
