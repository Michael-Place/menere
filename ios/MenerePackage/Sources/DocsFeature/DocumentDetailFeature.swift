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
        var showFullText = false
        var isEditingTitle = false
        var titleDraft = ""
        var showDeleteConfirm = false

        public init(doc: FamilyDomain.Document) {
            self.doc = doc
            self.titleDraft = doc.title
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
        case addToCalendarTapped
        case eventAdded(FamilyEvent)
        case editTitleTapped
        case commitTitle
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
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date
    @Dependency(\.dismiss) var dismiss

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
                    // Pages, events, and members load in parallel; each degrades independently.
                    async let events = persistence.events(hid)
                    async let members = persistence.members(hid)
                    await send(.eventsLoaded((try? await events) ?? []))
                    await send(.membersLoaded((try? await members) ?? []))
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
            let linked = store.members.filter { doc.linkedMemberIds.contains($0.id) }
            if !linked.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Linked to")
                    ForEach(linked) { member in
                        HStack(spacing: 8) {
                            let rgb = member.color.rgb
                            Circle()
                                .fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                                .frame(width: 10, height: 10)
                            Text(member.name).foregroundStyle(Color.ink)
                        }
                    }
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
