import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import PhotosUI
import StorageClient
import SwiftUI
import UIKit
import UserDomain

/// P9.1 — the Planta-inspired **add-a-plant capture wizard**. Adding a plant should feel like adopting
/// it: photograph it, watch it get identified, name it, give it a home, and say when it last drank —
/// then a care plan appears with a little "welcome home" beat. EDIT stays on the kind-parametrized
/// ``CareItemFormReducer``; only the ADD entry routes here.
///
/// The wizard NEVER traps: every step is skippable and back-navigable, and it degrades gracefully when
/// there's no photo (skip straight to a manual name) or the identify call fails / is low-confidence.
@Reducer
public struct PlantCaptureReducer {
    /// The steps, in order. `welcome` is the finale (no progress dots).
    public enum Step: Int, CaseIterable, Equatable, Sendable {
        case photo, identify, nickname, home, watering, welcome
        /// Steps that show progress dots (everything up to, but not including, the welcome beat).
        static let dotted: [Step] = [.photo, .identify, .nickname, .home, .watering]
    }

    /// "When did it last get a drink?" — sets the seeded Water task's `lastDoneAt` so the schedule
    /// starts honestly. `noIdea` leaves it never-done ⇒ due today.
    public enum WaterAnchor: String, CaseIterable, Equatable, Sendable {
        case today, fewDays, overWeek, noIdea

        var label: String {
            switch self {
            case .today: "Today"
            case .fewDays: "A few days ago"
            case .overWeek: "Over a week"
            case .noIdea: "No idea"
            }
        }

        /// The `lastDoneAt` this anchor implies. `noIdea` ⇒ `nil` (never-done ⇒ due today).
        func lastDoneAt(now: Date = Date()) -> Date? {
            let cal = Calendar.current
            switch self {
            case .today: return now
            case .fewDays: return cal.date(byAdding: .day, value: -3, to: now)
            case .overWeek: return cal.date(byAdding: .day, value: -8, to: now)
            case .noIdea: return nil
            }
        }
    }

    @ObservableState
    public struct State: Equatable {
        /// Stable id up-front so the photo uploads to `care/{id}/photo.jpg` and the saved item matches.
        var itemID: String
        var step: Step = .photo
        /// A freshly picked/captured photo (uploaded on create). `nil` ⇒ leaf glyph everywhere.
        var pendingPhoto: Data?
        /// AI identify in flight — drives the shimmer "Getting to know it…" state.
        var isIdentifying: Bool = false
        /// The identify result once it lands (used only to tone the reveal caption).
        var identification: PlantIdentification?
        /// `true` once identify returned nothing usable (failure / low confidence / unknown) — the
        /// reveal degrades to a warm "What do you call it?" nudge.
        var identifyFailed: Bool = false
        /// Editable identified common name (shown big in the reveal, prefills the nickname).
        var species: String = ""
        /// Editable botanical name (shown italic).
        var speciesLatin: String = ""
        /// AI care-notes preview (editable downstream via the edit form).
        var careNotes: String = ""
        /// The user's pet name for the plant.
        var nickname: String = ""
        /// Where it lives (freeform + chips).
        var location: String = ""
        /// One of ``CareItem/lightLevelChoices``.
        var lightLevel: String?
        /// Water cadence — AI suggestion or the 7-day default.
        var waterIntervalDays: Int = 7
        /// When it last drank (nil until a chip is tapped ⇒ treated as never-done ⇒ due today).
        var wateringAnchor: WaterAnchor?
        /// Existing care-item locations, for the Home step's quick chips (dedup'd, order-stable).
        var existingLocations: [String]
        /// Reveal is showing the manual "type the species" field ("Not right?").
        var manualSpecies: Bool = false
        var isSaving: Bool = false
        var saveError: String?

        public init(itemID: String = UUID().uuidString, existingLocations: [String] = []) {
            self.itemID = itemID
            self.existingLocations = existingLocations
        }

        /// The name the plant will be saved under: the nickname, falling back to the identified
        /// species, then a gentle default — so the wizard can never produce a nameless plant.
        var effectiveName: String {
            nickname.wizardBlankToNil ?? species.wizardBlankToNil ?? "New plant"
        }

        /// The confidence-toned caption under the reveal name.
        var revealCaption: String {
            guard let c = identification?.confidence.lowercased() else { return "Best guess — correct me" }
            switch c {
            case "high": return "Pretty sure"
            case "medium": return "Fairly confident — tweak if I'm off"
            default: return "Best guess — correct me"
            }
        }

