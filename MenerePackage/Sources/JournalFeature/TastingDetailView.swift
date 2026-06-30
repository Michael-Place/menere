import ComposableArchitecture
import SwiftUI
import WineDomain

/// Read-only view of a logged `Tasting` joined to its catalog `Wine`. Pushed from the History list
/// and the Home "Recent tastings" section. Deliberately inert for UX1 — the `.task` action is a seam
/// for UX2 (edit / delete); the reducer holds no mutable state.
@Reducer
public struct TastingDetailReducer {
    @ObservableState
    public struct State: Equatable {
        public let tasting: Tasting
        public let wine: Wine
        public init(tasting: Tasting, wine: Wine) {
            self.tasting = tasting
            self.wine = wine
        }
    }

    public enum Action: Equatable { case task }   // read-only for UX1; seam for UX2 edit/delete

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { _, action in
            switch action {
            case .task:
                return .none
            }
        }
    }
}

public struct TastingDetailView: View {
    let store: StoreOf<TastingDetailReducer>

    public init(store: StoreOf<TastingDetailReducer>) {
        self.store = store
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    public var body: some View {
        Form {
            wineIdentitySection
            ratingSection
            contextSection
            noteSection
            satSection
            photosSection
        }
        .navigationTitle("Tasting")
        .accessibilityIdentifier("tasting-detail")
        .task { store.send(.task) }
    }

    // MARK: - Sections

    private var wineIdentitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.wine.producer)
                    .font(.headline)
                if let name = store.wine.name {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let vintage = store.wine.vintage {
                    Text(String(vintage))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var ratingSection: some View {
        Section("Rating") {
            let tasting = store.tasting
            if tasting.ratingStars == nil && tasting.rating100 == nil {
                Text("No rating")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    if tasting.ratingStars != nil {
                        starRow(for: tasting.ratingStars ?? 0)
                    }
                    if let pts = tasting.rating100 {
                        Text("\(pts) pts")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contextSection: some View {
        let tasting = store.tasting
        let withWhom = tasting.withWhom.flatMap { $0.isEmpty ? nil : $0 }
        let occasion = tasting.occasion.flatMap { $0.isEmpty ? nil : $0 }
        Section("When") {
            LabeledRow(label: "Date", value: Self.dateFormatter.string(from: tasting.date))
            if let withWhom {
                LabeledRow(label: "With", value: withWhom)
            }
            if let occasion {
                LabeledRow(label: "Occasion", value: occasion)
            }
        }
    }

    @ViewBuilder
    private var noteSection: some View {
        if let note = store.tasting.note, !note.isEmpty {
            Section("Note") {
                Text(note)
            }
        }
    }

    @ViewBuilder
    private var satSection: some View {
        if let sat = store.tasting.sat, hasContent(sat) {
            Section("Structured note") {
                satRow(label: "Appearance", value: sat.appearance)
                satRow(label: "Nose", value: sat.nose)
                satRow(label: "Palate", value: sat.palate)
                satRow(label: "Conclusions", value: sat.conclusions)
            }
        }
    }

    @ViewBuilder
    private var photosSection: some View {
        if !store.tasting.photoURLs.isEmpty {
            Section("Photos") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.tasting.photoURLs, id: \.self) { url in
                            AsyncImage(url: url) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                ProgressView()
                            }
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func satRow(label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
            }
        }
    }

    private func hasContent(_ sat: SATNote) -> Bool {
        [sat.appearance, sat.nose, sat.palate, sat.conclusions]
            .contains { $0.map { !$0.isEmpty } ?? false }
    }

    /// A fixed, non-interactive 5-star row reflecting a 0.5...5 rating (half-star aware). Mirrors the
    /// glyph logic in `TastingFormView` but renders read-only.
    private func starRow(for value: Double) -> some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { position in
                Image(systemName: Self.starSymbol(for: value, position: position))
                    .foregroundStyle(.yellow)
            }
        }
        .accessibilityIdentifier("rating-stars")
    }

    private static func starSymbol(for value: Double, position: Int) -> String {
        let full = Double(position)
        let half = full - 0.5
        if value >= full {
            return "star.fill"
        } else if value >= half {
            return "star.leadinghalf.filled"
        } else {
            return "star"
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}
