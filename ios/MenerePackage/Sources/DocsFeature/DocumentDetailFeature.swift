import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import Foundation
import MenereUI
import PersistenceClient
import StorageClient
import SwiftUI
import UserDomain

/// The full document detail screen — pushed from the library and from search results. Renders the
/// scanned page images (async, member-gated Storage bytes), the full extracted field set, and the
/// document-driven date actions (`dueDate` → add-to-calendar; `expiryDate` → countdown chip).
///
/// Light edit affordances this phase: title (inline) + type (menu), persisted via `saveDocument`.
/// Delete removes the Firestore doc and its Storage pages. All mutations bubble up to the parent
/// (library / search) through `delegate` so the list stays in sync.
/// A `.project`-list item tagged with the title of the list it belongs to — the unit the
/// "Link to…" flow offers and the Related section renders (Act V V1-A). Deck-project papers live as
/// items inside a `.project` FamilyList; a document links to the item id.
public struct LinkableProjectItem: Equatable, Identifiable, Sendable {
    public var item: ListItem
    public var listTitle: String
    public var id: String { item.id }

    public init(item: ListItem, listTitle: String) {
        self.item = item
        self.listTitle = listTitle
    }
}

@Reducer
public struct DocumentDetailReducer {
    @ObservableState
    public struct State: Equatable {
        var doc: FamilyDomain.Document
        /// Rendered page bytes, keyed by Storage path (light in-memory cache).
        var pageData: [String: Data] = [:]
        var pagesLoading = false
        /// Loaded to (a) show the calendar action's idempotent done-state and (b) avoid duplicates.
        var events: [FamilyEvent] = []
        var members: [HouseholdMember] = []
        /// The household's pets (CareItems with kind == .pet), for the Pets field row + link menu (P10).
        var pets: [CareItem] = []
        /// The household's plants (CareItems with kind == .plant), for the "Link to…" flow (Act V V1-A).
        var plants: [CareItem] = []
        /// Project-list items (items inside `.project` FamilyLists), each tagged with its list title,
        /// for the "Link to…" flow's project picker + the Related display (Act V V1-A).
        var projectItems: [LinkableProjectItem] = []
        /// Drives the "Link to…" sheet (Act V V1-A).
        var showLinkSheet = false
        /// The full document set + expenses, loaded so the "Related" card can compute cross-links (P24).
        var allDocuments: [FamilyDomain.Document] = []
        var expenses: [Expense] = []
        /// A related document pushed from the "Related" card (recursive navigation, P24).
        @Presents var relatedDoc: DocumentDetailReducer.State?
        var showFullText = false
        var isEditingTitle = false
        var titleDraft = ""
        var showDeleteConfirm = false

        public init(doc: FamilyDomain.Document) {
            self.doc = doc
            self.titleDraft = doc.title
        }

        /// Merge a fresh copy delivered by the parent's live documents listener (pending→processed
        /// fills the fields in place). Edit-stomp guard: while the rename alert is open we keep the
        /// local title and let only the other fields update, so a mid-edit snapshot can't clobber
        /// the in-flight rename.
        mutating func applyUpdate(_ fresh: FamilyDomain.Document) {
            if isEditingTitle {
                var merged = fresh
                merged.title = doc.title
                doc = merged
            } else {
                doc = fresh
            }
        }

        /// The cross-entity graph for this document (same-vendor + shared-tag projects + linked
        /// expense + linked pets/members), computed against the family's full doc / expense sets (P24).
        var related: EntityGraph.RelatedItems {
            EntityGraph.related(for: doc, documents: allDocuments, expenses: expenses)
        }

        /// The entity categories this doc's vendor suggests linking to (Act V V1-A). Green Thumb →
        /// plants, a vet → pets, Deck Daddy's → project.
        var suggestedTargets: [EntityGraph.LinkTarget] {
            EntityGraph.suggestedLinkTargets(forVendor: doc.vendor)
        }

        /// Project items whose title or list matches the vendor's keywords — the pre-suggested
        /// projects for a contractor receipt (Act V V1-A).
        var suggestedProjectItems: [LinkableProjectItem] {
            guard suggestedTargets.contains(.project) else { return [] }
            let keywords = EntityGraph.projectMatchKeywords(forVendor: doc.vendor)
            guard !keywords.isEmpty else { return [] }
            return projectItems.filter { candidate in
                let hay = "\(candidate.item.title) \(candidate.listTitle)".lowercased()
                return keywords.contains { hay.contains($0) }
            }
        }

