import ComposableArchitecture
import DocsFeature
import FamilyDomain
import MenereUI
import PersistenceClient
import PhotosUI
import StorageClient
import SwiftUI
import UIKit
import UserDomain

/// A one-tap starter for the House-care empty state — the family's real recurring upkeep.
/// Tapping one creates a pre-filled ``CareItem`` the user can edit afterward.
public struct CareSuggestion: Equatable, Identifiable, Sendable {
    public let id: String
    let name: String
    let icon: String
    let taskTitle: String
    let intervalDays: Int?

    func makeItem() -> CareItem {
        CareItem(
            kind: .house,
            name: name,
            iconSymbol: icon,
            tasks: [CareTask(title: taskTitle, intervalDays: intervalDays)]
        )
    }

    /// The Place family's real "stuff you always forget."
    static let starters: [CareSuggestion] = [
        .init(id: "hvac", name: "HVAC filter", icon: "wind", taskTitle: "Replace filter", intervalDays: 90),
        .init(id: "gutters", name: "Gutters", icon: "drop.fill", taskTitle: "Clean gutters", intervalDays: 180),
        .init(id: "kitchen", name: "Deep clean: kitchen", icon: "sparkles", taskTitle: "Deep clean", intervalDays: 30),
        .init(id: "bathrooms", name: "Deep clean: bathrooms", icon: "shower.fill", taskTitle: "Deep clean", intervalDays: 30),
        .init(id: "bedding", name: "Laundry: bedding", icon: "bed.double.fill", taskTitle: "Wash bedding", intervalDays: 14),
        .init(id: "waterheater", name: "Water heater flush", icon: "flame.fill", taskTitle: "Flush tank", intervalDays: 180),
    ]
}

/// A one-tap starter for the Yard & garden empty state (P9-C3) — the seasonal landscaping jobs
/// Michael runs on the calendar. Each anchors its first-due to the **next occurrence** of a
/// month/day (this year if still ahead, else next year) and repeats **yearly** (`intervalDays: 365`)
/// once completed — so a fresh add reads as a future window, not "due today."
public struct YardSuggestion: Equatable, Identifiable, Sendable {
    public let id: String
    let name: String
    let icon: String
    let taskTitle: String
    let month: Int
    let day: Int

    /// The next calendar occurrence of `month`/`day` on or after today — this year when the window is
    /// still ahead, otherwise next year. Anchored at 9am local so a same-day add lands "due today"
    /// rather than tripping a start-of-day boundary.
    func nextAnchor(now: Date = Date(), calendar: Calendar = .current) -> Date {
        var comps = DateComponents()
        comps.month = month
        comps.day = day
        comps.hour = 9
        comps.year = calendar.component(.year, from: now)
        let thisYear = calendar.date(from: comps) ?? now
        if thisYear >= calendar.startOfDay(for: now) { return thisYear }
        comps.year = (comps.year ?? calendar.component(.year, from: now)) + 1
        return calendar.date(from: comps) ?? thisYear
    }

    func makeItem(now: Date = Date()) -> CareItem {
        CareItem(
            kind: .zone,
            name: name,
            iconSymbol: icon,
            tasks: [CareTask(title: taskTitle, intervalDays: 365, firstDueAt: nextAnchor(now: now))]
        )
    }

    /// Michael's seasonal landscaping rotation (dates are the yearly windows).
    static let starters: [YardSuggestion] = [
        .init(id: "mulch", name: "Spring mulch", icon: "tree.fill", taskTitle: "Spread mulch", month: 3, day: 15),
        .init(id: "prune", name: "Prune shrubs", icon: "scissors", taskTitle: "Prune shrubs", month: 2, day: 15),
        .init(id: "overseed", name: "Aerate & overseed", icon: "leaf.fill", taskTitle: "Aerate & overseed", month: 9, day: 15),
        .init(id: "fallcleanup", name: "Fall cleanup", icon: "wind", taskTitle: "Fall cleanup", month: 10, day: 15),
        .init(id: "leafremoval", name: "Leaf removal", icon: "sparkles", taskTitle: "Leaf removal", month: 11, day: 15),
    ]
}

