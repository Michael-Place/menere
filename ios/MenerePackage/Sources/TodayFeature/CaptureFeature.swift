import AnalyticsClient
import ComposableArchitecture
import DocsFeature
import FamilyDomain
import FirebaseFunctions
import Foundation
import MenereUI
import PersistenceClient
import SharedCapture
import StorageClient
import SwiftUI
import UIKit
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
    case recipe       // a recipe → the family Kitchen (V5-URL, URL front door)
    case wishlist     // a product → the family wishlist (V5-URL, URL front door)

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .brain: "Family Brain"
        case .plant: "Add a plant"
        case .memory: "A memory"
        case .list: "A list"
        case .event: "A reminder"
        case .recipe: "Kitchen"
        case .wishlist: "Wishlist"
        }
    }

    var symbol: String {
        switch self {
        case .brain: "brain.head.profile"
        case .plant: "leaf.fill"
        case .memory: "camera.fill"
        case .list: "checklist"
        case .event: "calendar.badge.plus"
        case .recipe: "fork.knife"
        case .wishlist: "star.fill"
        }
    }

    var blurb: String {
        switch self {
        case .brain: "File it and let Bacán read the details"
        case .plant: "Start watering reminders for it"
        case .memory: "Save it to the family scrapbook"
        case .list: "Drop it on a shared list"
        case .event: "Put it on the family calendar"
        case .recipe: "Save the recipe to your Kitchen"
        case .wishlist: "Add it to the family wishlist"
        }
    }

    var tint: Color {
        switch self {
        case .brain: .sky
        case .plant: .bacanGreen
        case .memory: .terracotta
        case .list: .bacanGreen
        case .event: .marigold
        case .recipe: .marigold
        case .wishlist: .terracotta
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

    /// A routed URL import from the `extractURL` callable — the "paste a link" front door (V5-URL).
    /// Holds the classified destination plus the per-type payload the confirm/file path needs.
    public struct URLImport: Equatable, Sendable {
        var destination: CaptureDestination
        var title: String
        var url: String
        var summary: String?
        var imageURL: String?
        var extractedText: String?
        var recipe: Recipe?
        var productPrice: Double?
        var productStore: String?
        var eventStart: Date?
        var eventEnd: Date?
        var eventLocation: String?
        var eventIsAllDay: Bool = false
    }

    @ObservableState
    public struct State: Equatable {
        public enum Stage: Equatable { case compose, classifying, confirm, filing, done }
        var stage: Stage = .compose

        /// Set when the capture is a pasted/typed link routed through `extractURL`. Drives the URL
        /// confirm card + the URL filing path (distinct from the photo/text filing).
        var urlImport: URLImport?

        /// Typed OR voice-dictated note (the keyboard mic dictates straight into the field — no extra
        /// speech plumbing needed).
        var text: String = ""
        /// The processed (downscaled JPEG) photo to classify + upload, and a small preview thumbnail.
        var imageJPEG: Data?
        var thumbnail: Data?
        /// A shared PDF's raw bytes (no downscale) + its filename, carried straight from the Share
        /// Extension. A PDF is a document → it routes to the Family Brain and uploads via
        /// `storage.uploadDocumentPDF` (the same path the doc scanner uses), never the photo-page path.
        var pdfData: Data?
        var pdfFilename: String?

        /// The ranked destinations for the current input; `suggestions.first` is the AI/heuristic's
        /// pick and is pre-selected. The user confirms it or taps another (one-tap override).
        var suggestions: [CaptureDestination] = []
        var selected: CaptureDestination?
        var plantHint: PlantHint?

        // Loaded context so filing can target the right list + tag groceries.
        var lists: [FamilyList] = []
        var members: [HouseholdMember] = []
        /// Active family projects (PR2) — offered as an optional "Add to a project" chip on the confirm
        /// step when a capture is headed to the Family Brain. Empty when there are no projects yet, in
        /// which case the chip row simply doesn't render.
        var projects: [Project] = []
        /// The project the user tags this capture onto (PR2). Applied to the created document's
        /// `projectIds` when filing to the Brain. Pre-selected from ``suggestedProjectId`` if the AI
        /// guessed one (rare at capture, but possible via a routed import).
        var selectedProjectId: String?
        /// An AI-guessed project id carried into capture (e.g. from a routed import). Pre-selects the
        /// chip so the family confirms rather than hunts.
        var suggestedProjectId: String?

        /// The active (not-done) projects, newest first — the set the "Add to a project" chip offers.
        var activeProjects: [Project] {
            projects.filter { $0.status != .done }
                .sorted { $0.createdAt > $1.createdAt }
        }

        // Result surface.
        var receipt: String?
        var routedTo: CaptureDestination?
        var confettiTrigger = 0
        var errorMessage: String?

        var hasInput: Bool {
            imageJPEG != nil || pdfData != nil
                || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var hasPhoto: Bool { imageJPEG != nil }
        var hasPDF: Bool { pdfData != nil }
        var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case task
        /// V5 Share Extension last-mile: read-and-clear the parked share (`CaptureHandoffStore.take()`)
        /// off the reducer, loading + downscaling any shared image bytes from the app-group container.
        case consumeHandoff
        /// The parked share (if any) + its processed image and/or raw PDF bytes, ready to prefill the
        /// compose surface.
        case handoffLoaded(PendingShare, jpeg: Data?, thumbnail: Data?, pdf: Data?)
        case contextLoaded(lists: [FamilyList], members: [HouseholdMember])
        case projectsLoaded([Project])
        /// Tag / untag the capture onto a project (PR2) — a toggle: tapping the selected chip clears it.
        case selectProject(String?)
        /// A photo finished processing in the view (downscaled JPEG + preview thumbnail).
        case photoProcessed(jpeg: Data, thumbnail: Data)
        case clearPhoto
        /// "Route it" — run the classifier (a vision call for photos, heuristics for text).
        case classifyTapped
        case plantHinted(PlantHint?)
        /// A pasted/typed link finished routing through `extractURL`.
        case urlImported(URLImport)
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
                // Prefill from a shared item regardless of household — the compose surface still shows
                // the link/text/image even before context loads.
                guard let (hid, _) = ctx() else { return .send(.consumeHandoff) }
                return .merge(
                    .send(.consumeHandoff),
                    .run { send in
                        async let lists = persistence.lists(hid)
                        async let members = persistence.members(hid)
                        async let projects = persistence.projects(hid)
                        await send(.contextLoaded(
                            lists: (try? await lists) ?? [],
                            members: (try? await members) ?? []
                        ))
                        await send(.projectsLoaded((try? await projects) ?? []))
                    }
                )

            case .consumeHandoff:
                // Read-and-clear the parked share off the main actor; load + downscale any image bytes
                // (they live as a file in the app-group container) before handing back for prefill.
                return .run { send in
                    guard let share = CaptureHandoffStore.take() else { return }
                    var jpeg: Data?
                    var thumbnail: Data?
                    var pdf: Data?
                    if let name = share.attachmentFilename,
                       let url = PendingShareStore.attachmentURL(for: name),
                       let data = try? Data(contentsOf: url) {
                        switch share.kind {
                        case .image:
                            if let ui = UIImage(data: data) {
                                jpeg = CaptureImageProcessing.downscaledJPEG(from: ui, maxEdge: 2000, quality: 0.75)
                                thumbnail = CaptureImageProcessing.thumbnailJPEG(from: ui)
                            }
                        case .pdf:
                            // A PDF's bytes go up untouched (no downscale) — the Brain reads the file.
                            pdf = data
                        case .text, .url:
                            break
                        }
                    }
                    await send(.handoffLoaded(share, jpeg: jpeg, thumbnail: thumbnail, pdf: pdf))
                }

            case let .handoffLoaded(share, jpeg, thumbnail, pdf):
                analytics.log("share_prefill", [
                    "kind": share.kind.rawValue,
                    "has_pdf": (pdf != nil) ? "1" : "0",
                ])
                switch share.kind {
                case .image:
                    // Prefill the photo slot; any note that rode along goes into the field too.
                    if let jpeg, let thumbnail {
                        state.imageJPEG = jpeg
                        state.thumbnail = thumbnail
                    }
                    let note = share.composeText
                    if !note.isEmpty { state.text = note }
                    return .none
                case .url:
                    // Prefill the field with the link, then route it straight through the URL front door
                    // (V5-URL) so the sheet opens already carrying a proposed destination.
                    state.text = share.composeText
                    return .send(.classifyTapped)
                case .pdf:
                    // A PDF is a document → it belongs in the Family Brain. Carry the raw bytes + the
                    // typed description (as the title/note), pre-select Brain, and jump straight to the
                    // confirm card so the user files it in one tap. If the bytes somehow didn't load,
                    // fall back to the plain note field so nothing is silently dropped.
                    let note = share.composeText
                    if !note.isEmpty { state.text = note }
                    if let pdf {
                        state.pdfData = pdf
                        state.pdfFilename = share.attachmentFilename
                        state.suggestions = [.brain]
                        state.selected = .brain
                        state.stage = .confirm
                    }
                    return .none
                case .text:
                    // Text lands in the note field for the user to route.
                    state.text = share.composeText
                    return .none
                }

            case let .contextLoaded(lists, members):
                state.lists = lists
                state.members = members
                return .none

            case let .projectsLoaded(projects):
                state.projects = projects
                // Pre-select an AI-guessed project (if any) so the family confirms with one tap.
                if state.selectedProjectId == nil,
                   let guess = state.suggestedProjectId,
                   projects.contains(where: { $0.id == guess }) {
                    state.selectedProjectId = guess
                }
                return .none

            case let .selectProject(id):
                // Toggle: tapping the already-selected chip clears the tag.
                state.selectedProjectId = (state.selectedProjectId == id) ? nil : id
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
                // A pasted/typed LINK → the `extractURL` front door (recipe/product/event/Brain).
                // Plain text → pure heuristics, so it's instant (no spinner needed).
                if let jpeg = state.imageJPEG {
                    state.stage = .classifying
                    return .run { send in
                        let hint = await Self.identifyPlant(jpeg)
                        await send(.plantHinted(hint))
                    }
                } else if let url = Self.detectURL(state.trimmedText) {
                    state.stage = .classifying
                    return .run { send in
                        let imported = await Self.importURL(url)
                        await send(.urlImported(imported))
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

            case let .urlImported(imported):
                state.urlImport = imported
                // The AI's routed home first; Family Brain is always offered as the safe override so a
                // link is never stranded.
                state.suggestions = imported.destination == .brain
                    ? [.brain]
                    : [imported.destination, .brain]
                state.selected = imported.destination
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
                // URL front door (V5-URL): file straight from the routed import payload.
                if let imported = state.urlImport {
                    analytics.log("smart_capture_routed", ["destination": dest.rawValue, "input": "url"])
                    analytics.log("url_imported", ["destination": dest.rawValue])
                    return .run { send in
                        do {
                            let receipt = try await Self.fileURL(
                                imported: imported, dest: dest, hid: hid, uid: uid, persistence: persistence
                            )
                            await send(.filed(receipt: receipt, destination: dest))
                        } catch {
                            await send(.fileFailed(error.localizedDescription))
                        }
                    }
                }
                let text = state.trimmedText
                let jpeg = state.imageJPEG
                let pdfData = state.pdfData
                let plantHint = state.plantHint
                let list = Self.targetList(state.lists)
                let input = pdfData != nil ? "pdf" : (jpeg != nil ? "photo" : "text")
                // A project tag only rides along when the capture is headed to the Brain (PR2).
                let projectIds: [String]? = (dest == .brain)
                    ? state.selectedProjectId.map { [$0] }
                    : nil
                analytics.log("smart_capture_routed", [
                    "destination": dest.rawValue,
                    "input": input,
                ])
                if projectIds != nil {
                    analytics.log("doc_project_tagged", ["source": "capture"])
                }
                return .run { send in
                    do {
                        let receipt = try await Self.file(
                            dest: dest, hid: hid, uid: uid, text: text, jpeg: jpeg, pdfData: pdfData,
                            plantHint: plantHint, list: list, projectIds: projectIds,
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
        pdfData: Data? = nil,
        plantHint: PlantHint?,
        list: FamilyList?,
        projectIds: [String]? = nil,
        persistence: PersistenceClient,
        storage: StorageClient,
        docs: DocsClient
    ) async throws -> String {
        let now = Date()
        switch dest {
        case .brain:
            let docId = UUID().uuidString
            var pagePaths: [String] = []
            if let pdfData {
                // A shared PDF uploads as-is via the doc-scanner's PDF path (NOT the photo-page path)
                // so `processDocument` reads the real file. `document.pdf` is the only "page".
                let path = try await storage.uploadDocumentPDF(hid, docId, pdfData)
                pagePaths.append(path)
            } else if let jpeg {
                let compressed = DocumentImageProcessing.compressedJPEG(from: jpeg) ?? jpeg
                let path = try await storage.uploadDocumentPage(hid, docId, 0, compressed)
                pagePaths.append(path)
            }
            let title = text.nonEmpty ?? (pdfData != nil ? "Shared PDF" : defaultDocTitle(text: text, now: now))
            let doc = FamilyDomain.Document(
                id: docId,
                title: title,
                type: .other,
                projectIds: projectIds,
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

        case .recipe, .wishlist:
            // Kitchen/Wishlist are URL-only destinations — they file via `fileURL`, never this
            // photo/text path.
            throw CaptureError.noTarget
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

    // MARK: - URL front door (V5-URL)

    /// The first http(s) link inside a captured note, or nil. This is the trigger that routes a
    /// paste/typed link through `extractURL` instead of the plain-text heuristics.
    static func detectURL(_ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "https?://[^\\s]+", options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range, in: text) else { return nil }
        // Trim trailing punctuation a user might type after a pasted link.
        let trailing = CharacterSet(charactersIn: ".,);]}\"'>")
        var url = String(text[r])
        while let last = url.unicodeScalars.last, trailing.contains(last) { url.removeLast() }
        return url.isEmpty ? nil : url
    }

    /// Call the deployed `extractURL` callable and map its routed result to a ``URLImport``. Never
    /// throws — a failed call degrades to a Family Brain import of the bare link so nothing is lost.
    static func importURL(_ url: String) async -> URLImport {
        let callable = Functions.functions(region: "us-central1").httpsCallable("extractURL")
        guard let result = try? await callable.call(["url": url]),
              let data = result.data as? [String: Any] else {
            return URLImport(destination: .brain, title: url, url: url)
        }
        let dest = mapDestination(data["destination"] as? String)
        let title = (data["title"] as? String)?.nonEmpty ?? url
        let summary = (data["summary"] as? String)?.nonEmpty
        let imageURL = (data["imageURL"] as? String)?.nonEmpty
        let extractedText = (data["extractedText"] as? String)?.nonEmpty

        var recipe: Recipe?
        if dest == .recipe, let r = data["recipe"] as? [String: Any] {
            recipe = parseRecipe(r, url: url, fallbackTitle: title, imageURL: imageURL)
        }
        var price: Double?
        var store: String?
        if dest == .wishlist, let p = data["product"] as? [String: Any] {
            price = (p["price"] as? Double) ?? (p["price"] as? Int).map(Double.init)
            store = (p["store"] as? String)?.nonEmpty
        }
        var start: Date?
        var end: Date?
        var location: String?
        var allDay = false
        if dest == .event, let e = data["event"] as? [String: Any] {
            start = (e["startDate"] as? String).flatMap(parseISODate)
            end = (e["endDate"] as? String).flatMap(parseISODate)
            location = (e["location"] as? String)?.nonEmpty
            allDay = (e["isAllDay"] as? Bool) ?? false
        }
        // An "event" with no parseable date isn't schedulable — keep the link in the Brain instead.
        let finalDest: CaptureDestination = (dest == .event && start == nil) ? .brain : dest
        return URLImport(
            destination: finalDest, title: title, url: url, summary: summary, imageURL: imageURL,
            extractedText: extractedText, recipe: recipe, productPrice: price, productStore: store,
            eventStart: start, eventEnd: end, eventLocation: location, eventIsAllDay: allDay
        )
    }

    static func mapDestination(_ raw: String?) -> CaptureDestination {
        switch raw {
        case "recipe": return .recipe
        case "product": return .wishlist
        case "event": return .event
        default: return .brain
        }
    }

    /// Map the server's Menere-shaped recipe dict → a `Recipe` (mirrors `RecipeImportClient`).
    static func parseRecipe(_ r: [String: Any], url: String, fallbackTitle: String, imageURL: String?) -> Recipe {
        let title = (r["title"] as? String)?.nonEmpty ?? fallbackTitle
        let servings = (r["servings"] as? Int) ?? Int((r["servings"] as? Double) ?? 4)
        let ingredients: [Ingredient] = (r["ingredients"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let name = (dict["name"] as? String)?.nonEmpty else { return nil }
            let quantity = (dict["quantity"] as? Double) ?? (dict["quantity"] as? Int).map(Double.init)
            let unit = (dict["unit"] as? String)?.nonEmpty
            return Ingredient(name: name, quantity: quantity, unit: unit)
        }
        let instructions = (r["instructions"] as? [String] ?? []).filter { !$0.isEmpty }
        return Recipe(
            title: title,
            servings: max(1, servings),
            sourceURL: (r["sourceURL"] as? String)?.nonEmpty ?? url,
            imageURL: (r["imageURL"] as? String)?.nonEmpty ?? imageURL,
            ingredients: ingredients,
            instructions: instructions
        )
    }

    static func parseISODate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// File a routed URL import through the SAME persistence the owning features use. Returns the warm
    /// success receipt. `dest` is the confirmed destination (which may be a Brain override).
    static func fileURL(
        imported: URLImport,
        dest: CaptureDestination,
        hid: String,
        uid: String,
        persistence: PersistenceClient
    ) async throws -> String {
        let now = Date()
        switch dest {
        case .recipe:
            let recipe = imported.recipe ?? Recipe(title: imported.title, sourceURL: imported.url, imageURL: imported.imageURL)
            try await persistence.saveRecipe(hid, recipe)
            return "Saved to Kitchen ✓ — “\(recipe.title)” is in your recipes."

        case .wishlist:
            let lists = try await persistence.lists(hid)
            let listID: String
            if let existing = lists.first(where: { $0.isWishlist }) {
                listID = existing.id
            } else {
                let newList = FamilyList(title: "Wishlist", icon: "star.fill", listType: .wishlist)
                try await persistence.saveList(hid, newList)
                listID = newList.id
            }
            let item = ListItem(
                title: imported.title,
                listID: listID,
                sortOrder: Int(now.timeIntervalSince1970),
                note: imported.summary,
                price: imported.productPrice,
                link: imported.url,
                store: imported.productStore,
                priority: .medium
            )
            try await persistence.saveListItem(hid, item)
            return "Added to Wishlist ✓ — “\(imported.title)”."

        case .event:
            guard let start = imported.eventStart else { throw CaptureError.noTarget }
            let end = imported.eventEnd ?? start.addingTimeInterval(3600)
            let event = FamilyEvent(
                title: imported.title,
                startDate: start,
                endDate: end,
                isAllDay: imported.eventIsAllDay,
                location: imported.eventLocation,
                notes: urlNote(summary: imported.summary, url: imported.url)
            )
            try await persistence.saveEvent(hid, event)
            return "Added to the calendar 🗓️ — “\(imported.title)”."

        default: // .brain (and the safe fallback for anything else)
            let doc = Document(
                id: UUID().uuidString,
                title: imported.title,
                type: .other,
                summary: imported.summary,
                extractedText: imported.extractedText,
                notes: urlNote(summary: imported.summary, url: imported.url),
                uploadedBy: uid,
                createdAt: now,
                processingState: .processed
            )
            try await persistence.saveDocument(hid, doc)
            return "Filed to the Family Brain ✓ — “\(imported.title)”."
        }
    }

    /// The note body for a URL-sourced event/doc: the summary (if any) above the source link.
    static func urlNote(summary: String?, url: String) -> String {
        if let summary, !summary.isEmpty { return "\(summary)\n\n\(url)" }
        return url
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
