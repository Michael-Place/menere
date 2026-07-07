import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import PhotoLibraryClient
import StorageClient
import SwiftUI
import UserDomain

// NOTE: `Document` is fully qualified as `FamilyDomain.Document` throughout — another imported module
// (transitively) also exports a `Document`, so the bare name is ambiguous here.

/// The **project workspace** (Projects PR1) — the rich gathering-place for one initiative. A cover
/// hero + editable phase/target header, then sections: an **inspiration board** (photo grid), linked
/// **Family-Brain documents** (via `Document.projectIds`), **links**, a **task** checklist, and
/// free-form **notes** (Markdown via ``RichNoteEditor``). Every mutation persists the project (or the
/// linked doc) and echoes the change up to the Projects list via `.delegate(.didChange)`.
@Reducer
public struct ProjectWorkspaceReducer {
    @ObservableState
    public struct State: Equatable {
        public var project: Project
        /// All household documents (for the linked-docs section + the "add existing" picker).
        var documents: [FamilyDomain.Document] = []
        var isLoadingDocs = false

        // Inspiration board.
        var showLibraryBrowser = false
        var showCamera = false
        var boardLoadingCount = 0
        var viewingPhotoPath: String?

        // Links.
        var showAddLink = false
        var linkURL = ""
        var linkTitle = ""

        // Tasks.
        var newTaskTitle = ""

        // Documents picker.
        var showDocPicker = false

        // Contacts.
        var showContactEditor = false
        /// The working copy the editor binds to; `editingContactId == nil` means we're adding a new one.
        var contactDraft = ProjectContact(name: "")
        var editingContactId: String?

        // Budget.
        var showBudgetEditor = false
        /// The text the budget field binds to (dollars, no cents) while editing.
        var budgetDraft = ""

        public init(project: Project) {
            self.project = project
        }

        /// Documents already tagged onto this project.
        var linkedDocuments: [FamilyDomain.Document] {
            documents
                .filter { ($0.projectIds ?? []).contains(project.id) }
                .sorted { $0.createdAt > $1.createdAt }
        }

        /// Documents NOT yet on this project (the "add existing" candidates), newest first.
        var unlinkedDocuments: [FamilyDomain.Document] {
            documents
                .filter { !($0.projectIds ?? []).contains(project.id) }
                .sorted { $0.createdAt > $1.createdAt }
        }

        /// Documents the AI (or capture) *guessed* belong to this project but that no one has
        /// confirmed yet — the "suggested items" inbox. Excludes anything already linked.
        var suggestedDocuments: [FamilyDomain.Document] {
            documents
                .filter { $0.suggestedProjectId == project.id && !($0.projectIds ?? []).contains(project.id) }
                .sorted { $0.createdAt > $1.createdAt }
        }

        /// The linked docs that carry a real dollar `amount` — the raw material for the quote
        /// comparison. Sorted cheapest → priciest so the first is the low bid.
        var quoteDocuments: [FamilyDomain.Document] {
            linkedDocuments
                .filter { ($0.amount ?? 0) > 0 }
                .sorted { ($0.amount ?? 0) < ($1.amount ?? 0) }
        }

        /// A tiny, decode-free rollup of the gathered quotes (count + range + cheapest id) — nil when
        /// no linked doc has an amount. All the money math the Budget section needs.
        var quoteStats: QuoteStats? {
            let quotes = quoteDocuments
            guard let low = quotes.first?.amount, let high = quotes.last?.amount else { return nil }
            return QuoteStats(count: quotes.count, low: low, high: high, cheapestDocId: quotes.first?.id)
        }
    }

    /// A pure summary of a project's gathered quotes — the Budget section's model. Kept in the feature
    /// (not `FamilyDomain`) so the money math stays local to the workspace, per PR3's "keep it light".
    public struct QuoteStats: Equatable, Sendable {
        public var count: Int
        public var low: Double
        public var high: Double
        public var cheapestDocId: String?

        /// "3 quotes · $48k–$71k" (single quote → just the one price). Compact k-formatting.
        public var headline: String {
            let noun = count == 1 ? "quote" : "quotes"
            if count == 1 || low == high {
                return "\(count) \(noun) · \(Self.compact(low))"
            }
            return "\(count) \(noun) · \(Self.compact(low))–\(Self.compact(high))"
        }

        /// $48,000 → "$48k"; $1,250 → "$1,250"; keeps it glanceable on a card.
        static func compact(_ value: Double) -> String {
            if value >= 1_000 {
                let k = value / 1_000
                let rounded = (k * 10).rounded() / 10
                let stem = rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
                return "$\(stem)k"
            }
            return value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        }
    }