/// The Place family's real dogs (P10). A one-tap add for the Pets empty state — "The pack" —
/// pre-filling the standard dog-care schedule. Persistent-filtered like the yard starters (adding
/// Fajita leaves Sprinkle on offer).
public struct PetSuggestion: Equatable, Identifiable, Sendable {
    public let id: String
    let name: String
    let icon: String

    /// The standard dog-care tasks, all never-done ⇒ due today (the first real completion anchors each
    /// to its cadence). Shared by the named starters and the blank "Someone else…" pet.
    static func defaultTasks() -> [CareTask] {
        [
            CareTask(title: "Heartworm pill", intervalDays: 30),
            CareTask(title: "Flea & tick", intervalDays: 30),
            CareTask(title: "Grooming", intervalDays: 60),
            CareTask(title: "Nail trim", intervalDays: 30),
        ]
    }

    func makeItem() -> CareItem {
        CareItem(kind: .pet, name: name, iconSymbol: "pawprint.fill", tasks: PetSuggestion.defaultTasks())
    }

    /// Fajita & Sprinkle — family canon.
    static let starters: [PetSuggestion] = [
        .init(id: "fajita", name: "Fajita", icon: "pawprint.fill"),
        .init(id: "sprinkle", name: "Sprinkle", icon: "pawprint.fill"),
    ]
}

/// The eight well-defined plant-care task types offered in the plant form's "Add care task" picker
/// (P19-C1). Each pre-fills a new ``CareTask``'s title + cadence and carries a badge symbol; the
/// symbol is re-derived from an arbitrary task title by ``symbol(forTitle:)`` so the plant DETAIL
/// screen can glyph *every* task without a model change (``CareTask`` stays symbol-free — this is
/// presets + UI only). Everything stays editable after the tap.
public enum PlantCarePreset: String, CaseIterable, Equatable, Sendable, Identifiable {
    case water, fertilize, repot, prune, rotate, mist, cleanLeaves, pestCheck

    public var id: String { rawValue }

    /// The task title seeded into the new ``CareTask`` (and matched by the detail's symbol/verb helpers).
    public var title: String {
        switch self {
        case .water: "Water"
        case .fertilize: "Fertilize"
        case .repot: "Re-pot"
        case .prune: "Prune"
        case .rotate: "Rotate"
        case .mist: "Mist"
        case .cleanLeaves: "Clean leaves"
        case .pestCheck: "Pest check"
        }
    }

    /// A sensible default cadence in days (Water 7 · Fertilize 30 · Re-pot 365 · Prune 90 · Rotate 7 ·
    /// Mist 3 · Clean leaves 30 · Pest check 14).
    public var intervalDays: Int {
        switch self {
        case .water: 7
        case .fertilize: 30
        case .repot: 365
        case .prune: 90
        case .rotate: 7
        case .mist: 3
        case .cleanLeaves: 30
        case .pestCheck: 14
        }
    }

    /// The SF Symbol badged on the preset in the picker and on the plant DETAIL task rows.
    public var symbol: String {
        switch self {
        case .water: "drop.fill"
        case .fertilize: "leaf.fill"
        case .repot: "shippingbox.fill"
        case .prune: "scissors"
        case .rotate: "arrow.clockwise"
        case .mist: "humidity.fill"
        case .cleanLeaves: "sparkles"
        case .pestCheck: "ladybug.fill"
        }
    }

    /// A short caption ("Every 7 days") for the picker row.
    var cadenceCaption: String { CareItem.intervalLabel(intervalDays) }

    /// The preset whose title best matches an arbitrary task title (substring, case-insensitive) — so a
    /// renamed/edited task still resolves to the right glyph on the detail screen. `nil` when nothing
    /// matches (a fully custom task).
    static func matching(_ title: String) -> PlantCarePreset? {
        let t = title.lowercased()
        if t.contains("water") { return .water }
        if t.contains("fertil") { return .fertilize }
        if t.contains("re-pot") || t.contains("repot") { return .repot }
        if t.contains("prune") { return .prune }
        if t.contains("rotate") { return .rotate }
        if t.contains("mist") { return .mist }
        if t.contains("clean") || t.contains("wipe") { return .cleanLeaves }
        if t.contains("pest") { return .pestCheck }
        return nil
    }