        /// Assemble the `CareItem` this wizard is building.
        func buildItem(now: Date = Date()) -> CareItem {
            CareItem(
                id: itemID,
                kind: .plant,
                name: effectiveName,
                iconSymbol: "leaf.fill",
                location: location.wizardBlankToNil,
                tasks: [CareTask(
                    title: "Water",
                    intervalDays: waterIntervalDays,
                    lastDoneAt: wateringAnchor?.lastDoneAt(now: now)
                )],
                species: species.wizardBlankToNil,
                speciesLatin: speciesLatin.wizardBlankToNil,
                careNotes: careNotes.wizardBlankToNil,
                lightLevel: lightLevel?.wizardBlankToNil
            )
        }
    }

    public enum Action: Equatable, BindableAction {
        case photoPicked(Data)
        case skipPhotoTapped
        case identifyStart
        case identifyResponse(PlantIdentification?)
        case notRightTapped
        case backTapped
        case nextTapped
        case locationChipTapped(String)
        case lightTapped(String)
        case anchorTapped(WaterAnchor)
        case createTapped
        case created
        case createFailed
        case finishTapped
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum Delegate: Equatable { case didFinish }
    }

    public init() {}

    @Dependency(\.dismiss) var dismiss

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case let .photoPicked(data):
                state.pendingPhoto = data
                state.step = .identify
                state.isIdentifying = true
                state.identifyFailed = false
                return .send(.identifyStart)

            case .skipPhotoTapped:
                // No photo → no identify; go straight to a warm manual name entry.
                state.step = .nickname
                return .none

            case .identifyStart:
                guard let source = state.pendingPhoto else {
                    state.isIdentifying = false
                    state.identifyFailed = true
                    return .none
                }
                state.isIdentifying = true
                return .run { send in
                    @Dependency(\.plants) var plants
                    let jpeg = CarePhotoProcessing.compressedJPEG(from: source) ?? source
                    do {
                        await send(.identifyResponse(try await plants.identify(jpeg)))
                    } catch {
                        await send(.identifyResponse(nil))
                    }
                }

            case let .identifyResponse(result):
                state.isIdentifying = false
                guard let result, !result.isLowConfidence, !result.isUnknown else {
                    // Warm no-fill: keep the fields blank and let the reveal nudge a manual name.
                    state.identifyFailed = true
                    state.identification = result
                    return .none
                }
                state.identification = result
                state.species = result.commonName
                state.speciesLatin = result.latinName ?? ""
                state.careNotes = CareItemFormReducer.composedCareNotes(
                    light: result.light, notes: result.careNotes
                ) ?? ""
                if let water = result.waterIntervalDays { state.waterIntervalDays = water }
                if let light = result.light, let match = Self.matchLight(light) { state.lightLevel = match }
                return .none

            case .notRightTapped:
                state.manualSpecies = true
                return .none

            case .backTapped:
                state.step = Step(rawValue: max(0, state.step.rawValue - 1)) ?? .photo
                return .none

            case .nextTapped:
                switch state.step {
                case .identify:
                    // Carry the identified name into the nickname field as a prefill.
                    if state.nickname.wizardBlankToNil == nil {
                        state.nickname = state.species
                    }
                    state.step = .nickname
                case .nickname:
                    state.step = .home
                case .home:
                    state.step = .watering
                default:
                    break
                }
                return .none

            case let .locationChipTapped(loc):
                state.location = loc
                return .none

            case let .lightTapped(level):
                state.lightLevel = (state.lightLevel == level) ? nil : level
                return .none

            case let .anchorTapped(anchor):
                state.wateringAnchor = anchor
                return .none

            case .createTapped:
                guard let hid = hid(), !state.isSaving else { return .none }
                state.isSaving = true
                state.saveError = nil
                let item = state.buildItem()
                let pending = state.pendingPhoto
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    @Dependency(\.storage) var storage
                    var toSave = item
                    if let pending {
                        let jpeg = CarePhotoProcessing.compressedJPEG(from: pending) ?? pending
                        if let path = try? await storage.uploadCarePhoto(hid, toSave.id, jpeg) {
                            toSave.photoPath = path
                        }
                    }
                    do {
                        try await persistence.saveCareItem(hid, toSave)
                        await send(.created)
                    } catch {
                        await send(.createFailed)
                    }
                }

            case .created:
                state.isSaving = false
                state.step = .welcome
                return .none

            case .createFailed:
                state.isSaving = false
                state.saveError = "Couldn't save just now — check your connection and try again."
                return .none

            case .finishTapped:
                return .run { send in
                    await send(.delegate(.didFinish))
                    await dismiss()
                }

            case .delegate, .binding:
                return .none
            }
        }
    }

    /// Map a free-text AI light phrase onto one of ``CareItem/lightLevelChoices`` (case/substring
    /// tolerant): "bright, indirect light" → "Bright indirect", "full sun" → "Direct sun".
    static func matchLight(_ phrase: String) -> String? {
        let p = phrase.lowercased()
        if p.contains("direct sun") || p.contains("full sun") { return "Direct sun" }
        if p.contains("bright") { return "Bright indirect" }
        if p.contains("low") || p.contains("shade") { return "Low" }
        if p.contains("medium") || p.contains("partial") { return "Medium" }
        return nil
    }
}

