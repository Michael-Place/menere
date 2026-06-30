import ComposableArchitecture
import MenereUI
import SwiftUI
import UserDomain
import WineDomain

/// Detail view of a logged `Tasting` joined to its catalog `Wine`. Pushed from the History list and
/// the Home "Recent tastings" section. UX2a adds owned Edit / Delete: editing presents a prefilled
/// `TastingFormReducer`; delete confirms then reports `.delegate(.tastingDeleted)` upward (the parent
/// performs the deletion + reload). The `.task` action stays inert.
@Reducer
public struct TastingDetailReducer {
    @ObservableState
    public struct State: Equatable {
        public let tasting: Tasting
        public let wine: Wine
        @Presents public var destination: Destination.State?
        @Presents public var confirmDelete: ConfirmationDialogState<Action.ConfirmDelete>?
        public init(tasting: Tasting, wine: Wine) {
            self.tasting = tasting
            self.wine = wine
        }
    }

    @Reducer(state: .equatable, action: .equatable)
    public enum Destination {
        case editTasting(TastingFormReducer)
    }

    public enum Action: Equatable {
        case task   // inert; reserved seam
        case editTapped
        case deleteTapped
        case confirmDelete(PresentationAction<ConfirmDelete>)
        case destination(PresentationAction<Destination.Action>)
        case delegate(Delegate)

        public enum ConfirmDelete: Equatable { case confirm }

        public enum Delegate: Equatable {
            case tastingDeleted(String)
            case tastingUpdated(Tasting)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .none

            case .editTapped:
                @Shared(.user) var user
                guard let uid = user?.id, let hid = user?.householdId else { return .none }
                state.destination = .editTasting(
                    TastingFormReducer.State(editing: state.tasting, wine: state.wine, hid: hid, uid: uid)
                )
                return .none

            case .deleteTapped:
                state.confirmDelete = ConfirmationDialogState {
                    TextState("Delete this tasting?")
                } actions: {
                    ButtonState(role: .destructive, action: .confirm) {
                        TextState("Delete")
                    }
                    ButtonState(role: .cancel) {
                        TextState("Cancel")
                    }
                }
                return .none

            case .confirmDelete(.presented(.confirm)):
                return .send(.delegate(.tastingDeleted(state.tasting.id)))

            case .destination(.presented(.editTasting(.delegate(.saved(let tasting))))):
                state.destination = nil
                return .send(.delegate(.tastingUpdated(tasting)))

            case .destination(.presented(.editTasting(.delegate(.cancelled)))):
                state.destination = nil
                return .none

            case .confirmDelete, .destination, .delegate:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
        .ifLet(\.$confirmDelete, action: \.confirmDelete)
    }
}

public struct TastingDetailView: View {
    @Bindable var store: StoreOf<TastingDetailReducer>

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { store.send(.editTapped) }
                    .accessibilityIdentifier("edit-tasting-button")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { store.send(.deleteTapped) } label: {
                    Image(systemName: "trash")
                }
                .accessibilityIdentifier("delete-tasting-button")
            }
        }
        .task { store.send(.task) }
        .sheet(item: $store.scope(state: \.destination?.editTasting, action: \.destination.editTasting)) { formStore in
            NavigationStack { TastingFormView(store: formStore) }
        }
        .confirmationDialog($store.scope(state: \.confirmDelete, action: \.confirmDelete))
    }

    // MARK: - Sections

    private var wineIdentitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.wine.producer)
                    .wineName(.headline)
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