        /// The plant care-items already linked to this doc.
        var linkedPlants: [CareItem] {
            let ids = Set(doc.linkedCareItemIds ?? [])
            return plants.filter { ids.contains($0.id) }
        }

        /// The project items already linked to this doc.
        var linkedProjectItems: [LinkableProjectItem] {
            let ids = Set(doc.linkedProjectItemIds ?? [])
            return projectItems.filter { ids.contains($0.id) }
        }

        /// Whether an all-day event with this doc's title already sits on the `dueDate` day.
        var onCalendar: Bool {
            guard let due = doc.dueDate else { return false }
            let cal = Calendar.current
            return events.contains {
                $0.title == doc.title && cal.isDate($0.startDate, inSameDayAs: due)
            }
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case pagesLoaded([String: Data])
        case eventsLoaded([FamilyEvent])
        case membersLoaded([HouseholdMember])
        case petsLoaded([CareItem])
        case plantsLoaded([CareItem])
        case projectItemsLoaded([LinkableProjectItem])
        case allDocumentsLoaded([FamilyDomain.Document])
        case expensesLoaded([Expense])
        case relatedDocTapped(FamilyDomain.Document)
        indirect case relatedDoc(PresentationAction<Action>)
        case petToggled(String)
        case careItemToggled(String)
        case projectItemToggled(String)
        case addToCalendarTapped
        case eventAdded(FamilyEvent)
        case editTitleTapped
        case commitTitle
        /// The rich-text notes editor changed (Rich-Text C1); persisted debounced as Markdown.
        case notesChanged(String)
        case typeSelected(DocumentType)
        case reprocessTapped
        case reprocessed(FamilyDomain.Document?)
        case deleteTapped
        case confirmDelete
        case delegate(Delegate)
        case binding(BindingAction<State>)
    }

    public enum Delegate: Equatable {
        case didChange(FamilyDomain.Document)
        case didDelete(String)
    }

    public init() {}

    @Dependency(\.persistence) var persistence
    @Dependency(\.storage) var storage
    @Dependency(\.docs) var docs
    @Dependency(\.analytics) var analytics
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date
    @Dependency(\.dismiss) var dismiss
    @Dependency(\.continuousClock) var clock