// MARK: - View

public struct PlantCaptureView: View {
    @Bindable var store: StoreOf<PlantCaptureReducer>
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var welcomeUnfurl = false

    public init(store: StoreOf<PlantCaptureReducer>) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            Color.familyCanvas.ignoresSafeArea()
            switch store.step {
            case .photo: photoStep
            case .identify: identifyStep
            case .nickname: nicknameStep
            case .home: homeStep
            case .watering: wateringStep
            case .welcome: welcomeStep
            }
        }
        .animation(.snappy, value: store.step)
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

    // MARK: Chrome

    /// Subtle step dots — filled up to and including the current step.
    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(PlantCaptureReducer.Step.dotted, id: \.rawValue) { s in
                Circle()
                    .fill(s.rawValue <= store.step.rawValue ? Color.bacanGreen : Color.inkSoft.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityIdentifier("plant-capture-dots")
    }

    private func topBar(showBack: Bool) -> some View {
        HStack {
            if showBack {
                Button { store.send(.backTapped) } label: {
                    Image(systemName: "chevron.left").font(.headline).foregroundStyle(Color.ink)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("plant-capture-back")
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
            Spacer()
            progressDots
            Spacer()
            Button { store.send(.finishTapped) } label: {
                Image(systemName: "xmark").font(.subheadline).foregroundStyle(Color.inkSoft)
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("plant-capture-close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// The picked photo as a soft full-width backdrop, else a friendly leaf plate.
    @ViewBuilder
    private func photoBackdrop(height: CGFloat) -> some View {
        Group {
            if let data = store.pendingPhoto, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.bacanGreen.opacity(0.12)
                    Image(systemName: "leaf.fill").font(.system(size: 56)).foregroundStyle(Color.bacanGreen)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func primaryButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.bacanGreen, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier(id)
    }

    // MARK: Step 1 — Photo

    private var photoStep: some View {
        VStack(spacing: 0) {
            topBar(showBack: false)
            Spacer()
            VStack(spacing: 20) {
                photoBackdrop(height: 300)
                    .overlay(alignment: .bottomLeading) {
                        Text("Let's meet your plant.")
                            .font(.system(.largeTitle, design: .rounded)).bold()
                            .foregroundStyle(store.pendingPhoto == nil ? Color.ink : .white)
                            .shadow(radius: store.pendingPhoto == nil ? 0 : 8)
                            .padding(20)
                    }
                VStack(spacing: 12) {
                    #if !targetEnvironment(simulator)
                    primaryButton("Take a photo", id: "plant-capture-camera") { showCamera = true }
                    #endif
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Text(cameraAvailable ? "Choose from library" : "Choose a photo")
                            .font(.headline)
                            .foregroundStyle(Color.bacanGreen)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Color.bacanGreen.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .accessibilityIdentifier("plant-capture-photo-picker")
                    Button("Skip for now") { store.send(.skipPhotoTapped) }
                        .font(.subheadline).foregroundStyle(Color.inkSoft)
                        .padding(.top, 4)
                        .accessibilityIdentifier("plant-capture-skip-photo")
                }
            }
            .padding(.horizontal, 20)
            Spacer()
        }
    }

    private var cameraAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    // MARK: Step 2 — Identify reveal

    private var identifyStep: some View {
        VStack(spacing: 0) {
            topBar(showBack: true)
            Spacer()
            VStack(spacing: 20) {
                photoBackdrop(height: 220)
                if store.isIdentifying {
                    identifyingShimmer
                } else {
                    revealCard
                }
            }
            .padding(.horizontal, 20)
            Spacer()
            if !store.isIdentifying {
                primaryButton("Looks right", id: "plant-capture-identify-next") { store.send(.nextTapped) }
                    .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
    }

    private var identifyingShimmer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Getting to know it…")
                .font(.system(.title2, design: .rounded)).bold().foregroundStyle(Color.ink)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 6).frame(width: 200, height: 22)
                RoundedRectangle(cornerRadius: 6).frame(width: 140, height: 14)
                RoundedRectangle(cornerRadius: 6).frame(maxWidth: .infinity).frame(height: 14)
            }
            .foregroundStyle(Color.inkSoft.opacity(0.25))
            .redacted(reason: .placeholder)
            .shimmering()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("plant-capture-identifying")
    }

    @ViewBuilder
    private var revealCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.identifyFailed {
                Text("What do you call it?")
                    .font(.system(.title, design: .rounded)).bold().foregroundStyle(Color.ink)
                Text("Couldn't tell from this photo — no worries, name it yourself next.")
                    .font(.subheadline).foregroundStyle(Color.inkSoft)
            } else {
                if store.manualSpecies {
                    TextField("Type the species", text: $store.species)
                        .font(.system(.title, design: .rounded)).bold()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("plant-capture-species-field")
                } else {
                    TextField("Common name", text: $store.species)
                        .font(.system(.title, design: .rounded)).bold()
                        .foregroundStyle(Color.ink)
                        .accessibilityIdentifier("plant-capture-name-field")
                }
                if store.speciesLatin.wizardBlankToNil != nil {
                    Text(store.speciesLatin).font(.callout).italic().foregroundStyle(Color.inkSoft)
                }
                Text(store.revealCaption)
                    .font(.caption).foregroundStyle(Color.bacanGreen)
                    .accessibilityIdentifier("plant-capture-reveal-caption")
                if store.careNotes.wizardBlankToNil != nil {
                    Text(store.careNotes)
                        .font(.footnote).foregroundStyle(Color.inkSoft)
                        .lineLimit(3)
                        .padding(.top, 2)
                }
                HStack(spacing: 8) {
                    Label("Water every \(store.waterIntervalDays)d", systemImage: "drop.fill")
                        .font(.caption).foregroundStyle(Color.bacanGreen)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.bacanGreen.opacity(0.12), in: Capsule())
                    Button("Not right?") { store.send(.notRightTapped) }
                        .font(.caption).foregroundStyle(Color.inkSoft)
                        .accessibilityIdentifier("plant-capture-not-right")
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Step 3 — Nickname

    private var nicknameStep: some View {
        VStack(spacing: 0) {
            topBar(showBack: true)
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                Text("What do you call it?")
                    .font(.system(.largeTitle, design: .rounded)).bold().foregroundStyle(Color.ink)
                Text("Monstera, Monty, Señor Hojas — your call.")
                    .font(.subheadline).foregroundStyle(Color.inkSoft)
                TextField("A name", text: $store.nickname)
                    .font(.title3)
                    .padding(14)
                    .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("plant-capture-nickname-field")
            }
            .padding(.horizontal, 20)
            Spacer()
            primaryButton("Next", id: "plant-capture-nickname-next") { store.send(.nextTapped) }
                .padding(.horizontal, 20).padding(.bottom, 24)
        }
    }

    // MARK: Step 4 — Home (location + light)

    private var homeStep: some View {
        VStack(spacing: 0) {
            topBar(showBack: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Where does it live?")
                        .font(.system(.largeTitle, design: .rounded)).bold().foregroundStyle(Color.ink)
                    TextField("A room or spot", text: $store.location)
                        .font(.title3)
                        .padding(14)
                        .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityIdentifier("plant-capture-location-field")
                    FlowChips(items: locationChips) { chip in
                        Button { store.send(.locationChipTapped(chip)) } label: {
                            chipLabel(chip, selected: store.location == chip)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("plant-capture-loc-chip-\(chip)")
                    }
                    Text("How's the light?")
                        .font(.headline).foregroundStyle(Color.ink).padding(.top, 6)
                    FlowChips(items: CareItem.lightLevelChoices) { level in
                        Button { store.send(.lightTapped(level)) } label: {
                            chipLabel(level, selected: store.lightLevel == level)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("plant-capture-light-\(level)")
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8)
            }
            primaryButton("Next", id: "plant-capture-home-next") { store.send(.nextTapped) }
                .padding(.horizontal, 20).padding(.bottom, 24)
        }
    }

    /// Existing locations first (dedup'd), then defaults not already present.
    private var locationChips: [String] {
        let defaults = ["Living room", "Kitchen", "Bedroom", "Office", "Porch"]
        var seen = Set<String>()
        var out: [String] = []
        for loc in store.existingLocations + defaults where !loc.isEmpty {
            let key = loc.lowercased()
            if seen.insert(key).inserted { out.append(loc) }
        }
        return out
    }

    private func chipLabel(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(selected ? .white : Color.ink)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(selected ? Color.bacanGreen : Color.familySurface, in: Capsule())
    }

    // MARK: Step 5 — Watering anchor

    private var wateringStep: some View {
        VStack(spacing: 0) {
            topBar(showBack: true)
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                Text("When did it last get a drink?")
                    .font(.system(.largeTitle, design: .rounded)).bold().foregroundStyle(Color.ink)
                Text("So the watering schedule starts honestly.")
                    .font(.subheadline).foregroundStyle(Color.inkSoft)
                ForEach(PlantCaptureReducer.WaterAnchor.allCases, id: \.rawValue) { anchor in
                    Button { store.send(.anchorTapped(anchor)) } label: {
                        HStack {
                            Text(anchor.label).font(.headline)
                                .foregroundStyle(store.wateringAnchor == anchor ? .white : Color.ink)
                            Spacer()
                            if store.wateringAnchor == anchor {
                                Image(systemName: "checkmark").foregroundStyle(.white)
                            }
                        }
                        .padding(16)
                        .background(
                            store.wateringAnchor == anchor ? Color.bacanGreen : Color.familySurface,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("plant-capture-anchor-\(anchor.rawValue)")
                }
                if let err = store.saveError {
                    Text(err).font(.caption).foregroundStyle(Color.terracotta)
                }
            }
            .padding(.horizontal, 20)
            Spacer()
            primaryButton(store.isSaving ? "Saving…" : "Meet the family", id: "plant-capture-create") {
                store.send(.createTapped)
            }
            .disabled(store.isSaving)
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
    }

    // MARK: Step 6 — Welcome moment

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Group {
                if let data = store.pendingPhoto, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 200, height: 200).clipShape(Circle())
                } else {
                    ZStack {
                        Circle().fill(Color.bacanGreen.opacity(0.15)).frame(width: 200, height: 200)
                        Image(systemName: "leaf.fill").font(.system(size: 72)).foregroundStyle(Color.bacanGreen)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 34)).foregroundStyle(Color.bacanGreen)
                    .leafUnfurl(isOn: welcomeUnfurl, color: .bacanGreen)
                    .offset(x: 6, y: -6)
            }
            Text("Welcome home, \(store.effectiveName).")
                .font(.system(.largeTitle, design: .rounded)).bold()
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 32)
                .accessibilityIdentifier("plant-capture-welcome")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            welcomeUnfurl = true
            try? await Task.sleep(for: .milliseconds(1900))
            store.send(.finishTapped)
        }
    }
}

/// A minimal wrapping chip row (no external deps) — lays items left-to-right, wrapping to new lines.
private struct FlowChips<Content: View>: View {
    let items: [String]
    let content: (String) -> Content

    var body: some View {
        // A simple wrap via a lazy vertical stack of horizontally-grouped rows is overkill; use a
        // flexible grid that wraps naturally.
        FlexibleWrap(items: items, spacing: 8, content: content)
    }
}

/// Wraps chips onto multiple lines within the available width.
private struct FlexibleWrap<Content: View>: View {
    let items: [String]
    let spacing: CGFloat
    let content: (String) -> Content

    @State private var totalHeight: CGFloat = .zero

    var body: some View {
        GeometryReader { geo in
            self.generate(in: geo)
        }
        .frame(height: totalHeight)
    }

    private func generate(in geo: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero
        return ZStack(alignment: .topLeading) {
            ForEach(items, id: \.self) { item in
                content(item)
                    .padding(.trailing, spacing)
                    .padding(.bottom, spacing)
                    .alignmentGuide(.leading) { d in
                        if abs(width - d.width) > geo.size.width {
                            width = 0
                            height -= d.height
                        }
                        let result = width
                        if item == items.last { width = 0 } else { width -= d.width }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if item == items.last { height = 0 }
                        return result
                    }
            }
        }
        .background(HeightReader(height: $totalHeight))
    }
}

private struct HeightReader: View {
    @Binding var height: CGFloat
    var body: some View {
        GeometryReader { geo -> Color in
            DispatchQueue.main.async { self.height = geo.size.height }
            return Color.clear
        }
    }
}

private extension String {
    /// `nil` when empty after trimming — a file-local mirror of the form's helper.
    var wizardBlankToNil: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
