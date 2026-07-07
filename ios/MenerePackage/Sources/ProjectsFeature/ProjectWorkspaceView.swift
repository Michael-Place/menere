import ComposableArchitecture
import FamilyDomain
import MenereUI
import SwiftUI

public struct ProjectWorkspaceView: View {
    @Bindable var store: StoreOf<ProjectWorkspaceReducer>
    @Environment(\.openURL) private var openURL

    public init(store: StoreOf<ProjectWorkspaceReducer>) {
        self.store = store
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { store.project.notes ?? "" },
            set: { store.send(.notesChanged($0)) }
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                inspirationSection
                suggestionsSection
                documentsSection
                budgetSection
                contactsSection
                linksSection
                tasksSection
                notesSection
                deleteButton
            }
            .padding(.bottom, 40)
        }
        .background(Color.familyCanvas)
        .navigationTitle(store.project.name.isEmpty ? "Project" : store.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.task) }
        .sheet(isPresented: $store.showLibraryBrowser) {
            PhotoLibraryBrowser { ids in store.send(.libraryAssetsPicked(ids)) }
        }
        .fullScreenCover(isPresented: $store.showCamera) {
            CameraPicker(
                onCapture: { ui in
                    let data = CaptureImageProcessing.downscaledJPEG(from: ui) ?? ui.jpegData(compressionQuality: 0.8)
                    if let data { store.send(.cameraCaptured(data)) } else { store.send(.cameraTapped) }
                },
                onCancel: { store.send(.cameraCaptured(Data())) }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $store.showAddLink) { addLinkSheet }
        .sheet(isPresented: $store.showDocPicker) { docPickerSheet }
        .sheet(isPresented: $store.showContactEditor) { contactEditorSheet }
        .sheet(isPresented: $store.showBudgetEditor) { budgetEditorSheet }
        .fullScreenCover(
            isPresented: Binding(
                get: { store.viewingPhotoPath != nil },
                set: { if !$0 { store.send(.dismissViewer) } }
            )
        ) {
            photoViewer
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let cover = store.project.coverImagePath {
                        BacanImage(path: cover, targetSize: CGSize(width: 1000, height: 600))
                    } else {
                        LinearGradient(
                            colors: [ProjectPhasePalette.color(store.project.status).opacity(0.30), Color.familySurface],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.clear, .black.opacity(store.project.coverImagePath == nil ? 0 : 0.35)],
                        startPoint: .center, endPoint: .bottom
                    )
                )

                if store.project.coverImagePath != nil {
                    Text(store.project.name)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                        .padding(16)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                // Editable name (shown here when there's no photo to overlay it on).
                if store.project.coverImagePath == nil {
                    TextField("Project name", text: $store.project.name)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.ink)
                        .onSubmit { store.send(.headerCommitted) }
                        .accessibilityIdentifier("project-name-field")
                }

                // Phase picker.
                Menu {
                    ForEach(ProjectPhase.allCases, id: \.self) { phase in
                        Button {
                            store.send(.phaseSelected(phase))
                        } label: {
                            Label(phase.displayName, systemImage: phase.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        PhaseChip(phase: store.project.status)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.inkSoft)
                    }
                }
                .accessibilityIdentifier("project-phase-menu")

                // Target date.
                Toggle(isOn: Binding(
                    get: { store.project.targetDate != nil },
                    set: { store.send(.targetToggled($0)) }
                )) {
                    Label("Target date", systemImage: "calendar")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.ink)
                }
                .tint(Color.bacanGreen)

                if store.project.targetDate != nil {
                    DatePicker(
                        "Target",
                        selection: Binding(
                            get: { store.project.targetDate ?? Date() },
                            set: { store.send(.targetChanged($0)) }
                        ),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                }
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.familySurface))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }

    // MARK: Inspiration board

    private var inspirationSection: some View {
        SectionCard(title: "Inspiration board", systemImage: "photo.on.rectangle.angled", accent: .marigold) {
            HStack(spacing: 10) {
                Button { store.send(.addPhotoTapped) } label: {
                    Label("Add photos", systemImage: "photo.badge.plus")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("add-inspiration-photos")

                if CameraPicker.isCameraAvailable {
                    Button { store.send(.cameraTapped) } label: {
                        Label("Camera", systemImage: "camera")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    }
                    .buttonStyle(.pressable)
                }
                Spacer()
                if store.boardLoadingCount > 0 { ProgressView() }
            }
            .foregroundStyle(Color.bacanGreen)
            .padding(.bottom, 4)

            let photos = store.project.photoPaths ?? []
            if photos.isEmpty {
                emptyHint("Start gathering ideas — pool shapes, tile colors, dream classrooms. 🏊")
            } else {
                let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(photos, id: \.self) { path in
                        BacanImage(path: path, targetSize: CGSize(width: 300, height: 300))
                            .aspectRatio(1, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onTapGesture { store.send(.photoTapped(path)) }
                            .contextMenu {
                                Button { store.send(.setCoverFromBoard(path)) } label: {
                                    Label("Set as cover", systemImage: "photo")
                                }
                                Button(role: .destructive) { store.send(.removePhoto(path)) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
    }

    // MARK: Suggested items inbox

    /// A gently-highlighted card of docs the AI/capture *guessed* belong here (`suggestedProjectId`),
    /// each with **Add** (confirm → moves into Documents) or **Dismiss** (wave it off). Hidden when empty.
    @ViewBuilder
    private var suggestionsSection: some View {
        let suggestions = store.suggestedDocuments
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("\(suggestions.count) \(suggestions.count == 1 ? "item" : "items") suggested for this project")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(Color.marigold)
                }

                Text("These looked related — keep them?")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Color.inkSoft)

                VStack(spacing: 8) {
                    ForEach(suggestions) { doc in
                        SuggestionRow(
                            doc: doc,
                            onAdd: {
                                store.send(.acceptSuggestion(doc))
                                MenereHaptics.softTap()
                            },
                            onDismiss: { store.send(.dismissSuggestion(doc)) }
                        )
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.marigold.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.marigold.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .accessibilityIdentifier("project-suggestions-section")
        }
    }

    // MARK: Documents

    private var documentsSection: some View {
        SectionCard(title: "Documents", systemImage: "doc.text.fill", accent: .sky) {
            Button { store.send(.addDocumentTapped) } label: {
                Label("Add existing document", systemImage: "plus.circle")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Color.bacanGreen)
            .padding(.bottom, 4)
            .accessibilityIdentifier("add-project-document")

            let docs = store.linkedDocuments
            if docs.isEmpty {
                emptyHint("Quotes, invoices, brochures from the Family Brain will live here.")
            } else {
                VStack(spacing: 8) {
                    ForEach(docs) { doc in
                        DocumentRow(doc: doc) { store.send(.unlinkDocument(doc)) }
                    }
                }
            }
        }
    }

    // MARK: Budget / Quotes

    /// A comparison built from the project's linked Brain docs that carry an `amount` (vendor +
    /// price, cheapest highlighted), plus an editable `budgetTarget` and a plain-language readout of
    /// the low quote vs. the target. All the money math lives in `QuoteStats` — this stays a readout.
    private var budgetSection: some View {
        SectionCard(title: "Budget & quotes", systemImage: "dollarsign.circle.fill", accent: .bacanGreen) {
            let stats = store.quoteStats
            let target = store.project.budgetTarget

            // Budget target row (tap to set / edit).
            Button { store.send(.setBudgetTapped) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "target").foregroundStyle(Color.bacanGreen)
                    if let target {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Budget")
                                .font(.caption).foregroundStyle(Color.inkSoft)
                            Text(target, format: .currency(code: "USD").precision(.fractionLength(0)))
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .foregroundStyle(Color.ink)
                        }
                    } else {
                        Text("Set a budget")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.bacanGreen)
                    }
                    Spacer()
                    Image(systemName: "pencil")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.familyCanvas))
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("set-project-budget")

            if let stats {
                // Headline: "3 quotes · $48k–$71k".
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.doc.horizontal").foregroundStyle(Color.sky)
                    Text(stats.headline)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.ink)
                    Spacer()
                }
                .padding(.top, 4)

                // Plain-language readout: low quote vs. target.
                if let readout = budgetReadout(stats: stats, target: target) {
                    Text(readout)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(readout.contains("over") ? Color.terracotta : Color.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The quotes, cheapest highlighted.
                VStack(spacing: 8) {
                    ForEach(store.quoteDocuments) { doc in
                        QuoteRow(doc: doc, isCheapest: doc.id == stats.cheapestDocId)
                    }
                }
                .padding(.top, 2)
            } else {
                emptyHint("Link quotes to this project (Documents above) and the price comparison shows up here — cheapest bid highlighted. 💸")
            }
        }
    }

    /// "Low quote is $23k under budget" / "$4k over budget" / a neutral range when there's no target.
    private func budgetReadout(stats: ProjectWorkspaceReducer.QuoteStats, target: Double?) -> String? {
        guard let target, target > 0 else { return nil }
        let delta = target - stats.low
        let amount = ProjectWorkspaceReducer.QuoteStats.compact(abs(delta))
        if abs(delta) < 1 {
            return "Low quote is right at budget."
        } else if delta > 0 {
            return "Low quote is \(amount) under budget. 🎉"
        } else {
            return "Low quote is \(amount) over budget."
        }
    }

    // MARK: Contacts

    /// The people the family is talking to — contractors, admissions offices, realtors. Rows show
    /// name + role/company with tappable call/email buttons; tap the row to edit.
    private var contactsSection: some View {
        SectionCard(title: "Contacts", systemImage: "person.2.fill", accent: .terracotta) {
            Button { store.send(.addContactTapped) } label: {
                Label("Add contact", systemImage: "person.crop.circle.badge.plus")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Color.bacanGreen)
            .padding(.bottom, 4)
            .accessibilityIdentifier("add-project-contact")

            let contacts = store.project.contacts ?? []
            if contacts.isEmpty {
                emptyHint("Add the contractors or schools you're talking to — with phone, email, and their quote. 📇")
            } else {
                VStack(spacing: 8) {
                    ForEach(contacts) { contact in
                        ContactRow(
                            contact: contact,
                            onEdit: { store.send(.editContactTapped(contact)) },
                            onCall: { if let url = contact.phoneURL { openURL(url) } },
                            onEmail: { if let url = contact.emailURL { openURL(url) } },
                            onDelete: { store.send(.deleteContact(contact.id)) }
                        )
                    }
                }
            }
        }
    }

    // MARK: Links

    private var linksSection: some View {
        SectionCard(title: "Links", systemImage: "link", accent: .terracotta) {
            Button { store.send(.addLinkTapped) } label: {
                Label("Add link", systemImage: "plus.circle")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Color.bacanGreen)
            .padding(.bottom, 4)
            .accessibilityIdentifier("add-project-link")

            let links = store.project.links ?? []
            if links.isEmpty {
                emptyHint("Contractor sites, Pinterest boards, listings — drop them here.")
            } else {
                VStack(spacing: 8) {
                    ForEach(links) { link in
                        Button {
                            if let url = link.resolvedURL { openURL(url) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "safari")
                                    .foregroundStyle(Color.terracotta)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(link.displayTitle)
                                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                                        .foregroundStyle(Color.ink)
                                        .lineLimit(1)
                                    Text(link.url)
                                        .font(.caption)
                                        .foregroundStyle(Color.inkSoft)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.familyCanvas))
                        }
                        .buttonStyle(.pressable)
                        .contextMenu {
                            Button(role: .destructive) { store.send(.deleteLink(link.id)) } label: {
                                Label("Delete link", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Tasks

    private var tasksSection: some View {
        SectionCard(title: "Tasks", systemImage: "checklist", accent: .bacanGreen) {
            let tasks = store.project.tasks ?? []
            VStack(spacing: 8) {
                ForEach(tasks) { task in
                    HStack(spacing: 12) {
                        Button {
                            store.send(.toggleTask(task.id))
                            MenereHaptics.softTap()
                        } label: {
                            Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(task.isDone ? Color.bacanGreen : Color.inkSoft)
                                .symbolEffect(.bounce, value: task.isDone)
                        }
                        .buttonStyle(.plain)
                        Text(task.title)
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(task.isDone ? Color.inkSoft : Color.ink)
                            .strikethrough(task.isDone, color: Color.inkSoft)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button(role: .destructive) { store.send(.deleteTask(task.id)) } label: {
                            Label("Delete task", systemImage: "trash")
                        }
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle").foregroundStyle(Color.bacanGreen)
                    TextField("Add a to-do…", text: $store.newTaskTitle)
                        .font(.system(.body, design: .rounded))
                        .onSubmit { store.send(.addTaskSubmitted) }
                        .submitLabel(.done)
                        .accessibilityIdentifier("add-project-task-field")
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        SectionCard(title: "Notes", systemImage: "note.text", accent: .sage) {
            RichNoteEditor(markdown: notesBinding, placeholder: "Jot down thoughts, measurements, questions…")
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) { store.send(.deleteProjectTapped) } label: {
            Label("Delete project", systemImage: "trash")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.terracotta.opacity(0.12)))
                .foregroundStyle(Color.terracotta)
        }
        .buttonStyle(.pressable)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Sheets

    private var addLinkSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $store.linkURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("new-link-url-field")
                    TextField("Title (optional)", text: $store.linkTitle)
                }
                .listRowBackground(Color.familySurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Add link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.showAddLink = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { store.send(.saveLink) }
                        .disabled(store.linkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var docPickerSheet: some View {
        NavigationStack {
            Group {
                let docs = store.unlinkedDocuments
                if docs.isEmpty {
                    ContentUnavailableView(
                        "No other documents",
                        systemImage: "doc",
                        description: Text("Scan or import into the Family Brain first, then tag it here.")
                    )
                } else {
                    List {
                        ForEach(docs) { doc in
                            Button { store.send(.linkDocument(doc)) } label: {
                                DocumentRow(doc: doc, onUnlink: nil)
                            }
                            .listRowBackground(Color.familySurface)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.familyCanvas)
            .navigationTitle("Add a document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { store.showDocPicker = false }
                }
            }
        }
    }

    private var contactEditorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $store.contactDraft.name)
                        .accessibilityIdentifier("contact-name-field")
                    TextField("Role (Contractor, Admissions…)", text: optionalText($store.contactDraft.role))
                    TextField("Company / school", text: optionalText($store.contactDraft.company))
                }
                .listRowBackground(Color.familySurface)

                Section("Reach them") {
                    TextField("Phone", text: optionalText($store.contactDraft.phone))
                        .keyboardType(.phonePad)
                    TextField("Email", text: optionalText($store.contactDraft.email))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }
                .listRowBackground(Color.familySurface)

                // Optionally pin this contact to one of the project's quote documents.
                let quotes = store.linkedDocuments
                if !quotes.isEmpty {
                    Section("Their quote") {
                        Picker("Linked document", selection: $store.contactDraft.linkedDocId) {
                            Text("None").tag(String?.none)
                            ForEach(quotes) { doc in
                                Text(doc.title.isEmpty ? doc.type.displayName : doc.title)
                                    .tag(Optional(doc.id))
                            }
                        }
                    }
                    .listRowBackground(Color.familySurface)
                }

                Section("Notes") {
                    TextField("Anything to remember…", text: optionalText($store.contactDraft.notes), axis: .vertical)
                        .lineLimit(1...4)
                }
                .listRowBackground(Color.familySurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle(store.editingContactId == nil ? "Add contact" : "Edit contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.dismissContactEditor) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveContact) }
                        .disabled(store.contactDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("save-contact-button")
                }
            }
        }
    }

    /// Bridge a `Binding<String?>` (the model's optional fields) to the `Binding<String>` a Form
    /// TextField wants — empty text reads/writes as `nil`. The reducer re-trims on save.
    private func optionalText(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private var budgetEditorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("$").foregroundStyle(Color.inkSoft)
                        TextField("48,000", text: $store.budgetDraft)
                            .keyboardType(.numbersAndPunctuation)
                            .accessibilityIdentifier("budget-target-field")
                    }
                } footer: {
                    Text("What you're hoping to spend. We'll compare it against the quotes you've gathered.")
                }
                .listRowBackground(Color.familySurface)

                if store.project.budgetTarget != nil {
                    Section {
                        Button(role: .destructive) { store.send(.clearBudget) } label: {
                            Label("Clear budget", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color.familySurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.dismissBudgetEditor) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveBudget) }
                        .accessibilityIdentifier("save-budget-button")
                }
            }
        }
    }

    private var photoViewer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let path = store.viewingPhotoPath {
                BacanImage(path: path, contentMode: .fit)
                    .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Spacer()
                    Button { store.send(.dismissViewer) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .rounded))
            .foregroundStyle(Color.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

// MARK: - Section card chrome

struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title).font(.system(.headline, design: .rounded).weight(.bold)).foregroundStyle(Color.ink)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(accent)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.familySurface))
        .padding(.horizontal, 16)
    }
}

// MARK: - Document row

struct DocumentRow: View {
    let doc: FamilyDomain.Document
    let onUnlink: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: doc.type.symbolName)
                .foregroundStyle(Color.sky)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title.isEmpty ? doc.type.displayName : doc.title)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let vendor = doc.vendor, !vendor.isEmpty {
                        Text(vendor).lineLimit(1)
                    }
                    if let amount = doc.amount {
                        Text(amount, format: .currency(code: "USD"))
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
            }
            Spacer()
            if let onUnlink {
                Button { onUnlink() } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(Color.terracotta)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "plus.circle").foregroundStyle(Color.bacanGreen)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.familyCanvas))
    }
}