    public enum Action: BindableAction, Equatable {
        case task
        case documentsLoaded([FamilyDomain.Document])

        // Header
        case phaseSelected(ProjectPhase)
        case targetToggled(Bool)
        case targetChanged(Date)
        case headerCommitted
        case notesChanged(String)
        case persistDebounced

        // Board
        case addPhotoTapped
        case cameraTapped
        case libraryAssetsPicked([String])
        case cameraCaptured(Data)
        case boardPhotoReady(Data)
        case boardPhotoUploaded(String?)
        case removePhoto(String)
        case setCoverFromBoard(String)
        case photoTapped(String)
        case dismissViewer

        // Links
        case addLinkTapped
        case saveLink
        case deleteLink(String)

        // Tasks
        case addTaskSubmitted
        case toggleTask(String)
        case deleteTask(String)

        // Documents
        case addDocumentTapped
        case linkDocument(FamilyDomain.Document)
        case unlinkDocument(FamilyDomain.Document)

        // Suggested-items inbox (AI/capture guessed this doc belongs here)
        case acceptSuggestion(FamilyDomain.Document)
        case dismissSuggestion(FamilyDomain.Document)

        // Contacts
        case addContactTapped
        case editContactTapped(ProjectContact)
        case saveContact
        case deleteContact(String)
        case dismissContactEditor

        // Budget
        case setBudgetTapped
        case saveBudget
        case clearBudget
        case dismissBudgetEditor

        // Whole-project lifecycle
        case deleteProjectTapped

        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum Delegate: Equatable {
            case didChange(Project)
            case didDelete(String)
        }
    }

    public init() {}