    /// Debounce the notes save so a burst of keystrokes collapses to one Firestore write.
    private enum CancelID: Hashable { case saveNotes }
    static let notesDebounce: Duration = .milliseconds(700)

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    private func uid() -> String? {
        @Shared(.user) var user
        return user?.id
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                guard let hid = hid() else { return .none }
                let pagePaths = state.doc.pagePaths.filter { $0.hasSuffix(".jpg") }
                state.pagesLoading = !pagePaths.isEmpty
                return .run { send in
                    // Pages, events, members, pets, and the full doc/expense sets load in parallel;
                    // each degrades independently. The doc/expense sets feed the P24 "Related" card.
                    async let events = persistence.events(hid)
                    async let members = persistence.members(hid)
                    async let careItems = persistence.careItems(hid)
                    async let documents = persistence.documents(hid)
                    async let expenses = persistence.expenses(hid)
                    async let lists = persistence.lists(hid)
                    await send(.eventsLoaded((try? await events) ?? []))
                    await send(.membersLoaded((try? await members) ?? []))
                    let care = (try? await careItems) ?? []
                    await send(.petsLoaded(care.filter { $0.kind == .pet }))
                    await send(.plantsLoaded(care.filter { $0.kind == .plant }))
                    await send(.allDocumentsLoaded((try? await documents) ?? []))
                    await send(.expensesLoaded((try? await expenses) ?? []))
                    // Project-list items (Act V V1-A) — items inside `.project` lists, each tagged
                    // with its list title. Loaded lazily per project list; degrades independently.
                    let projectLists = ((try? await lists) ?? []).filter { $0.isProject }
                    var projectItems: [LinkableProjectItem] = []
                    for list in projectLists {
                        let items = (try? await persistence.listItems(hid, list.id)) ?? []
                        projectItems.append(contentsOf: items.map {
                            LinkableProjectItem(item: $0, listTitle: list.title)
                        })
                    }
                    await send(.projectItemsLoaded(projectItems))
                    var loaded: [String: Data] = [:]
                    for path in pagePaths {
                        if let data = try? await storage.downloadData(path) {
                            loaded[path] = data
                        }
                    }
                    await send(.pagesLoaded(loaded))
                }

            case let .pagesLoaded(map):
                state.pagesLoading = false
                state.pageData = map
                return .none

            case let .eventsLoaded(events):
                state.events = events
                return .none

            case let .membersLoaded(members):
                state.members = members
                return .none

            case let .petsLoaded(pets):
                state.pets = pets
                return .none

            case let .plantsLoaded(plants):
                state.plants = plants
                return .none

            case let .projectItemsLoaded(items):
                state.projectItems = items
                return .none

            case let .allDocumentsLoaded(documents):
                state.allDocuments = documents
                return .none

            case let .expensesLoaded(expenses):
                state.expenses = expenses
                return .none

            case let .relatedDocTapped(doc):
                analytics.log("related_item_tapped", ["kind": "document"])
                state.relatedDoc = DocumentDetailReducer.State(doc: doc)
                return .none

            // Bubble a nested detail's edits/deletes up so the library stays in sync.
            case let .relatedDoc(.presented(.delegate(delegate))):
                return .send(.delegate(delegate))

            case .relatedDoc:
                return .none

            case let .petToggled(petID):
                guard let hid = hid() else { return .none }
                let linking: Bool
                if let idx = state.doc.linkedPetIds.firstIndex(of: petID) {
                    state.doc.linkedPetIds.remove(at: idx)
                    linking = false
                } else {
                    state.doc.linkedPetIds.append(petID)
                    linking = true
                }
                if linking { analytics.log("doc_entity_linked", ["kind": "pet"]) }
                let doc = state.doc
                return .run { send in
                    try await persistence.saveDocument(hid, doc)
                    await send(.delegate(.didChange(doc)))
                }

            case let .careItemToggled(itemID):
                guard let hid = hid() else { return .none }
                var ids = state.doc.linkedCareItemIds ?? []
                let linking: Bool
                if let idx = ids.firstIndex(of: itemID) {
                    ids.remove(at: idx)
                    linking = false
                } else {
                    ids.append(itemID)
                    linking = true
                }
                state.doc.linkedCareItemIds = ids.isEmpty ? nil : ids
                if linking { analytics.log("doc_entity_linked", ["kind": "plant"]) }
                let doc = state.doc
                return .run { send in
                    try await persistence.saveDocument(hid, doc)
                    await send(.delegate(.didChange(doc)))
                }

            case let .projectItemToggled(itemID):
                guard let hid = hid() else { return .none }
                var ids = state.doc.linkedProjectItemIds ?? []
                let linking: Bool
                if let idx = ids.firstIndex(of: itemID) {
                    ids.remove(at: idx)
                    linking = false
                } else {
                    ids.append(itemID)
                    linking = true
                }
                state.doc.linkedProjectItemIds = ids.isEmpty ? nil : ids
                if linking { analytics.log("doc_entity_linked", ["kind": "project"]) }
                let doc = state.doc
                return .run { send in
                    try await persistence.saveDocument(hid, doc)
                    await send(.delegate(.didChange(doc)))
                }

            case .addToCalendarTapped:
                guard let hid = hid(), let due = state.doc.dueDate, !state.onCalendar else { return .none }
                let event = FamilyEvent(
                    id: uuid().uuidString,
                    title: state.doc.title,
                    startDate: due,
                    isAllDay: true,
                    notes: "From Family Brain",
                    createdAt: date.now,
                    updatedAt: date.now
                )
                @Shared(.user) var user
                let actorID = user?.id
                return .run { send in
                    try await persistence.saveEvent(hid, event)
                    try? await persistence.logActivity(hid, .eventAdded(title: event.title, actorID: actorID))
                    await send(.eventAdded(event))
                }

            case let .eventAdded(event):
                // Reflect the new event locally so the button swaps to its done state immediately.
                state.events.append(event)
                return .none

            case .editTitleTapped:
                state.titleDraft = state.doc.title
                state.isEditingTitle = true
                return .none

            case .commitTitle:
                state.isEditingTitle = false
                let trimmed = state.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != state.doc.title, let hid = hid() else { return .none }
                state.doc.title = trimmed
                let doc = state.doc
                return .run { send in
                    try await persistence.saveDocument(hid, doc)
                    await send(.delegate(.didChange(doc)))
                }

            case let .notesChanged(markdown):
                let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : markdown
                guard trimmed != state.doc.notes, let hid = hid() else { return .none }
                state.doc.notes = trimmed
                let doc = state.doc
                return .run { send in
                    try await clock.sleep(for: Self.notesDebounce)
                    try await persistence.saveDocument(hid, doc)
                    await send(.delegate(.didChange(doc)))
                }
                .cancellable(id: CancelID.saveNotes, cancelInFlight: true)

            case let .typeSelected(type):
                guard type != state.doc.type, let hid = hid() else { return .none }
                state.doc.type = type
                let doc = state.doc
                return .run { send in
                    try await persistence.saveDocument(hid, doc)
                    await send(.delegate(.didChange(doc)))
                }

            case .reprocessTapped:
                guard let hid = hid() else { return .none }
                let docId = state.doc.id
                return .run { send in
                    try? await docs.process(docId)
                    let updated = (try? await persistence.documents(hid)) ?? []
                    await send(.reprocessed(updated.first { $0.id == docId }))
                }

            case let .reprocessed(updated):
                guard let updated else { return .none }
                state.doc = updated
                return .send(.delegate(.didChange(updated)))

            case .deleteTapped:
                state.showDeleteConfirm = true
                return .none

            case .confirmDelete:
                state.showDeleteConfirm = false
                guard let hid = hid() else { return .none }
                let doc = state.doc
                return .run { send in
                    try? await storage.deletePaths(doc.pagePaths)
                    try? await persistence.deleteDocument(hid, doc.id)
                    await send(.delegate(.didDelete(doc.id)))
                    await dismiss()
                }

            case .delegate, .binding:
                return .none
            }
        }
        .ifLet(\.$relatedDoc, action: \.relatedDoc) {
            DocumentDetailReducer()
        }
    }
}