// MARK: - Contact row

/// One project contact: name + role/company, with tap-to-call / tap-to-email buttons and a quote
/// chip when linked. Tapping the body opens the editor; the phone/email glyphs act independently.
struct ContactRow: View {
    let contact: ProjectContact
    let onEdit: () -> Void
    let onCall: () -> Void
    let onEmail: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onEdit) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.terracotta.opacity(0.16)).frame(width: 34, height: 34)
                        Text(initials)
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(Color.terracotta)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.name)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                        if !contact.subtitle.isEmpty {
                            Text(contact.subtitle)
                                .font(.caption)
                                .foregroundStyle(Color.inkSoft)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if contact.phoneURL != nil {
                Button(action: onCall) {
                    Image(systemName: "phone.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.bacanGreen)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.bacanGreen.opacity(0.12)))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("contact-call")
            }
            if contact.emailURL != nil {
                Button(action: onEmail) {
                    Image(systemName: "envelope.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.sky)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.sky.opacity(0.12)))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("contact-email")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.familyCanvas))
        .contextMenu {
            Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive, action: onDelete) { Label("Delete contact", systemImage: "trash") }
        }
    }

    private var initials: String {
        let parts = contact.name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

// MARK: - Quote row

/// One quote in the Budget comparison: vendor/title + amount, with a "Low bid" badge on the cheapest.
struct QuoteRow: View {
    let doc: FamilyDomain.Document
    let isCheapest: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCheapest ? "trophy.fill" : "doc.text")
                .foregroundStyle(isCheapest ? Color.marigold : Color.sky)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(vendorLabel)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if isCheapest {
                    Text("Low bid")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.marigold)
                }
            }
            Spacer(minLength: 8)
            if let amount = doc.amount {
                Text(amount, format: .currency(code: "USD").precision(.fractionLength(0)))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.ink)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isCheapest ? Color.marigold.opacity(0.12) : Color.familyCanvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isCheapest ? Color.marigold.opacity(0.4) : .clear, lineWidth: 1)
        )
    }

    private var vendorLabel: String {
        if let vendor = doc.vendor, !vendor.isEmpty { return vendor }
        return doc.title.isEmpty ? doc.type.displayName : doc.title
    }
}