    private enum CancelID { case notesDebounce }

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    /// Forgiving budget parse: "$48,000" / "48000" / "48k" / "48.5k" → a Double, else nil (blank clears).
    static func parseBudget(_ raw: String) -> Double? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var multiplier = 1.0
        if s.hasSuffix("k") { multiplier = 1_000; s.removeLast() }
        let filtered = s.filter { $0.isNumber || $0 == "." }
        guard let value = Double(filtered), value > 0 else { return nil }
        return value * multiplier
    }

    /// Persist the current project and echo it up to the list. The single write path for every edit.
    private func persist(_ project: Project) -> Effect<Action> {
        guard let hid = hid() else { return .send(.delegate(.didChange(project))) }
        return .merge(
            .send(.delegate(.didChange(project))),
            .run { _ in
                @Dependency(\.persistence) var persistence
                try await persistence.saveProject(hid, project)
            }
        )
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                guard let hid = hid() else { return .none }
                state.isLoadingDocs = true
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let docs = (try? await persistence.documents(hid)) ?? []
                    await send(.documentsLoaded(docs))
                }

            case let .documentsLoaded(docs):
                state.isLoadingDocs = false
                state.documents = docs
                return .none

            // MARK: Header
            case let .phaseSelected(phase):
                state.project.status = phase
                return persist(state.project)

            case let .targetToggled(on):
                state.project.targetDate = on ? Date() : nil
                return persist(state.project)

            case let .targetChanged(date):
                state.project.targetDate = date
                return persist(state.project)

            case .headerCommitted:
                state.project.name = state.project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let s = state.project.summary?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    state.project.summary = s.isEmpty ? nil : s
                }
                return persist(state.project)

            case let .notesChanged(markdown):
                state.project.notes = markdown.isEmpty ? nil : markdown
                // Debounce persistence so we don't write on every keystroke.
                let project = state.project
                let householdId = hid()
                return .run { send in
                    @Dependency(\.continuousClock) var clock
                    try await clock.sleep(for: .seconds(0.6))
                    await send(.delegate(.didChange(project)))
                    if let householdId {
                        @Dependency(\.persistence) var persistence
                        try await persistence.saveProject(householdId, project)
                    }
                }
                .cancellable(id: CancelID.notesDebounce, cancelInFlight: true)

            case .persistDebounced:
                return .none

            // MARK: Board
            case .addPhotoTapped:
                state.showLibraryBrowser = true
                return .none

            case .cameraTapped:
                state.showCamera = true
                return .none

            case let .libraryAssetsPicked(ids):
                state.showLibraryBrowser = false
                guard !ids.isEmpty else { return .none }
                return .run { send in
                    @Dependency(\.photoLibrary) var photoLibrary
                    for id in ids {
                        if let data = await photoLibrary.loadFullImage(id),
                           let ui = UIImage(data: data) {
                            let jpeg = CaptureImageProcessing.downscaledJPEG(from: ui) ?? data
                            await send(.boardPhotoReady(jpeg))
                        }
                    }
                }

            case let .cameraCaptured(data):
                state.showCamera = false
                return .send(.boardPhotoReady(data))

            case let .boardPhotoReady(data):
                guard let hid = hid() else { return .none }
                state.boardLoadingCount += 1
                let projectID = state.project.id
                return .run { send in
                    @Dependency(\.storage) var storage
                    let path = try? await storage.uploadProjectPhoto(hid, projectID, UUID().uuidString, data)
                    await send(.boardPhotoUploaded(path))
                }

            case let .boardPhotoUploaded(path):
                state.boardLoadingCount = max(0, state.boardLoadingCount - 1)
                guard let path else { return .none }
                var paths = state.project.photoPaths ?? []
                paths.append(path)
                state.project.photoPaths = paths
                @Dependency(\.analytics) var analytics
                analytics.log("project_photo_added")
                return persist(state.project)

            case let .removePhoto(path):
                state.project.photoPaths?.removeAll { $0 == path }
                if state.project.photoPaths?.isEmpty == true { state.project.photoPaths = nil }
                return .merge(
                    persist(state.project),
                    .run { _ in
                        @Dependency(\.storage) var storage
                        try? await storage.deletePaths([path])
                    }
                )

            case let .setCoverFromBoard(path):
                state.project.coverImagePath = path
                return persist(state.project)

            case let .photoTapped(path):
                state.viewingPhotoPath = path
                return .none

            case .dismissViewer:
                state.viewingPhotoPath = nil
                return .none

            // MARK: Links
            case .addLinkTapped:
                state.linkURL = ""
                state.linkTitle = ""
                state.showAddLink = true
                return .none

            case .saveLink:
                let url = state.linkURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return .none }
                let link = ProjectLink(url: url, title: state.linkTitle.trimmingCharacters(in: .whitespacesAndNewlines))
                var links = state.project.links ?? []
                links.append(link)
                state.project.links = links
                state.showAddLink = false
                @Dependency(\.analytics) var analytics
                analytics.log("project_link_added")
                return persist(state.project)

            case let .deleteLink(id):
                state.project.links?.removeAll { $0.id == id }
                if state.project.links?.isEmpty == true { state.project.links = nil }
                return persist(state.project)

            // MARK: Tasks
            case .addTaskSubmitted:
                let title = state.newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return .none }
                var tasks = state.project.tasks ?? []
                tasks.append(ProjectTask(title: title))
                state.project.tasks = tasks
                state.newTaskTitle = ""
                return persist(state.project)

            case let .toggleTask(id):
                guard let idx = state.project.tasks?.firstIndex(where: { $0.id == id }) else { return .none }
                state.project.tasks?[idx].isDone.toggle()
                return persist(state.project)

            case let .deleteTask(id):
                state.project.tasks?.removeAll { $0.id == id }
                if state.project.tasks?.isEmpty == true { state.project.tasks = nil }
                return persist(state.project)

            // MARK: Documents
            case .addDocumentTapped:
                state.showDocPicker = true
                return .none

            case let .linkDocument(doc):
                guard let hid = hid() else { return .none }
                var updated = doc
                var ids = updated.projectIds ?? []
                if !ids.contains(state.project.id) { ids.append(state.project.id) }
                updated.projectIds = ids
                if let idx = state.documents.firstIndex(where: { $0.id == doc.id }) {
                    state.documents[idx] = updated
                }
                state.showDocPicker = false
                // Immutable snapshot so the concurrently-executing `.run` closure doesn't capture a `var`.
                let linked = updated
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    @Dependency(\.analytics) var analytics
                    try await persistence.saveDocument(hid, linked)
                    analytics.log("project_document_linked")
                }

            case let .unlinkDocument(doc):
                guard let hid = hid() else { return .none }
                var updated = doc
                updated.projectIds = (updated.projectIds ?? []).filter { $0 != state.project.id }
                if updated.projectIds?.isEmpty == true { updated.projectIds = nil }
                if let idx = state.documents.firstIndex(where: { $0.id == doc.id }) {
                    state.documents[idx] = updated
                }
                // Immutable snapshot so the concurrently-executing `.run` closure doesn't capture a `var`.
                let unlinked = updated
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveDocument(hid, unlinked)
                }

            // MARK: Suggested-items inbox
            // The AI (or capture) tagged `suggestedProjectId` on a loose doc — surface it here so the
            // family can keep it (→ real `projectIds` link) or gently wave it off.
            case let .acceptSuggestion(doc):
                guard let hid = hid() else { return .none }
                var updated = doc
                var ids = updated.projectIds ?? []
                if !ids.contains(state.project.id) { ids.append(state.project.id) }
                updated.projectIds = ids
                updated.suggestedProjectId = nil
                if let idx = state.documents.firstIndex(where: { $0.id == doc.id }) {
                    state.documents[idx] = updated
                }
                let accepted = updated
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    @Dependency(\.analytics) var analytics
                    try await persistence.saveDocument(hid, accepted)
                    analytics.log("project_suggestion_added")
                }

            case let .dismissSuggestion(doc):
                guard let hid = hid() else { return .none }
                var updated = doc
                updated.suggestedProjectId = nil
                if let idx = state.documents.firstIndex(where: { $0.id == doc.id }) {
                    state.documents[idx] = updated
                }
                let dismissed = updated
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    @Dependency(\.analytics) var analytics
                    try await persistence.saveDocument(hid, dismissed)
                    analytics.log("project_suggestion_dismissed")
                }

            // MARK: Contacts
            case .addContactTapped:
                state.editingContactId = nil
                state.contactDraft = ProjectContact(name: "")
                state.showContactEditor = true
                return .none

            case let .editContactTapped(contact):
                state.editingContactId = contact.id
                state.contactDraft = contact
                state.showContactEditor = true
                return .none

            case .saveContact:
                var draft = state.contactDraft
                draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !draft.name.isEmpty else { return .none }
                // Normalise blank optionals back to nil so rows/links don't render empty fields.
                func clean(_ s: String?) -> String? {
                    let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (t?.isEmpty == false) ? t : nil
                }
                draft.role = clean(draft.role)
                draft.company = clean(draft.company)
                draft.phone = clean(draft.phone)
                draft.email = clean(draft.email)
                draft.notes = clean(draft.notes)

                var contacts = state.project.contacts ?? []
                let isNew: Bool
                if let id = state.editingContactId, let idx = contacts.firstIndex(where: { $0.id == id }) {
                    contacts[idx] = draft
                    isNew = false
                } else {
                    contacts.append(draft)
                    isNew = true
                }
                state.project.contacts = contacts
                state.showContactEditor = false
                state.editingContactId = nil
                if isNew {
                    @Dependency(\.analytics) var analytics
                    analytics.log("project_contact_added")
                }
                return persist(state.project)

            case let .deleteContact(id):
                state.project.contacts?.removeAll { $0.id == id }
                if state.project.contacts?.isEmpty == true { state.project.contacts = nil }
                return persist(state.project)

            case .dismissContactEditor:
                state.showContactEditor = false
                state.editingContactId = nil
                return .none

            // MARK: Budget
            case .setBudgetTapped:
                // Prefill with the current target (dollars, no cents) if one is set.
                if let target = state.project.budgetTarget {
                    state.budgetDraft = String(Int(target.rounded()))
                } else {
                    state.budgetDraft = ""
                }
                state.showBudgetEditor = true
                return .none

            case .saveBudget:
                // Parse a forgiving "$48,000" / "48000" / "48k" into a Double.
                let value = Self.parseBudget(state.budgetDraft)
                state.project.budgetTarget = value
                state.showBudgetEditor = false
                if value != nil {
                    @Dependency(\.analytics) var analytics
                    analytics.log("project_budget_set")
                }
                return persist(state.project)

            case .clearBudget:
                state.project.budgetTarget = nil
                state.showBudgetEditor = false
                return persist(state.project)

            case .dismissBudgetEditor:
                state.showBudgetEditor = false
                return .none

            // MARK: Lifecycle
            case .deleteProjectTapped:
                let id = state.project.id
                var paths = state.project.photoPaths ?? []
                if let cover = state.project.coverImagePath { paths.append(cover) }
                let householdId = hid()
                return .merge(
                    .run { [paths] _ in
                        @Dependency(\.storage) var storage
                        if let householdId {
                            @Dependency(\.persistence) var persistence
                            try? await persistence.deleteProject(householdId, id)
                        }
                        try? await storage.deletePaths(paths)
                    },
                    .send(.delegate(.didDelete(id)))
                )

            case .delegate:
                return .none

            case .binding:
                return .none
            }
        }
    }
}