public struct DocumentDetailView: View {
    @Bindable var store: StoreOf<DocumentDetailReducer>

    public init(store: StoreOf<DocumentDetailReducer>) {
        self.store = store
    }

    private var doc: FamilyDomain.Document { store.doc }
    private var tint: Color { DocumentRow.tint(for: doc.type) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pagesSection
                headerSection
                if let expiry = doc.expiryDate {
                    DocumentDateChip(date: expiry, kind: .expiry)
                }
                if doc.dueDate != nil {
                    calendarAction
                }
                fieldsSection
                notesSection
                relatedSection
                if doc.processingState != .processed {
                    processingSection
                }
                fullTextSection
            }
            .padding(16)
            // Keep the last element (Full text) clear of the tab bar so it stays tappable/scrollable.
            .padding(.bottom, 40)
        }
        .background(Color.familyCanvas)
        .navigationTitle("Document")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(
            item: $store.scope(state: \.relatedDoc, action: \.relatedDoc)
        ) { relatedStore in
            DocumentDetailView(store: relatedStore)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        store.send(.editTitleTapped)
                    } label: { Label("Edit title", systemImage: "pencil") }
                        .accessibilityIdentifier("detail-edit-title")

                    Menu {
                        ForEach(DocumentType.allCases, id: \.self) { type in
                            Button {
                                store.send(.typeSelected(type))
                            } label: {
                                Label(type.displayName, systemImage: type.symbolName)
                            }
                        }
                    } label: { Label("Change type", systemImage: "tag") }

                    if !store.plants.isEmpty || !store.pets.isEmpty || !store.projectItems.isEmpty {
                        Button {
                            store.send(.binding(.set(\.showLinkSheet, true)))
                        } label: { Label("Link to…", systemImage: "link") }
                            .accessibilityIdentifier("detail-link-to")
                    }

                    Button(role: .destructive) {
                        store.send(.deleteTapped)
                    } label: { Label("Delete", systemImage: "trash") }
                        .accessibilityIdentifier("detail-delete")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("detail-menu")
            }
        }
        .task { store.send(.task) }
        .alert("Rename document", isPresented: $store.isEditingTitle) {
            TextField("Title", text: $store.titleDraft)
                .accessibilityIdentifier("detail-title-field")
            Button("Cancel", role: .cancel) {}
            Button("Save") { store.send(.commitTitle) }
                .accessibilityIdentifier("detail-title-save")
        }
        .alert("Delete this document?", isPresented: $store.showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { store.send(.confirmDelete) }
                .accessibilityIdentifier("detail-delete-confirm")
        } message: {
            Text("This removes the document and its scanned pages. This can't be undone.")
        }
        .sheet(isPresented: $store.showLinkSheet) {
            DocumentLinkSheet(store: store)
        }
    }

    // MARK: Pages

    @ViewBuilder
    private var pagesSection: some View {
        let jpgPaths = doc.pagePaths.filter { $0.hasSuffix(".jpg") }
        if !jpgPaths.isEmpty {
            VStack(spacing: 10) {
                ForEach(jpgPaths, id: \.self) { path in
                    if let data = store.pageData[path], let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 340)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityIdentifier("detail-page-image")
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.inkSoft.opacity(0.12))
                            .frame(height: 200)
                            .overlay { if store.pagesLoading { ProgressView() } }
                    }
                }
            }
        } else if doc.pagePaths.contains(where: { $0.hasSuffix(".pdf") }) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
                .frame(height: 140)
                .overlay {
                    Label("PDF document", systemImage: "doc.fill")
                        .foregroundStyle(tint)
                }
        }
    }

    // MARK: Header (icon + title + type)

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 44, height: 44)
                Image(systemName: doc.type.symbolName)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(doc.title)
                    .familyTitle(.title3)
                    .foregroundStyle(Color.ink)
                    .accessibilityIdentifier("detail-title")
                Text(doc.type.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Add-to-calendar action

    @ViewBuilder
    private var calendarAction: some View {
        if store.onCalendar {
            Label("On the calendar", systemImage: "checkmark.circle.fill")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.bacanGreen.opacity(0.12), in: Capsule(style: .continuous))
                .accessibilityIdentifier("detail-on-calendar")
        } else {
            Button {
                store.send(.addToCalendarTapped)
            } label: {
                Label("Add to calendar", systemImage: "calendar.badge.plus")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.bacanGreen, in: Capsule(style: .continuous))
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("detail-add-to-calendar")
        }
    }

    // MARK: Fields

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let vendor = nonEmpty(doc.vendor) {
                fieldRow("Vendor", vendor)
            }
            if let amount = doc.amount {
                fieldRow("Amount", Self.currency(amount))
            }
            if let docDate = doc.docDate {
                fieldRow("Date", Self.dateText(docDate))
            }
            if let due = doc.dueDate {
                fieldRow("Due", Self.dateText(due))
            }
            if !doc.tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Tags")
                    FlowTags(tags: doc.tags, tint: tint)
                }
            }
            if let summary = nonEmpty(doc.summary) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Summary")
                    Text(summary)
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.familySurface))
    }

    private func fieldRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            fieldLabel(label)
            Spacer()
            Text(value).foregroundStyle(Color.ink).multilineTextAlignment(.trailing)
        }
    }

    // MARK: Notes (Rich-Text C1 — the family's own annotations)

    /// A rich-text notes card. Edits persist debounced as a Markdown string via `notesChanged`.
    /// Writing Tools + Genmoji ride along on the standard control (Apple-Intelligence devices only).
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes")
                .familyTitle(.subheadline)
                .foregroundStyle(Color.ink)
            RichNoteEditor(
                markdown: Binding(
                    get: { store.doc.notes ?? "" },
                    set: { store.send(.notesChanged($0)) }
                ),
                placeholder: "Add a note — what this is, where it's filed, follow-ups…"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.familySurface))
        .accessibilityIdentifier("detail-notes-section")
    }

    // MARK: Related (P24 — the navigable graph)

    /// Cross-entity connections for this document: the expense it became, other docs from the same
    /// vendor, the "projects" (shared tags) it belongs to, and the pets / members it's linked to.
    /// Every group hides itself when empty; each doc row pushes another `DocumentDetailView`.
    @ViewBuilder
    private var relatedSection: some View {
        let related = store.related
        let linkedMembers = store.members.filter { doc.linkedMemberIds.contains($0.id) }
        let linkedPets = store.pets.filter { doc.linkedPetIds.contains($0.id) }
        let linkedPlants = store.linkedPlants
        let linkedProjects = store.linkedProjectItems
        let hasContent = !related.isEmpty || !linkedPlants.isEmpty || !linkedProjects.isEmpty
        if hasContent {
            VStack(alignment: .leading, spacing: 14) {
                Text("Related")
                    .familyTitle(.subheadline)
                    .foregroundStyle(Color.ink)
                    .accessibilityIdentifier("detail-related-header")

                if !linkedPlants.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Plants")
                        ForEach(linkedPlants) { plant in
                            LinkedEntityRow(
                                name: plant.name,
                                subtitle: plant.species ?? plant.location,
                                symbol: "leaf.fill",
                                color: .bacanGreen
                            )
                            .accessibilityIdentifier("detail-related-plant-\(plant.id)")
                        }
                    }
                }

                if !linkedProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel("Projects")
                        ForEach(linkedProjects) { project in
                            LinkedEntityRow(
                                name: project.item.title,
                                subtitle: project.listTitle,
                                symbol: "hammer.fill",
                                color: .terracotta
                            )
                            .accessibilityIdentifier("detail-related-project-\(project.id)")
                        }
                    }
                }

                if let expense = related.linkedExpense {
                    relatedExpenseRow(expense)
                }

                if !related.sameVendor.isEmpty {
                    relatedGroup(
                        title: "More from \(related.vendorName ?? "this vendor")",
                        docs: related.sameVendor
                    )
                }

                ForEach(related.projects) { project in
                    relatedGroup(title: "Part of: \(project.title)", docs: project.documents)
                }

                if !linkedPets.isEmpty || !linkedMembers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Linked to")
                        FlexibleWrap(linkChips, spacing: 6) { chip in
                            HStack(spacing: 5) {
                                Image(systemName: chip.symbol)
                                    .font(.caption2)
                                    .foregroundStyle(chip.color)
                                Text(chip.name)
                                    .font(.caption)
                                    .foregroundStyle(Color.ink)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(chip.color.opacity(0.14), in: Capsule())
                            .accessibilityIdentifier(chip.a11y)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.familySurface))
            .accessibilityIdentifier("detail-related-section")
        }
    }

    /// The linked-expense summary row (informational — the family's expenses live in the Money screen).
    private func relatedExpenseRow(_ expense: Expense) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.sage.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.sage)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Logged as a \(Self.currency(expense.amount)) \(expense.category.displayName) expense")
                    .font(.subheadline)
                    .foregroundStyle(Color.ink)
                Text("In Money")
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("detail-related-expense")
    }

    /// A titled group of related documents, each a tappable row pushing its own detail.
    private func relatedGroup(title: String, docs: [FamilyDomain.Document]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.inkSoft)
                Text("(\(docs.count))")
                    .font(.footnote)
                    .foregroundStyle(Color.inkSoft)
            }
            ForEach(docs) { related in
                Button {
                    store.send(.relatedDocTapped(related))
                } label: {
                    RelatedDocRow(doc: related)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("detail-related-doc-\(related.id)")
            }
        }
    }

    /// A compact "linked to" chip (a pet or a member).
    struct LinkChip: Hashable {
        var id: String
        var name: String
        var symbol: String
        var color: Color
        var a11y: String
    }

    /// Linked pets + members rendered as compact chips (single "connections" home, P24).
    private var linkChips: [LinkChip] {
        let pets = store.pets.filter { doc.linkedPetIds.contains($0.id) }
            .map { LinkChip(id: "pet-\($0.id)", name: $0.name, symbol: "pawprint.fill", color: .sky, a11y: "detail-pet-\($0.id)") }
        let members = store.members.filter { doc.linkedMemberIds.contains($0.id) }
            .map { member -> LinkChip in
                let rgb = member.color.rgb
                return LinkChip(
                    id: "member-\(member.id)",
                    name: member.name,
                    symbol: "person.fill",
                    color: Color(red: rgb.red, green: rgb.green, blue: rgb.blue),
                    a11y: "detail-member-\(member.id)"
                )
            }
        return pets + members
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption).textCase(.uppercase)
            .foregroundStyle(Color.inkSoft)
    }

    // MARK: Processing

    private var processingSection: some View {
        HStack(spacing: 10) {
            Image(systemName: doc.processingState == .failed ? "exclamationmark.triangle.fill" : "hourglass")
                .foregroundStyle(doc.processingState == .failed ? .orange : Color.inkSoft)
            Text(doc.processingState == .failed ? "Processing failed." : "Still processing…")
                .foregroundStyle(Color.inkSoft)
            Spacer()
            Button("Process again") { store.send(.reprocessTapped) }
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
                .accessibilityIdentifier("detail-reprocess")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.familySurface))
    }

    // MARK: Full text

    @ViewBuilder
    private var fullTextSection: some View {
        if let text = nonEmpty(doc.extractedText) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    store.send(.binding(.set(\.showFullText, !store.showFullText)))
                } label: {
                    HStack {
                        Text("Full text").familyTitle(.subheadline).foregroundStyle(Color.ink)
                        Spacer()
                        Image(systemName: store.showFullText ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.inkSoft)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("detail-fulltext-toggle")

                if store.showFullText {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(Color.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                        .accessibilityIdentifier("detail-fulltext")
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.familySurface))
        }
    }

    // MARK: Helpers

    private func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func currency(_ amount: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = "USD"
        return fmt.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
    }

    static func dateText(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        return df.string(from: date)
    }
}