    /// The badge symbol for a task title — a matched preset's glyph, else a soft leaf default.
    static func symbol(forTitle title: String) -> String {
        matching(title)?.symbol ?? "leaf.fill"
    }
}

@Reducer
public struct CareItemFormReducer {
    @ObservableState
    public struct State: Equatable {
        var item: CareItem
        let isEditing: Bool
        /// A freshly picked photo (camera or library), not yet uploaded — uploaded on Save.
        var pendingPhoto: Data?
        /// The existing photo bytes loaded from Storage in edit mode, for display.
        var loadedPhoto: Data?
        /// AI plant-identify in flight — drives the button spinner.
        var isIdentifying: Bool = false
        /// Show the "AI suggestion — edit anything" caption under the filled fields (set after a
        /// successful identify; cleared once the user, e.g., re-picks a photo).
        var showAISuggestion: Bool = false
        /// A warm inline note under the identify button for a low-confidence / failed identify.
        var identifyNote: String?
        /// Family-Brain documents linked to this pet (P10 "Vet records" timeline), newest first.
        /// Loaded one-shot in `.task` for pets only.
        var petDocs: [FamilyDomain.Document] = []

        public init(item: CareItem, isEditing: Bool) {
            self.item = item
            self.isEditing = isEditing
        }

        /// The photo to render now: a fresh pick wins over the loaded one.
        var displayPhoto: Data? { pendingPhoto ?? loadedPhoto }
        /// This form is editing a plant — drives plant-flavored copy, option sets, and the photo /
        /// species / notes fields.
        var isPlant: Bool { item.kind == .plant }
        /// This form is editing a pet (P10) — drives the photo (shared with plants), breed, birthday,
        /// and vet sections. No species / AI-identify (that stays plant-only).
        var isPet: Bool { item.kind == .pet }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case saveTapped
        case deleteTapped
        case addTaskTapped
        case addPresetTask(PlantCarePreset)
        case removeTask(id: String)
        case photoPicked(Data)
        case photoLoaded(Data?)
        case docsLoaded([FamilyDomain.Document])
        case identifyTapped
        case identifyResponse(PlantIdentification?)
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum Delegate: Equatable { case didChange }
    }

    public init() {}

    @Dependency(\.dismiss) var dismiss

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    /// Weave the AI light phrase into the care notes, e.g. light "Bright indirect" + notes "Water when
    /// the top inch is dry." → "Bright indirect light. Water when the top inch is dry." Either side may
    /// be empty; returns `nil` only when both are.
    static func composedCareNotes(light: String?, notes: String?) -> String? {
        var parts: [String] = []
        if let light = light?.trimmingCharacters(in: .whitespacesAndNewlines), !light.isEmpty {
            // Avoid "light light" if the phrase already says it; keep the sentence terminated.
            var phrase = light.lowercased().contains("light") ? light : "\(light) light"
            if !phrase.hasSuffix(".") { phrase += "." }
            parts.append(phrase)
        }
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            parts.append(notes)
        }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                // Edit mode: fetch the existing photo for display (best-effort). Pets also load their
                // linked Family-Brain documents for the "Vet records" timeline.
                let photoPath: String? = {
                    guard state.loadedPhoto == nil, let p = state.item.photoPath, !p.isEmpty else { return nil }
                    return p
                }()
                let petID = state.isPet ? state.item.id : nil
                guard photoPath != nil || petID != nil else { return .none }
                let hid = hid()
                return .run { send in
                    @Dependency(\.storage) var storage
                    @Dependency(\.persistence) var persistence
                    if let photoPath {
                        await send(.photoLoaded(try? await storage.downloadData(photoPath)))
                    }
                    if let petID, let hid {
                        let docs = ((try? await persistence.documents(hid)) ?? [])
                            .filter { $0.linkedPetIds.contains(petID) }
                        await send(.docsLoaded(docs))
                    }
                }

            case let .photoLoaded(data):
                state.loadedPhoto = data
                return .none

            case let .docsLoaded(docs):
                // Newest first — by the document's own date, falling back to when it was filed.
                state.petDocs = docs.sorted { ($0.docDate ?? $0.createdAt) > ($1.docDate ?? $1.createdAt) }
                return .none

