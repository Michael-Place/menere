import ComposableArchitecture
import MenereUI
import PersistenceClient
import PhotosUI
import StorageClient
import SwiftUI
import WineDomain

/// "Log a tasting" form. Pure & uid-injected like its `BottleFormReducer` sibling: the reducer never
/// reads `@Shared(.user)` — the integration layer passes the signed-in `uid` and the resolved `Wine`
/// in at init, which keeps it trivially testable. Photo bytes arrive as `[Data]` via `.photosPicked`
/// (the view converts `PhotosPickerItem` → `Data`), so the reducer needs no PhotosUI to be tested.
/// Uploads photos via `\.storage`, persists a `Tasting` via `\.persistence`, and reports the result
/// upward via `delegate`.
@Reducer
public struct TastingFormReducer {
    @ObservableState
    public struct State: Equatable {
        public let wine: Wine
        public let hid: String
        public let uid: String

        var ratingStars: Double? = nil          // 0.5...5
        var rating100Text: String = ""          // parsed Int?
        var note: String = ""
        // SAT free text — deliberately NOT WSET enums (trademark).
        var appearance = ""
        var nose = ""
        var palate = ""
        var conclusions = ""
        var withWhom = ""
        var occasion = ""
        var bottleId: String? = nil
        var availableBottles: [Bottle] = []     // cellared bottles of THIS wine
        var pendingPhotos: [Data] = []          // selected, not yet uploaded
        var isSaving = false
        var errorMessage: String?
        /// Transient trigger bumped on each successful save, just before `.delegate(.saved)`. The view
        /// observes it via `.successHaptic(_:)` so a save celebration fires even as the form dismisses.
        var savedTick = 0

        /// Non-nil in edit mode: the id of the tasting being edited (save reuses it instead of minting).
        public var editingID: String? = nil
        /// Already-uploaded photo URLs from the tasting being edited; preserved on save (newly-picked
        /// `pendingPhotos` are appended after these). Removing existing remote photos is deferred (UX2c).
        var existingPhotoURLs: [URL] = []
        /// The original tasting `date`, preserved across saves.
        var originalDate: Date? = nil
        /// The original `createdAt`, preserved across saves.
        var originalCreatedAt: Date? = nil

        public init(wine: Wine, hid: String, uid: String) {
            self.wine = wine
            self.hid = hid
            self.uid = uid
        }

        /// Edit mode: prefill every field from an existing `Tasting`. Save reuses `editingID`,
        /// `originalDate`, `originalCreatedAt`, and keeps `existingPhotoURLs`.
        public init(editing tasting: Tasting, wine: Wine, hid: String, uid: String) {
            self.wine = wine
            self.hid = hid
            self.uid = uid
            self.ratingStars = tasting.ratingStars
            self.rating100Text = tasting.rating100.map(String.init) ?? ""
            self.note = tasting.note ?? ""
            self.appearance = tasting.sat?.appearance ?? ""
            self.nose = tasting.sat?.nose ?? ""
            self.palate = tasting.sat?.palate ?? ""
            self.conclusions = tasting.sat?.conclusions ?? ""
            self.withWhom = tasting.withWhom ?? ""
            self.occasion = tasting.occasion ?? ""
            self.bottleId = tasting.bottleId
            self.existingPhotoURLs = tasting.photoURLs
            self.editingID = tasting.id
            self.originalDate = tasting.date
            self.originalCreatedAt = tasting.createdAt
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case bottlesLoaded([Bottle])
        case photosPicked([Data])
        case removePhoto(Int)
        case saveTapped
        case saveResponse(SaveResult)
        case cancelTapped
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum SaveResult: Equatable {
            case success(Tasting)
            case failure(String)
        }

        public enum Delegate: Equatable {
            case saved(Tasting)
            case cancelled
        }
    }

    @Dependency(\.persistence) var persistence
    @Dependency(\.storage) var storage
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                return .run { [hid = state.hid, wineId = state.wine.id] send in
                    do {
                        let all = try await persistence.bottles(hid)
                        await send(.bottlesLoaded(all.filter { $0.wineId == wineId }))
                    } catch {
                        // Loading cellared bottles for the optional link picker is non-fatal.
                    }
                }