/// A lightweight related-document row for the "Related" card — type icon + title + a vendor/amount
/// meta line + a chevron. Tapping (handled by the enclosing Button) pushes another detail.
struct RelatedDocRow: View {
    let doc: FamilyDomain.Document
    private var tint: Color { DocumentRow.tint(for: doc.type) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.16)).frame(width: 32, height: 32)
                Image(systemName: doc.type.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.title)
                    .font(.subheadline)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if let meta = metaLine {
                    Text(meta)
                        .font(.caption2)
                        .foregroundStyle(Color.inkSoft)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var metaLine: String? {
        var parts: [String] = [doc.type.displayName]
        if let vendor = doc.vendor?.trimmingCharacters(in: .whitespacesAndNewlines), !vendor.isEmpty {
            parts.append(vendor)
        }
        if let amount = doc.amount, amount > 0 {
            parts.append(DocumentDetailView.currency(amount))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// An informational "Related" row for a linked plant or project (Act V V1-A). Styled like
/// `RelatedDocRow` (icon + name + subtitle) but non-navigating: the reverse view (opening the plant
/// or project) lives in ChoresFeature and is a follow-up, so the row reads as a connection, not a link.
struct LinkedEntityRow: View {
    let name: String
    let subtitle: String?
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.16)).frame(width: 32, height: 32)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Color.inkSoft)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// The "Link to…" sheet (Act V V1-A — receipt↔entity). Lets the family connect a Brain document to
/// the plants, pets, and project items it relates to. When the document's vendor matches a known
/// pattern (garden→plants, vet→pets, deck/contractor→project) the matching entities are surfaced in a
/// pre-suggested "Suggested" section for one-tap linking; every entity is also available in its full
/// category section below. Selections persist immediately via the document save path.
struct DocumentLinkSheet: View {
    @Bindable var store: StoreOf<DocumentDetailReducer>

    private var doc: FamilyDomain.Document { store.doc }
    private var linkedCareIds: Set<String> { Set(doc.linkedCareItemIds ?? []) }
    private var linkedPetIds: Set<String> { Set(doc.linkedPetIds) }
    private var linkedProjectIds: Set<String> { Set(doc.linkedProjectItemIds ?? []) }

    /// The suggestion caption, e.g. "Because this is from Green Thumb Nursery".
    private var suggestionCaption: String? {
        guard !store.suggestedTargets.isEmpty,
              let vendor = doc.vendor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !vendor.isEmpty
        else { return nil }
        return "Because this is from \(vendor)"
    }

    var body: some View {
        NavigationStack {
            List {
                suggestedSection
                if !store.plants.isEmpty {
                    Section("Plants") {
                        ForEach(store.plants) { plant in
                            entityRow(
                                name: plant.name,
                                subtitle: plant.species ?? plant.location,
                                symbol: "leaf.fill",
                                color: .bacanGreen,
                                linked: linkedCareIds.contains(plant.id),
                                a11y: "link-plant-\(plant.id)"
                            ) { store.send(.careItemToggled(plant.id)) }
                        }
                    }
                }
                if !store.pets.isEmpty {
                    Section("Pets") {
                        ForEach(store.pets) { pet in
                            entityRow(
                                name: pet.name,
                                subtitle: pet.breed,
                                symbol: "pawprint.fill",
                                color: .sky,
                                linked: linkedPetIds.contains(pet.id),
                                a11y: "link-pet-\(pet.id)"
                            ) { store.send(.petToggled(pet.id)) }
                        }
                    }
                }
                if !store.projectItems.isEmpty {
                    Section("Projects") {
                        ForEach(store.projectItems) { project in
                            entityRow(
                                name: project.item.title,
                                subtitle: project.listTitle,
                                symbol: "hammer.fill",
                                color: .terracotta,
                                linked: linkedProjectIds.contains(project.id),
                                a11y: "link-project-\(project.id)"
                            ) { store.send(.projectItemToggled(project.id)) }
                        }
                    }
                }
            }
            .navigationTitle("Link to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.send(.binding(.set(\.showLinkSheet, false))) }
                        .accessibilityIdentifier("link-sheet-done")
                }
            }
        }
    }

    /// The vendor-driven suggestions block: plants for garden vendors, pets for vets, the matched
    /// project items for contractor vendors. Hidden entirely when the vendor gives no signal.
    @ViewBuilder
    private var suggestedSection: some View {
        let targets = store.suggestedTargets
        let suggestedPlants = targets.contains(.plants) ? store.plants : []
        let suggestedPets = targets.contains(.pets) ? store.pets : []
        let suggestedProjects = store.suggestedProjectItems
        if !suggestedPlants.isEmpty || !suggestedPets.isEmpty || !suggestedProjects.isEmpty {
            Section {
                ForEach(suggestedPlants) { plant in
                    entityRow(
                        name: plant.name, subtitle: plant.species ?? plant.location,
                        symbol: "leaf.fill", color: .bacanGreen,
                        linked: linkedCareIds.contains(plant.id),
                        a11y: "suggest-plant-\(plant.id)"
                    ) { store.send(.careItemToggled(plant.id)) }
                }
                ForEach(suggestedPets) { pet in
                    entityRow(
                        name: pet.name, subtitle: pet.breed,
                        symbol: "pawprint.fill", color: .sky,
                        linked: linkedPetIds.contains(pet.id),
                        a11y: "suggest-pet-\(pet.id)"
                    ) { store.send(.petToggled(pet.id)) }
                }
                ForEach(suggestedProjects) { project in
                    entityRow(
                        name: project.item.title, subtitle: project.listTitle,
                        symbol: "hammer.fill", color: .terracotta,
                        linked: linkedProjectIds.contains(project.id),
                        a11y: "suggest-project-\(project.id)"
                    ) { store.send(.projectItemToggled(project.id)) }
                }
            } header: {
                Label("Suggested", systemImage: "sparkles")
            } footer: {
                if let caption = suggestionCaption { Text(caption) }
            }
            .accessibilityIdentifier("link-suggested-section")
        }
    }

    /// One toggle-able entity row — a filled/empty check reflects the linked state; the whole row taps.
    private func entityRow(
        name: String,
        subtitle: String?,
        symbol: String,
        color: Color,
        linked: Bool,
        a11y: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(color.opacity(0.16)).frame(width: 32, height: 32)
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.subheadline).foregroundStyle(Color.ink).lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption2).foregroundStyle(Color.inkSoft).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: linked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(linked ? color : Color.inkSoft.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(a11y)
    }
}

/// Simple wrapping tag row (no scrolling needed at family scale).
struct FlowTags: View {
    let tags: [String]
    let tint: Color

    var body: some View {
        FlexibleWrap(tags, spacing: 6) { tag in
            Text(tag)
                .font(.caption2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(tint.opacity(0.15), in: Capsule())
                .foregroundStyle(tint)
        }
    }
}