            case let .photoPicked(data):
                state.pendingPhoto = data
                // A new photo invalidates any prior AI suggestion / note.
                state.showAISuggestion = false
                state.identifyNote = nil
                return .none

            case .identifyTapped:
                guard let source = state.displayPhoto, !state.isIdentifying else { return .none }
                state.isIdentifying = true
                state.identifyNote = nil
                state.showAISuggestion = false
                return .run { send in
                    @Dependency(\.plants) var plants
                    // Send the same compressed JPEG the form would upload on Save.
                    let jpeg = CarePhotoProcessing.compressedJPEG(from: source) ?? source
                    do {
                        await send(.identifyResponse(try await plants.identify(jpeg)))
                    } catch {
                        await send(.identifyResponse(nil))   // nil ⇒ the call failed
                    }
                }

            case let .identifyResponse(result):
                state.isIdentifying = false
                // Failure, low confidence, or an "Unknown" result → fill nothing, show a warm note.
                guard let result, !result.isLowConfidence, !result.isUnknown else {
                    state.identifyNote = "Couldn't tell from this photo — try a closer shot of the leaves."
                    return .none
                }
                state.item.species = result.commonName
                state.item.speciesLatin = result.latinName?.blankToNil
                state.item.careNotes = Self.composedCareNotes(light: result.light, notes: result.careNotes)
                // Don't-stomp: only apply the AI cadence if the "Water" task is still the untouched
                // 7-day default. A user who deliberately changed it keeps their choice.
                if let water = result.waterIntervalDays,
                   let idx = state.item.tasks.firstIndex(where: {
                       $0.title.lowercased() == "water" && $0.intervalDays == 7
                   }) {
                    state.item.tasks[idx].intervalDays = water
                }
                state.showAISuggestion = true
                return .none

            case .addTaskTapped:
                let interval = CareItem.intervalChoices(for: state.item.kind).first(where: { $0 != nil }) ?? 30
                state.item.tasks.append(CareTask(title: "", intervalDays: interval))
                return .none

            case let .addPresetTask(preset):
                // P19-C1: a plant-care preset seeds title + cadence (still editable). No dedupe — a
                // plant may legitimately carry two of the same kind on different schedules.
                state.item.tasks.append(CareTask(title: preset.title, intervalDays: preset.intervalDays))
                return .none

            case let .removeTask(id):
                state.item.tasks.removeAll { $0.id == id }
                return .none

            case .saveTapped:
                // BUG FIX (P9.1): the Planta-style "photo → Identify from photo → Save" flow fills
                // `species` (the identified common name), NOT `name` — and the Save button is never
                // disabled. Before this, saving with a blank name silently no-op'd (guard → .none),
                // which read to Michael as "Save doesn't work for new plants." Fall back to the
                // identified species (then the botanical name) so an identified plant always saves.
                if state.item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let fallback = (state.item.species ?? state.item.speciesLatin)?.blankToNil {
                    state.item.name = fallback
                }
                guard let hid = hid(),
                      !state.item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return .none }
                var item = state.item
                // Trim empty-title tasks and normalize blank optional text to nil.
                item.tasks.removeAll { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                item.location = item.location?.blankToNil
                item.species = item.species?.blankToNil
                item.careNotes = item.careNotes?.blankToNil
                item.careContext = item.careContext?.blankToNil
                item.breed = item.breed?.blankToNil
                item.vetName = item.vetName?.blankToNil
                item.vetPhone = item.vetPhone?.blankToNil
                let base = item
                let pending = state.pendingPhoto
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    @Dependency(\.storage) var storage
                    var toSave = base
                    // Upload a freshly picked photo first (compressed ≤1200px), then persist with its
                    // path. Upload failure degrades gracefully — the item still saves without a photo.
                    if let pending {
                        let jpeg = CarePhotoProcessing.compressedJPEG(from: pending) ?? pending
                        if let path = try? await storage.uploadCarePhoto(hid, toSave.id, jpeg) {
                            toSave.photoPath = path
                        }
                    }
                    try await persistence.saveCareItem(hid, toSave)
                    await send(.delegate(.didChange))
                    await dismiss()
                }

            case .deleteTapped:
                guard let hid = hid() else { return .none }
                let id = state.item.id
                let photoPath = state.item.photoPath
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    @Dependency(\.storage) var storage
                    try await persistence.deleteCareItem(hid, id)
                    if let photoPath, !photoPath.isEmpty {
                        try? await storage.deletePaths([photoPath])   // best-effort photo cleanup
                    }
                    await send(.delegate(.didChange))
                    await dismiss()
                }

            case .delegate, .binding:
                return .none
            }
        }
    }
}