            case .bottlesLoaded(let bottles):
                state.availableBottles = bottles
                return .none

            case .photosPicked(let datas):
                state.pendingPhotos.append(contentsOf: datas)
                return .none

            case .removePhoto(let index):
                guard state.pendingPhotos.indices.contains(index) else { return .none }
                state.pendingPhotos.remove(at: index)
                return .none

            case .saveTapped:
                guard !state.isSaving else { return .none }
                state.isSaving = true
                state.errorMessage = nil
                let tastingId = state.editingID ?? uuid().uuidString
                let now = date.now
                let savedDate = state.originalDate ?? now
                let createdAt = state.originalCreatedAt ?? now
                let sat = Self.makeSAT(
                    appearance: state.appearance,
                    nose: state.nose,
                    palate: state.palate,
                    conclusions: state.conclusions
                )
                return .run { [
                    uid = state.uid,
                    hid = state.hid,
                    pending = state.pendingPhotos,
                    existing = state.existingPhotoURLs,
                    wineId = state.wine.id,
                    bottleId = state.bottleId,
                    ratingStars = state.ratingStars,
                    rating100Text = state.rating100Text,
                    note = state.note,
                    withWhom = state.withWhom,
                    occasion = state.occasion,
                    tastingId,
                    savedDate,
                    createdAt,
                    sat
                ] send in
                    do {
                        var urls: [URL] = existing
                        for data in pending {
                            urls.append(try await storage.uploadTastingPhoto(uid, tastingId, data))
                        }
                        let tasting = Tasting(
                            id: tastingId,
                            wineId: wineId,
                            bottleId: bottleId,
                            date: savedDate,
                            ratingStars: ratingStars,
                            rating100: Int(rating100Text.trimmingCharacters(in: .whitespaces)),
                            note: note.isEmpty ? nil : note,
                            sat: sat,
                            photoURLs: urls,
                            withWhom: withWhom.isEmpty ? nil : withWhom,
                            occasion: occasion.isEmpty ? nil : occasion,
                            createdAt: createdAt
                        )
                        try await persistence.saveTasting(hid, tasting)
                        await send(.saveResponse(.success(tasting)))
                    } catch {
                        await send(.saveResponse(.failure(error.localizedDescription)))
                    }
                }

            case .saveResponse(.success(let tasting)):
                state.isSaving = false
                state.savedTick += 1
                return .send(.delegate(.saved(tasting)))

            case .saveResponse(.failure(let message)):
                state.isSaving = false
                state.errorMessage = message
                return .none

            case .cancelTapped:
                return .send(.delegate(.cancelled))

            case .delegate, .binding:
                return .none
            }
        }
    }

    /// Maps the four free-text SAT fields into a `SATNote`, turning empty strings into nil. Returns
    /// `nil` when all four are empty so an untouched SAT section never persists an empty note.
    static func makeSAT(
        appearance: String,
        nose: String,
        palate: String,
        conclusions: String
    ) -> SATNote? {
        let a = appearance.isEmpty ? nil : appearance
        let n = nose.isEmpty ? nil : nose
        let p = palate.isEmpty ? nil : palate
        let c = conclusions.isEmpty ? nil : conclusions
        guard a != nil || n != nil || p != nil || c != nil else { return nil }
        return SATNote(appearance: a, nose: n, palate: p, conclusions: c)
    }
}

public struct TastingFormView: View {
    @Bindable var store: StoreOf<TastingFormReducer>
    @State private var pickerItems: [PhotosPickerItem] = []

