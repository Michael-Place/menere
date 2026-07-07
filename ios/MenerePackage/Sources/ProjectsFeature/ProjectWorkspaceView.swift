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
                documentsSection
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