// MARK: - Suggestion row

/// One suggested doc in the inbox: title/vendor/amount + **Add** (confirm) and **Dismiss** (wave off).
struct SuggestionRow: View {
    let doc: FamilyDomain.Document
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: doc.type.symbolName)
                    .foregroundStyle(Color.marigold)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title.isEmpty ? doc.type.displayName : doc.title)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let vendor = doc.vendor, !vendor.isEmpty {
                            Text(vendor).lineLimit(1)
                        }
                        if let amount = doc.amount {
                            Text(amount, format: .currency(code: "USD"))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { onDismiss() } label: {
                    Text("Dismiss")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.inkSoft)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.familyCanvas))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("dismiss-suggestion")

                Button { onAdd() } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.bacanGreen))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("add-suggestion")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.familySurface))
    }
}

// MARK: - Preview

#Preview("Workspace") {
    NavigationStack {
        ProjectWorkspaceView(
            store: Store(
                initialState: ProjectWorkspaceReducer.State(project: Project.previewSamples[0])
            ) {
                ProjectWorkspaceReducer()
            } withDependencies: {
                $0.storage = .previewValue
            }
        )
    }
}

#Preview("Budget & contacts") {
    var project = Project.previewSamples[0]
    project.budgetTarget = 60_000
    project.contacts = [
        ProjectContact(
            name: "Dave Rivera", role: "Contractor", company: "Blue Haven Pools",
            phone: "512-555-0148", email: "dave@bluehaven.example"
        ),
        ProjectContact(
            name: "Maria Chen", role: "Sales", company: "Aqua Dreams",
            phone: "512-555-0199", email: "maria@aquadreams.example"
        ),
        ProjectContact(name: "Sun Pools front desk", role: "Contractor"),
    ]
    var state = ProjectWorkspaceReducer.State(project: project)
    // Three linked quote docs at different prices → the comparison + cheapest highlight.
    state.documents = [
        FamilyDomain.Document(title: "Blue Haven quote", type: .receipt, projectIds: [project.id], amount: 71_000, vendor: "Blue Haven Pools", uploadedBy: "preview"),
        FamilyDomain.Document(title: "Aqua Dreams quote", type: .receipt, projectIds: [project.id], amount: 48_500, vendor: "Aqua Dreams", uploadedBy: "preview"),
        FamilyDomain.Document(title: "Sun Pools quote", type: .receipt, projectIds: [project.id], amount: 63_200, vendor: "Sun Pools", uploadedBy: "preview"),
    ]
    return NavigationStack {
        ProjectWorkspaceView(
            store: Store(initialState: state) {
                ProjectWorkspaceReducer()
            } withDependencies: {
                $0.storage = .previewValue
            }
        )
    }
}

#Preview("Suggested inbox") {
    let project = Project.previewSamples[0]
    var state = ProjectWorkspaceReducer.State(project: project)
    state.documents = [
        FamilyDomain.Document(
            title: "Blue Haven — pool quote",
            type: .receipt,
            projectIds: nil,
            suggestedProjectId: project.id,
            amount: 78_500,
            vendor: "Blue Haven Pools",
            uploadedBy: "preview"
        ),
        FamilyDomain.Document(
            title: "Gunite vs. fiberglass brochure",
            type: .other,
            projectIds: nil,
            suggestedProjectId: project.id,
            vendor: "Pool Warehouse",
            uploadedBy: "preview"
        ),
    ]
    return NavigationStack {
        ProjectWorkspaceView(
            store: Store(initialState: state) {
                ProjectWorkspaceReducer()
            } withDependencies: {
                $0.storage = .previewValue
            }
        )
    }
}