    public init(store: StoreOf<TastingFormReducer>) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.wine.producer)
                        .wineName(.headline)
                        .foregroundStyle(Color.ink)
                    if let name = store.wine.name {
                        Text(name)
                            .cuvee()
                    }
                    if let vintage = store.wine.vintage {
                        Text(String(vintage))
                            .font(.subheadline)
                            .foregroundStyle(Color.inkSoft)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Rating") {
                starRatingRow
                TextField("Score (out of 100)", text: $store.rating100Text)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("rating100-field")
            }

            Section("Note") {
                TextField("Tasting note", text: $store.note, axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("note-field")
            }

            Section {
                TextField("Appearance", text: $store.appearance, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("appearance-field")
                TextField("Nose", text: $store.nose, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("nose-field")
                TextField("Palate", text: $store.palate, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("palate-field")
                TextField("Conclusions", text: $store.conclusions, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("conclusions-field")
            } header: {
                Text("Structured note")
            } footer: {
                Text("Free-form notes — jot down whatever you observe.")
            }

            Section("Context") {
                TextField("With whom", text: $store.withWhom)
                    .accessibilityIdentifier("with-whom-field")
                TextField("Occasion", text: $store.occasion)
                    .accessibilityIdentifier("occasion-field")
            }

            if !store.availableBottles.isEmpty {
                Section("Link to a bottle") {
                    Picker("Bottle", selection: $store.bottleId) {
                        Text("None").tag(String?.none)
                        ForEach(store.availableBottles) { bottle in
                            Text(bottleLabel(bottle)).tag(String?.some(bottle.id))
                        }
                    }
                    .accessibilityIdentifier("bottle-picker")
                }
            }

            Section("Photos") {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: 4,
                    matching: .images
                ) {
                    Label("Add photos", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("photos-picker")

                if !store.pendingPhotos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(store.pendingPhotos.enumerated()), id: \.offset) { index, data in
                                thumbnail(data: data, index: index)
                            }
                        }
                    }
                }
            }

            if let error = store.errorMessage {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(action: { store.send(.saveTapped) }) {
                    if store.isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(store.editingID == nil ? "Save tasting" : "Save changes")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isSaving)
                .accessibilityIdentifier("save-tasting-button")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .selectionHaptic(store.ratingStars)
        .successHaptic(store.savedTick)
        .navigationTitle(store.editingID == nil ? "Log a tasting" : "Edit tasting")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { store.send(.cancelTapped) }
                    .accessibilityIdentifier("cancel-tasting-button")
            }
        }
        .task { store.send(.task) }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var datas: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        datas.append(data)
                    }
                }
                if !datas.isEmpty {
                    store.send(.photosPicked(datas))
                }
                pickerItems = []
            }
        }
    }

    // MARK: - Subviews

    private var starRatingRow: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { position in
                star(for: position)
            }
            Spacer()
            if store.ratingStars != nil {
                Button("Clear") { store.ratingStars = nil }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
        .accessibilityIdentifier("rating-stars")
    }

    private func star(for position: Int) -> some View {
        let value = store.ratingStars ?? 0
        let full = Double(position)
        let half = full - 0.5
        let symbol: String
        if value >= full {
            symbol = "star.fill"
        } else if value >= half {
            symbol = "star.leadinghalf.filled"
        } else {
            symbol = "star"
        }
        return Image(systemName: symbol)
            .foregroundStyle(Color.candleGold)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: store.ratingStars)
            .onTapGesture {
                // Tap toggles between half and full for the same position.
                withAnimation(.menereBouncy) {
                    store.ratingStars = value == half ? full : half
                }
            }
    }

    private func thumbnail(data: Data, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                } else {
                    Rectangle()
                        .fill(.secondary.opacity(0.2))
                        .frame(width: 64, height: 64)
                }
            }
            .polaroid(rotation: index.isMultiple(of: 2) ? -1.5 : 1.5)
            .transition(.opacity)

            Button {
                store.send(.removePhoto(index))
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .accessibilityIdentifier("remove-photo-\(index)")
            .padding(2)
        }
        .animation(.menereSnappy, value: store.pendingPhotos.count)
    }

    private func bottleLabel(_ bottle: Bottle) -> String {
        var parts: [String] = []
        if let location = bottle.storageLocation, !location.isEmpty { parts.append(location) }
        parts.append("qty \(bottle.quantity)")
        return parts.joined(separator: " · ")
    }
}
