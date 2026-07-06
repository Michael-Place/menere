import AnalyticsClient
import ComposableArchitecture
import DocsFeature
import FamilyDomain
import FirebaseFunctions
import Foundation
import MenereUI
import PersistenceClient
import StorageClient
import SwiftUI
import UserDomain

// MARK: - Smart-capture inbox (Act V — V2-D)
//
// ONE capture surface that AI-routes a photo / voice-dictated text / typed note to the right module,
// killing the "which screen do I go to?" navigation tax. It *orchestrates* capabilities that already
// exist — `processDocument` (Family Brain), `identifyPlant` (plant ID), memory-create, list-add,
// event-create — and never files silently: every capture ends on a proposed destination with a
// one-tap confirm/override.

/// Where a captured item can land. A single enum drives both the ranked-suggestion chips and the
/// filing switch. The suggestion *set* differs by input kind (a photo can become a Brain doc / plant /
/// memory; text can become a list item / memory / reminder).
public enum CaptureDestination: String, Equatable, Sendable, Identifiable, CaseIterable {
    case brain        // Family Brain document (receipt / paperwork / medical)
    case plant        // a new plant on the care rails
    case memory       // a family scrapbook memory
    case list         // add to a shared list (groceries by default)
    case event        // a calendar reminder / event

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .brain: "Family Brain"
        case .plant: "Add a plant"
        case .memory: "A memory"
        case .list: "A list"
        case .event: "A reminder"
        }
    }

    var symbol: String {
        switch self {
        case .brain: "brain.head.profile"
        case .plant: "leaf.fill"
        case .memory: "camera.fill"
        case .list: "checklist"
        case .event: "calendar.badge.plus"
        }
    }

    var blurb: String {
        switch self {
        case .brain: "File it and let Bacán read the details"
        case .plant: "Start watering reminders for it"
        case .memory: "Save it to the family scrapbook"
        case .list: "Drop it on a shared list"
        case .event: "Put it on the family calendar"
        }
    }

    var tint: Color {
        switch self {
        case .brain: .sky
        case .plant: .bacanGreen
        case .memory: .terracotta
        case .list: .bacanGreen
        case .event: .marigold
        }
    }
}

@Reducer
public struct CaptureReducer {
    /// A lightweight plant-ID signal from the `identifyPlant` vision callable — the AI half of the
    /// photo router. Present only when a photo genuinely looks like a plant.
    public struct PlantHint: Equatable, Sendable {
        public var commonName: String
        public var latinName: String?
        public var waterIntervalDays: Int?
        public var confidence: String
        /// A confident, non-"Unknown" ID — strong enough to float "Add a plant" to the top.
        var isConfident: Bool {
            let c = confidence.lowercased()
            return (c == "high" || c == "medium")
                && commonName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "unknown"
                && !commonName.isEmpty
        }
    }

    @ObservableState
    public struct State: Equatable {
        public enum Stage: Equatable { case compose, classifying, confirm, filing, done }
        var stage: Stage = .compose

        /// Typed OR voice-dictated note (the keyboard mic dictates straight into the field — no extra
        /// speech plumbing needed).
        var text: String = ""
        /// The processed (downscaled JPEG) photo to classify + upload, and a small preview thumbnail.
        var imageJPEG: Data?
        var thumbnail: Data?

        /// The ranked destinations for the current input; `suggestions.first` is the AI/heuristic's
        /// pick and is pre-selected. The user confirms it or taps another (one-tap override).
        var suggestions: [CaptureDestination] = []
        var selected: CaptureDestination?
        var plantHint: PlantHint?

        // Loaded context so filing can target the right list + tag groceries.
        var lists: [FamilyList] = []
        var members: [HouseholdMember] = []

        // Result surface.
        var receipt: String?
        var routedTo: CaptureDestination?
        var confettiTrigger = 0
        var errorMessage: String?