private extension String {
    /// `nil` when this string is empty after trimming whitespace; otherwise itself.
    var blankToNil: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

/// JPEG compression + downscaling for care-item (plant) photos — the same idiom as the Family-Brain
/// document intake, tuned smaller (a 1200px long edge is plenty for a thumbnail-first plant photo).
enum CarePhotoProcessing {
    static func compressedJPEG(from data: Data, maxEdge: CGFloat = 1200, quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let resized: UIImage
        if longest > maxEdge, longest > 0 {
            let scale = maxEdge / longest
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            resized = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        } else {
            resized = image
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

public struct CareItemFormView: View {
    @Bindable var store: StoreOf<CareItemFormReducer>
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    private let columns = Array(repeating: GridItem(.flexible()), count: 4)

    public init(store: StoreOf<CareItemFormReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(nameHeader) {
                    TextField(namePlaceholder, text: $store.item.name)
                        .accessibilityIdentifier("care-name-field")
                }

                // Photo is shared plant↔pet; species/notes stay plant-only; breed/birthday/vet pet-only.
                if store.isPlant || store.isPet {
                    photoSection
                }
                if store.isPlant {
                    speciesSection
                }
                if store.isPet {
                    breedSection
                    birthdaySection
                    vetSection
                    vetRecordsSection
                }

                Section("Icon") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(CareItem.iconOptions(for: store.item.kind), id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.title2)
                                .foregroundStyle(store.item.iconSymbol == symbol ? Color.bacanGreen : Color.inkSoft)
                                .frame(width: 40, height: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(store.item.iconSymbol == symbol ? Color.bacanGreen.opacity(0.15) : .clear)
                                )
                                .onTapGesture { store.item.iconSymbol = symbol }
                                .accessibilityIdentifier("care-icon-\(symbol)")
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Location") {
                    TextField(store.isPlant ? "Living room window (optional)" : "Where? (optional)", text: Binding(
                        get: { store.item.location ?? "" },
                        set: { store.item.location = $0 }
                    ))
                    .accessibilityIdentifier("care-location-field")
                }

                Section("Tasks") {
                    ForEach($store.item.tasks) { $task in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Task", text: $task.title)
                            Picker("Repeats", selection: $task.intervalDays) {
                                ForEach(CareItem.intervalChoices(for: store.item.kind), id: \.self) { choice in
                                    Text(CareItem.intervalLabel(choice)).tag(choice)
                                }
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { indexSet in
                        for i in indexSet { store.send(.removeTask(id: store.item.tasks[i].id)) }
                    }
                    // Plants get a preset picker (P19-C1) — Water, Fertilize, Re-pot, Prune, Rotate,
                    // Mist, Clean leaves, Pest check, each pre-filling title + cadence + glyph. Other
                    // kinds keep the plain blank-task add.
                    if store.isPlant {
                        addCareTaskMenu
                    } else {
                        Button {
                            store.send(.addTaskTapped)
                        } label: {
                            Label("Add a task", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("add-care-task-button")
                    }
                }

                if store.isEditing {
                    Section {
                        Button(deleteLabel, role: .destructive) {
                            store.send(.deleteTapped)
                        }
                        .accessibilityIdentifier("delete-care-button")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveTapped) }
                        .accessibilityIdentifier("save-care-button")
                }
            }
            .task { store.send(.task) }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        store.send(.photoPicked(data))
                    }
                    pickerItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CarePhotoCamera(
                    onCapture: { data in store.send(.photoPicked(data)); showCamera = false },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
        }
    }

    private var navTitle: String {
        if store.isPlant { return store.isEditing ? "Edit plant" : "New plant" }
        if store.isPet { return store.isEditing ? "Edit pet" : "New pet" }
        if store.item.kind == .zone { return store.isEditing ? "Edit yard zone" : "New yard zone" }
        return store.isEditing ? "Edit care item" : "New care item"
    }

    private var nameHeader: String {
        if store.isPlant { return "Plant" }
        if store.isPet { return "Pet" }
        return "Name"
    }

    private var namePlaceholder: String {
        if store.isPlant { return "What's it called?" }
        if store.isPet { return "Who's the pet?" }
        return "What needs care?"
    }

    private var deleteLabel: String {
        if store.isPlant { return "Delete plant" }
        if store.isPet { return "Delete pet" }
        return "Delete"
    }

    // MARK: Plant care-task presets (P19-C1)

    /// The plant "Add care task" affordance — a menu of the eight well-defined presets. Each pre-fills
    /// title + cadence + glyph (still editable in the task row above).
    @ViewBuilder
    private var addCareTaskMenu: some View {
        Menu {
            ForEach(PlantCarePreset.allCases) { preset in
                Button {
                    store.send(.addPresetTask(preset))
                } label: {
                    Label("\(preset.title) · \(preset.cadenceCaption.lowercased())", systemImage: preset.symbol)
                }
                .accessibilityIdentifier("care-preset-\(preset.rawValue)")
            }
        } label: {
            Label("Add care task", systemImage: "plus")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("add-care-task-button")
    }

    // MARK: Plant photo

    @ViewBuilder
    private var photoSection: some View {
        Section("Photo") {
            HStack(spacing: 14) {
                photoThumbnail
                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choose photo", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("plant-photo-picker")

                    // The in-app camera is unreliable on the simulator (reports available, then
                    // presents a broken picker) — same guard as the document scanner.
                    #if !targetEnvironment(simulator)
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take photo", systemImage: "camera")
                    }
                    .accessibilityIdentifier("plant-photo-camera")
                    #endif
                }
                Spacer()
            }
            // P9-C2 — AI plant identify: runs the `identifyPlant` Claude-vision callable on the
            // compressed photo → fills species / speciesLatin / careNotes and (don't-stomp) the Water
            // cadence. Plant-only — pets share the photo picker but have no AI-identify.
            if store.isPlant {
                Button {
                    store.send(.identifyTapped)
                } label: {
                    HStack(spacing: 8) {
                        if store.isIdentifying {
                            ProgressView().controlSize(.small)
                            Text("Identifying…")
                        } else {
                            Label("Identify from photo", systemImage: "sparkles")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(store.displayPhoto == nil || store.isIdentifying)
                .accessibilityIdentifier("plant-identify-button")

                if let note = store.identifyNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                        .accessibilityIdentifier("plant-identify-note")
                }
            }
        }
    }

    @ViewBuilder
    private var photoThumbnail: some View {
        // Pets get a sky-tinted pawprint fallback; plants a green leaf.
        let tint = store.isPet ? Color.sky : Color.bacanGreen
        let fallback = store.isPet ? "pawprint.fill" : "leaf.fill"
        Group {
            if let data = store.displayPhoto, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(tint.opacity(0.15))
                    Image(systemName: fallback).font(.title2).foregroundStyle(tint)
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .accessibilityIdentifier("plant-photo-thumbnail")
    }

    @ViewBuilder
    private var speciesSection: some View {
        Section("Species") {
            TextField("e.g. Monstera deliciosa", text: Binding(
                get: { store.item.species ?? "" },
                set: { store.item.species = $0 }
            ))
            .accessibilityIdentifier("plant-species-field")
        }
        Section("Light") {
            Picker("Light level", selection: Binding(
                get: { store.item.lightLevel ?? "" },
                set: { store.item.lightLevel = $0.isEmpty ? nil : $0 }
            )) {
                Text("—").tag("")
                ForEach(CareItem.lightLevelChoices, id: \.self) { level in
                    Text(level).tag(level)
                }
            }
            .accessibilityIdentifier("plant-light-picker")
        }
        Section("Notes") {
            TextField("Care notes (light, watering quirks…)", text: Binding(
                get: { store.item.careNotes ?? "" },
                set: { store.item.careNotes = $0 }
            ), axis: .vertical)
            .lineLimit(1...4)
            .accessibilityIdentifier("plant-notes-field")

            if store.showAISuggestion {
                Label("AI suggestion — edit anything", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
                    .accessibilityIdentifier("plant-ai-suggestion-caption")
            }
        }
        // P19-C3 — the plant's SITUATION: context the AI troubleshooter uses to adapt its diagnosis
        // and watering cadence. Distinct from care notes (generic advice).
        Section {
            TextField("Pot type, indoor/outdoor, light, drafts…", text: Binding(
                get: { store.item.careContext ?? "" },
                set: { store.item.careContext = $0 }
            ), axis: .vertical)
            .lineLimit(1...4)
            .accessibilityIdentifier("plant-context-field")
        } header: {
            Text("Its situation")
        } footer: {
            Text("Pot & soil, indoor/outdoor, light — helps Bacán tune its care")
        }
    }

    // MARK: Pet (P10)

    @ViewBuilder
    private var breedSection: some View {
        Section("Breed") {
            TextField("e.g. Chihuahua mix", text: Binding(
                get: { store.item.breed ?? "" },
                set: { store.item.breed = $0 }
            ))
            .accessibilityIdentifier("pet-breed-field")
        }
    }

    @ViewBuilder
    private var birthdaySection: some View {
        Section("Birthday") {
            Toggle("Set a birthday", isOn: Binding(
                get: { store.item.birthday != nil },
                set: { store.item.birthday = $0 ? (store.item.birthday ?? Date()) : nil }
            ))
            .accessibilityIdentifier("pet-birthday-toggle")

            if let birthday = store.item.birthday {
                DatePicker(
                    "Birthday",
                    selection: Binding(get: { birthday }, set: { store.item.birthday = $0 }),
                    displayedComponents: .date
                )
                .accessibilityIdentifier("pet-birthday-picker")
            }
        }
    }

    @ViewBuilder
    private var vetSection: some View {
        Section("Vet") {
            TextField("Vet name (optional)", text: Binding(
                get: { store.item.vetName ?? "" },
                set: { store.item.vetName = $0 }
            ))
            .accessibilityIdentifier("pet-vet-name-field")

            TextField("Vet phone (optional)", text: Binding(
                get: { store.item.vetPhone ?? "" },
                set: { store.item.vetPhone = $0 }
            ))
            .keyboardType(.phonePad)
            .accessibilityIdentifier("pet-vet-phone-field")
        }
    }

    /// P10 — the pet's document timeline: Family-Brain documents linked to this pet, newest first.
    /// Each row shows the doc title + the existing expiry/due countdown chip; tapping pushes the real
    /// ``DocumentDetailView`` (ChoresFeature → DocsFeature is cycle-free). Empty state nudges a scan.
    @ViewBuilder
    private var vetRecordsSection: some View {
        Section("Vet records") {
            if store.petDocs.isEmpty {
                Text("No records yet — scan the vet paperwork and it'll file itself.")
                    .font(.caption).foregroundStyle(Color.inkSoft)
                    .accessibilityIdentifier("pet-vet-records-empty")
            } else {
                ForEach(store.petDocs) { doc in
                    NavigationLink {
                        DocumentDetailView(
                            store: Store(initialState: DocumentDetailReducer.State(doc: doc)) {
                                DocumentDetailReducer()
                            }
                        )
                    } label: {
                        vetRecordRow(doc)
                    }
                    .accessibilityIdentifier("pet-vet-record-\(doc.id)")
                }
            }
        }
    }

    private func vetRecordRow(_ doc: FamilyDomain.Document) -> some View {
        HStack(spacing: 10) {
            Image(systemName: doc.type.symbolName)
                .font(.subheadline)
                .foregroundStyle(Color.sky)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(doc.title).foregroundStyle(Color.ink)
                if let expiry = doc.expiryDate {
                    DocumentDateChip(date: expiry, kind: .expiry)
                } else if let due = doc.dueDate {
                    DocumentDateChip(date: due, kind: .due)
                }
            }
        }
    }
}

/// Wraps `UIImagePickerController` (`.camera`) to photograph a plant. The captured image is encoded
/// to JPEG `Data` and handed to `onCapture` (the reducer compresses/uploads on Save). Mirrors the
/// wine-label capture; a custom `AVCaptureSession` is out of scope. Shared by the edit form and the
/// P9.1 plant capture wizard.
struct CarePhotoCamera: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.9)
            else { onCancel(); return }
            onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}