        var hasInput: Bool {
            imageJPEG != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var hasPhoto: Bool { imageJPEG != nil }
        var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case task
        case contextLoaded(lists: [FamilyList], members: [HouseholdMember])
        /// A photo finished processing in the view (downscaled JPEG + preview thumbnail).
        case photoProcessed(jpeg: Data, thumbnail: Data)
        case clearPhoto
        /// "Route it" — run the classifier (a vision call for photos, heuristics for text).
        case classifyTapped
        case plantHinted(PlantHint?)
        case selectDestination(CaptureDestination)
        case editTapped              // back from confirm to compose
        case fileTapped
        case filed(receipt: String, destination: CaptureDestination)
        case fileFailed(String)
        case captureAnotherTapped
        case doneTapped
        case binding(BindingAction<State>)
        case delegate(Delegate)
    }

    public enum Delegate: Equatable {
        /// Something was filed — the parent refreshes Today's cards so the new doc/plant/event shows.
        case didFile
    }

    public init() {}

    @Dependency(\.persistence) var persistence
    @Dependency(\.storage) var storage
    @Dependency(\.docs) var docs
    @Dependency(\.analytics) var analytics
    @Dependency(\.dismiss) var dismiss

    private func ctx() -> (hid: String, uid: String)? {
        @Shared(.user) var user
        guard let hid = user?.householdId, let uid = user?.id else { return nil }
        return (hid, uid)
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                analytics.log("smart_capture_opened")
                guard let (hid, _) = ctx() else { return .none }
                return .run { send in
                    async let lists = persistence.lists(hid)
                    async let members = persistence.members(hid)
                    await send(.contextLoaded(
                        lists: (try? await lists) ?? [],
                        members: (try? await members) ?? []
                    ))
                }

            case let .contextLoaded(lists, members):
                state.lists = lists
                state.members = members
                return .none

            case let .photoProcessed(jpeg, thumbnail):
                state.imageJPEG = jpeg
                state.thumbnail = thumbnail
                return .none

            case .clearPhoto:
                state.imageJPEG = nil
                state.thumbnail = nil
                state.plantHint = nil
                return .none

            case .classifyTapped:
                guard state.hasInput else { return .none }
                // Photo → an AI vision pass (identifyPlant doubles as the plant-vs-not classifier).
                // Text → pure heuristics, so it's instant (no spinner needed).
                if let jpeg = state.imageJPEG {
                    state.stage = .classifying
                    return .run { send in
                        let hint = await Self.identifyPlant(jpeg)
                        await send(.plantHinted(hint))
                    }
                } else {
                    state.suggestions = Self.classifyText(state.trimmedText, lists: state.lists)
                    state.selected = state.suggestions.first
                    state.stage = .confirm
                    return .none
                }

            case let .plantHinted(hint):
                state.plantHint = hint
                state.suggestions = Self.classifyPhoto(plantHint: hint, hasText: !state.trimmedText.isEmpty)
                state.selected = state.suggestions.first
                state.stage = .confirm
                return .none

            case let .selectDestination(dest):
                state.selected = dest
                return .none

            case .editTapped:
                state.stage = .compose
                return .none

            case .fileTapped:
                guard let dest = state.selected, let (hid, uid) = ctx() else { return .none }
                state.stage = .filing
                state.errorMessage = nil
                let text = state.trimmedText
                let jpeg = state.imageJPEG
                let plantHint = state.plantHint
                let list = Self.targetList(state.lists)
                analytics.log("smart_capture_routed", [
                    "destination": dest.rawValue,
                    "input": jpeg != nil ? "photo" : "text",
                ])
                return .run { send in
                    do {
                        let receipt = try await Self.file(
                            dest: dest, hid: hid, uid: uid, text: text, jpeg: jpeg,
                            plantHint: plantHint, list: list,
                            persistence: persistence, storage: storage, docs: docs
                        )
                        await send(.filed(receipt: receipt, destination: dest))
                    } catch {
                        await send(.fileFailed(error.localizedDescription))
                    }
                }

            case let .filed(receipt, destination):
                state.stage = .done
                state.receipt = receipt
                state.routedTo = destination
                state.confettiTrigger += 1
                return .send(.delegate(.didFile))

            case let .fileFailed(message):
                state.stage = .confirm
                state.errorMessage = "That didn't file — \(message). Give it another try."
                return .none

            case .captureAnotherTapped:
                state = State()
                return .send(.task)

            case .doneTapped:
                return .run { _ in await dismiss() }

            case .binding, .delegate:
                return .none
            }
        }
    }

    // MARK: - Classifiers

    /// Rank the photo destinations. The AI plant-ID result is the signal: a confident, known plant
    /// floats "Add a plant" to the top; otherwise a photo is most likely paperwork (Brain), then a
    /// memory. Every option stays available for a one-tap override.
    static func classifyPhoto(plantHint: PlantHint?, hasText: Bool) -> [CaptureDestination] {
        if let hint = plantHint, hint.isConfident {
            return [.plant, .brain, .memory]
        }
        return [.brain, .memory, .plant]
    }

    /// Rank the text destinations from lightweight intent heuristics. "buy batteries" → a list;
    /// "Oliver walked today!" → a memory; "dentist Tuesday at 3" → a reminder. Ties fall back to a
    /// list (the most common quick note). Always returns all three so the user can override.
    static func classifyText(_ raw: String, lists: [FamilyList]) -> [CaptureDestination] {
        let t = " " + raw.lowercased() + " "
        func has(_ needles: [String]) -> Bool { needles.contains { t.contains($0) } }

        let eventWords = [
            "remind", "reminder", "appointment", "appt", "meeting", "deadline", "due ",
            "tomorrow", "tonight", "next week", "o'clock", " at ", "pm ", "am ", ":00",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "pick up", "drop off", "dentist", "doctor", "birthday party",
        ]
        let memoryWords = [
            "first ", " walked", " smiled", " laughed", " said ", " crawled", " rolled",
            " loved", "milestone", "cutest", " today!", "!", " took his", " took her",
            "oliver", "famfis", "francis", "fajita", "sprinkle",
        ]
        let listWords = [
            "buy ", "need ", "get ", "grab ", "pick up ", "out of ", "more ", "restock",
            "batteries", "milk", "eggs", "groceries", "add ", "toilet paper", "paper towels",
        ]

        var scores: [CaptureDestination: Int] = [.list: 0, .memory: 0, .event: 0]
        if has(listWords) { scores[.list, default: 0] += 2 }
        if has(eventWords) { scores[.event, default: 0] += 2 }
        if has(memoryWords) { scores[.memory, default: 0] += 2 }
        // A trailing "!" leans memory; a leading verb leans list — nudge the default.
        if raw.hasSuffix("!") { scores[.memory, default: 0] += 1 }

        // Stable default order for ties: list is the safest home for a quick note.
        let order: [CaptureDestination] = [.list, .event, .memory]
        return order.sorted { a, b in
            let sa = scores[a] ?? 0, sb = scores[b] ?? 0
            if sa != sb { return sa > sb }
            return (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
        }
    }

    /// The list a text capture lands on: the grocery list if there is one, else the first list.
    static func targetList(_ lists: [FamilyList]) -> FamilyList? {
        lists.first(where: { $0.isGrocery }) ?? lists.first
    }

    // MARK: - Filing

    /// Perform the write for the chosen destination through the SAME persistence/functions the owning
    /// features use — no new backend. Returns the warm success line for the receipt.
    static func file(
        dest: CaptureDestination,
        hid: String,
        uid: String,
        text: String,
        jpeg: Data?,
        plantHint: PlantHint?,
        list: FamilyList?,
        persistence: PersistenceClient,
        storage: StorageClient,
        docs: DocsClient
    ) async throws -> String {
        let now = Date()
        switch dest {
        case .brain:
            let docId = UUID().uuidString
            var pagePaths: [String] = []
            if let jpeg {
                let compressed = DocumentImageProcessing.compressedJPEG(from: jpeg) ?? jpeg
                let path = try await storage.uploadDocumentPage(hid, docId, 0, compressed)
                pagePaths.append(path)
            }
            let doc = FamilyDomain.Document(
                id: docId,
                title: defaultDocTitle(text: text, now: now),
                type: .other,
                pagePaths: pagePaths,
                notes: text.isEmpty ? nil : text,
                uploadedBy: uid,
                createdAt: now,
                processingState: .pending
            )
            try await persistence.saveDocument(hid, doc)
            // Fire the AI enrichment; the live Brain listener delivers the write-back later. Don't
            // block the receipt on it.
            Task { try? await docs.process(docId) }
            return "Filed to the Family Brain ✓ — Bacán is reading it now."

        case .plant:
            let itemId = UUID().uuidString
            var photoPath: String?
            if let jpeg { photoPath = try? await storage.uploadCarePhoto(hid, itemId, jpeg) }
            let name = plantHint?.commonName.trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty ?? (text.nonEmpty ?? "New plant")
            let interval = plantHint?.waterIntervalDays ?? 7
            let item = CareItem(
                id: itemId,
                kind: .plant,
                name: name,
                iconSymbol: "leaf.fill",
                tasks: [CareTask(title: "Water \(name)", intervalDays: interval)],
                createdAt: now,
                photoPath: photoPath,
                species: plantHint?.commonName.nonEmpty,
                speciesLatin: plantHint?.latinName?.nonEmpty
            )
            try await persistence.saveCareItem(hid, item)
            return "Added \(name) to your plants 🌿"

        case .memory:
            let memId = UUID().uuidString
            var photoPaths: [String] = []
            if let jpeg, let path = try? await storage.uploadMemoryPhoto(hid, memId, 0, jpeg) {
                photoPaths.append(path)
            }
            let memory = Memory(
                id: memId,
                title: nil,
                richText: text,
                photoPaths: photoPaths,
                date: now,
                createdBy: uid,
                createdAt: now,
                updatedAt: now
            )
            try await persistence.saveMemory(hid, memory)
            return "Saved to your memories 📸"

        case .list:
            guard let list, !text.isEmpty else {
                throw CaptureError.noTarget
            }
            let item = ListItem(
                title: text,
                listID: list.id,
                sortOrder: Int(now.timeIntervalSince1970),
                groceryCategory: list.isGrocery ? GroceryItemDB.categorize(text) : nil
            )
            try await persistence.saveListItem(hid, item)
            return "Added to \(list.title) ✓"

        case .event:
            guard !text.isEmpty else { throw CaptureError.noTarget }
            let cal = Calendar.current
            // A sensible default: tomorrow at 9am (an all-day-ish reminder the user can reschedule).
            let base = cal.date(byAdding: .day, value: 1, to: now) ?? now
            let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: base) ?? base
            let event = FamilyEvent(
                title: text,
                startDate: start,
                endDate: start.addingTimeInterval(3600),
                notes: "From Smart Capture"
            )
            try await persistence.saveEvent(hid, event)
            return "Added to the calendar 🗓️ — tomorrow morning, tweak it anytime."
        }
    }

    enum CaptureError: Error, LocalizedError {
        case noTarget
        var errorDescription: String? { "there was nothing to file" }
    }

    static func defaultDocTitle(text: String, now: Date) -> String {
        if let t = text.nonEmpty { return t }
        let f = DateFormatter()
        f.dateFormat = "MMM d 'capture'"
        return f.string(from: now)
    }

    // MARK: - Vision (identifyPlant callable, used as the photo router's AI signal)

    /// Run the deployed `identifyPlant` Claude-vision callable and map it to a ``PlantHint``. Failure /
    /// non-plant returns nil — the router then defaults the photo to Brain. Same transport as
    /// `PlantsClient` (base64 JPEG + media type).
    static func identifyPlant(_ jpeg: Data) async -> PlantHint? {
        let base64 = jpeg.base64EncodedString()
        let callable = Functions.functions(region: "us-central1").httpsCallable("identifyPlant")
        guard let result = try? await callable.call(["imageBase64": base64, "mediaType": "image/jpeg"]),
              let dict = result.data as? [String: Any] else { return nil }
        let common = (dict["commonName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !common.isEmpty else { return nil }
        let latin = (dict["latinName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = (dict["confidence"] as? String) ?? "low"
        let interval: Int?
        if let i = dict["waterIntervalDays"] as? Int { interval = i }
        else if let n = dict["waterIntervalDays"] as? NSNumber { interval = n.intValue }
        else { interval = nil }
        return PlantHint(
            commonName: common,
            latinName: (latin?.isEmpty == false) ? latin : nil,
            waterIntervalDays: interval,
            confidence: confidence
        )
    }
}

private extension String {
    /// The trimmed string, or nil if it's empty/whitespace.
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
