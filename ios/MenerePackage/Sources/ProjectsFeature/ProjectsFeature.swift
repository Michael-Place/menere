import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import StorageClient
import SwiftUI
import UserDomain

/// Projects PR1 — the **Projects list** surface, reached from the Lists tab. Shows a card per family
/// initiative (cover, name, phase chip, target date, progress hint) and a **+ New project** flow.
/// Tapping a card pushes the ``ProjectWorkspaceView``.
@Reducer
public struct ProjectsReducer {
    @ObservableState
    public struct State: Equatable {
        var projects: [Project] = []
        var isLoading = false

        // New-project sheet.
        var showNewSheet = false
        var newName = ""
        var newPhase: ProjectPhase = .dreaming
        var hasTargetDate = false
        var newTargetDate = Date()
        var newSummary = ""
        /// A freshly picked cover photo (downscaled JPEG), pending upload on create.
        var newCoverData: Data?
        var isCreating = false

        // Template picker (PR4). A chosen KB template pre-fills the phase, summary, starter tasks, and
        // "don't forget" notes on create. `nil` (or the blank template) = start from scratch.
        var showTemplatePicker = false
        var selectedTemplateId: String?
        /// The resolved template for the current draft, if one is chosen (blank resolves to `nil`).
        var selectedTemplate: ProjectTemplate? { selectedTemplateId.flatMap(ProjectTemplate.named) }

        @Presents var workspace: ProjectWorkspaceReducer.State?

        public init() {}
    }

    public enum Action: BindableAction, Equatable {
        case task
        case projectsLoaded([Project])
        case addTapped
        case newCoverPicked(Data)
        case newCoverCleared
        case chooseTemplateTapped
        case templatePicked(String)
        case clearTemplate
        case createProject
        case projectCreated(Project)
        case projectTapped(Project)
        case deleteProjects(IndexSet)
        case workspace(PresentationAction<ProjectWorkspaceReducer.Action>)
        case binding(BindingAction<State>)
    }

    public init() {}

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                guard let hid = hid() else { return .none }
                state.isLoading = true
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let projects = (try? await persistence.projects(hid)) ?? []
                    await send(.projectsLoaded(projects))
                }

            case let .projectsLoaded(projects):
                state.isLoading = false
                // Newest first — a fresh initiative floats to the top.
                state.projects = projects.sorted { $0.createdAt > $1.createdAt }
                return .none

            case .addTapped:
                state.newName = ""
                state.newPhase = .dreaming
                state.hasTargetDate = false
                state.newTargetDate = Date()
                state.newSummary = ""
                state.newCoverData = nil
                state.selectedTemplateId = nil
                state.showTemplatePicker = false
                state.showNewSheet = true
                return .none

            case let .newCoverPicked(data):
                state.newCoverData = data
                return .none

            case .newCoverCleared:
                state.newCoverData = nil
                return .none

            case .chooseTemplateTapped:
                state.showTemplatePicker = true
                return .none

            case let .templatePicked(id):
                state.showTemplatePicker = false
                guard let template = ProjectTemplate.named(id) else { return .none }
                // Blank/custom clears any prior selection but still applies its (dreaming) phase.
                state.selectedTemplateId = template.isBlank ? nil : id
                state.newPhase = template.phaseSuggestion
                // Pre-fill name + summary only when the family hasn't typed their own.
                if state.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !template.isBlank {
                    state.newName = template.title
                }
                if state.newSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.newSummary = template.summaryHint
                }
                return .none

            case .clearTemplate:
                state.selectedTemplateId = nil
                return .none

            case .createProject:
                let name = state.newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let hid = hid(), !state.isCreating else { return .none }
                state.isCreating = true
                let summary = state.newSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                var base = Project(
                    name: name,
                    status: state.newPhase,
                    targetDate: state.hasTargetDate ? state.newTargetDate : nil,
                    summary: summary.isEmpty ? nil : summary
                )
                // Seed the workspace from the chosen KB template (starter checklist + "don't forget" notes).
                let template = state.selectedTemplate
                if let template, !template.isBlank {
                    base.tasks = template.starterProjectTasks()
                    base.notes = template.starterNotes()
                }
                let coverData = state.newCoverData
                let templateId = template?.isBlank == false ? template?.id : nil
                // Immutable snapshot so the concurrently-executing `.run` closure doesn't capture a `var`.
                let seededBase = base
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    @Dependency(\.storage) var storage
                    @Dependency(\.analytics) var analytics
                    var project = seededBase
                    if let coverData,
                       let path = try? await storage.uploadProjectPhoto(hid, project.id, "cover", coverData) {
                        project.coverImagePath = path
                    }
                    try await persistence.saveProject(hid, project)
                    analytics.log("project_created", ["phase": project.status.rawValue])
                    if let templateId {
                        analytics.log("project_template_used", ["template": templateId])
                    }
                    await send(.projectCreated(project))
                }

            case let .projectCreated(project):
                state.isCreating = false
                state.showNewSheet = false
                state.projects.insert(project, at: 0)
                // Drop straight into the new workspace so the family can start gathering.
                state.workspace = ProjectWorkspaceReducer.State(project: project)
                return .none

            case let .projectTapped(project):
                state.workspace = ProjectWorkspaceReducer.State(project: project)
                return .none

            case let .deleteProjects(offsets):
                guard let hid = hid() else { return .none }
                let toDelete = offsets.map { state.projects[$0] }
                state.projects.remove(atOffsets: offsets)
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    @Dependency(\.storage) var storage
                    for project in toDelete {
                        try? await persistence.deleteProject(hid, project.id)
                        // Best-effort clean of the project's photos.
                        var paths = project.photoPaths ?? []
                        if let cover = project.coverImagePath { paths.append(cover) }
                        try? await storage.deletePaths(paths)
                    }
                }

            // The workspace edited its project — reflect the change back into the list card.
            case let .workspace(.presented(.delegate(.didChange(project)))):
                if let idx = state.projects.firstIndex(where: { $0.id == project.id }) {
                    state.projects[idx] = project
                }
                return .none

            case let .workspace(.presented(.delegate(.didDelete(id)))):
                state.projects.removeAll { $0.id == id }
                state.workspace = nil
                return .none

            case .workspace:
                return .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$workspace, action: \.workspace) {
            ProjectWorkspaceReducer()
        }
    }
}

// MARK: - View

public struct ProjectsView: View {
    @Bindable var store: StoreOf<ProjectsReducer>

    public init(store: StoreOf<ProjectsReducer>) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if store.projects.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                        Button {
                            store.send(.projectTapped(project))
                        } label: {
                            ProjectCard(project: project)
                        }
                        .buttonStyle(.pressable)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.send(.deleteProjects(IndexSet(integer: index)))
                            } label: {
                                Label("Delete project", systemImage: "trash")
                            }
                        }
                        .tabEntrance(.slideLeading, index: index)
                    }
                }
            }
            .padding(16)
        }
        .background(Color.familyCanvas)
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.send(.addTapped) } label: { Image(systemName: "plus").appearBounce() }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("add-project-button")
            }
        }
        .task { store.send(.task) }
        .navigationDestination(
            item: $store.scope(state: \.workspace, action: \.workspace)
        ) { workspaceStore in
            ProjectWorkspaceView(store: workspaceStore)
        }
        .sheet(isPresented: $store.showNewSheet) {
            NewProjectSheet(store: store)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.bacanGreen.opacity(0.12)).frame(width: 88, height: 88)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.bacanGreen)
            }
            Text("No projects yet")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(Color.ink)
            Text("A pool next summer? A new school for Oliver? Start a project to gather photos, quotes, links, and to-dos all in one place. 🏊")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
            Button { store.send(.addTapped) } label: {
                Label("Start a project", systemImage: "plus")
                    .font(.system(.headline, design: .rounded))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.bacanGreen))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.pressable)
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Project card

struct ProjectCard: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover hero (or a soft phase-tinted placeholder).
            ZStack {
                if let cover = project.coverImagePath {
                    BacanImage(path: cover, targetSize: CGSize(width: 800, height: 480))
                } else {
                    LinearGradient(
                        colors: [ProjectPhasePalette.color(project.status).opacity(0.28), Color.familySurface],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: project.status.icon)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(ProjectPhasePalette.color(project.status).opacity(0.6))
                }
            }
            .frame(height: 132)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 8) {
                Text(project.name)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                if let summary = project.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 8) {
                    PhaseChip(phase: project.status)
                    if let target = project.targetDate {
                        chip(icon: "calendar", text: target.formatted(.dateTime.month(.abbreviated).day().year()))
                    }
                    if let summary = project.taskSummary {
                        chip(icon: "checklist", text: summary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
        }
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.familySurface))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(.caption, design: .rounded).weight(.medium))
        }
        .foregroundStyle(Color.inkSoft)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.inkSoft.opacity(0.10)))
    }
}

/// The status chip shown on cards and the workspace header.
struct PhaseChip: View {
    let phase: ProjectPhase

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: phase.icon).font(.system(size: 11, weight: .semibold))
            Text(phase.displayName).font(.system(.caption, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(ProjectPhasePalette.color(phase))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(ProjectPhasePalette.color(phase).opacity(0.16)))
    }
}

/// The phase → color mapping (kept in the view layer; `FamilyDomain` stays UI-free).
enum ProjectPhasePalette {
    static func color(_ phase: ProjectPhase) -> Color {
        switch phase {
        case .dreaming: .sky
        case .researching: .marigold
        case .deciding: .terracotta
        case .inProgress: .bacanGreen
        case .done: .sage
        }
    }
}

// MARK: - New project sheet

private struct NewProjectSheet: View {
    @Bindable var store: StoreOf<ProjectsReducer>

    var body: some View {
        NavigationStack {
            Form {
                // Start from a template — pre-fills phase, summary, starter tasks + "don't forget" notes.
                Section {
                    Button { store.send(.chooseTemplateTapped) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: store.selectedTemplate?.systemImage ?? "wand.and.stars")
                                .foregroundStyle(Color.bacanGreen)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.selectedTemplate?.title ?? "Start from a template")
                                    .font(.system(.body, design: .rounded).weight(.semibold))
                                    .foregroundStyle(Color.ink)
                                Text(store.selectedTemplate.map { _ in "Pre-fills tasks + reminders" }
                                     ?? "Pool, school, trip, reno, and more")
                                    .font(.caption)
                                    .foregroundStyle(Color.inkSoft)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("choose-template-button")
                    if store.selectedTemplate != nil {
                        Button(role: .destructive) { store.send(.clearTemplate) } label: {
                            Label("Clear template", systemImage: "xmark.circle")
                        }
                    }
                }
                .listRowBackground(Color.familySurface)

                Section {
                    TextField("Pool build, Oliver's new school…", text: $store.newName)
                        .accessibilityIdentifier("new-project-name-field")
                }
                .listRowBackground(Color.familySurface)

                Section("Phase") {
                    Picker("Phase", selection: $store.newPhase) {
                        ForEach(ProjectPhase.allCases, id: \.self) { phase in
                            Label(phase.displayName, systemImage: phase.icon).tag(phase)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .listRowBackground(Color.familySurface)

                Section("Details") {
                    Toggle("Set a target date", isOn: $store.hasTargetDate)
                    if store.hasTargetDate {
                        DatePicker("Target", selection: $store.newTargetDate, displayedComponents: .date)
                    }
                    TextField("A one-line summary (optional)", text: $store.newSummary, axis: .vertical)
                        .lineLimit(1...3)
                }
                .listRowBackground(Color.familySurface)

                Section("Cover photo") {
                    PhotoCaptureField(
                        image: store.newCoverData.flatMap(UIImage.init(data:)),
                        fallbackSymbol: "photo.on.rectangle",
                        tint: .bacanGreen,
                        onProcessed: { processed in store.send(.newCoverPicked(processed.jpeg)) }
                    )
                    if store.newCoverData != nil {
                        Button(role: .destructive) { store.send(.newCoverCleared) } label: {
                            Label("Remove cover", systemImage: "trash")
                        }
                    }
                }
                .listRowBackground(Color.familySurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.showNewSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { store.send(.createProject) }
                        .disabled(
                            store.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || store.isCreating
                        )
                        .accessibilityIdentifier("create-project-button")
                }
            }
            .sheet(isPresented: $store.showTemplatePicker) {
                TemplatePickerSheet(
                    selectedId: store.selectedTemplateId,
                    onPick: { store.send(.templatePicked($0)) },
                    onCancel: { store.showTemplatePicker = false }
                )
            }
        }
    }
}

// MARK: - Template picker

/// The Project KB picker (PR4) — a scrollable menu of starter templates (pool, school, trip, reno,
/// party, baby, car, move, landscaping) plus "Start from scratch". Each row previews what it seeds:
/// the suggested phase and a peek at the starter checklist + "things people forget".
private struct TemplatePickerSheet: View {
    let selectedId: String?
    let onPick: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(ProjectTemplate.catalog) { template in
                        Button { onPick(template.id) } label: {
                            TemplateRow(template: template, isSelected: template.id == selectedId)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(16)
            }
            .background(Color.familyCanvas)
            .navigationTitle("Start from a template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

private struct TemplateRow: View {
    let template: ProjectTemplate
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(ProjectPhasePalette.color(template.phaseSuggestion).opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: template.systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ProjectPhasePalette.color(template.phaseSuggestion))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(template.title)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.ink)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.bacanGreen)
                    }
                }
                if template.isBlank {
                    Text("A clean slate — add your own tasks and notes.")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(template.summaryHint)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                        .multilineTextAlignment(.leading)
                    if let first = template.starterTasks.first {
                        Label("\(template.starterTasks.count) starter tasks · \(first)…", systemImage: "checklist")
                            .font(.caption)
                            .foregroundStyle(Color.inkSoft)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.familySurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? Color.bacanGreen : .clear, lineWidth: 2)
        )
    }
}

// MARK: - Previews

#Preview("Projects list") {
    NavigationStack {
        ProjectsView(
            store: Store(
                initialState: {
                    var s = ProjectsReducer.State()
                    s.projects = Project.previewSamples
                    return s
                }()
            ) {
                ProjectsReducer()
            } withDependencies: {
                $0.storage = .previewValue
            }
        )
    }
}

#Preview("Empty") {
    NavigationStack {
        ProjectsView(store: Store(initialState: ProjectsReducer.State()) { ProjectsReducer() })
    }
}

#Preview("Template picker") {
    TemplatePickerSheet(selectedId: "pool", onPick: { _ in }, onCancel: {})
}

extension Project {
    /// Sample projects for SwiftUI previews (no network).
    static var previewSamples: [Project] {
        [
            Project(
                name: "Backyard pool",
                status: .researching,
                targetDate: Calendar.current.date(byAdding: .month, value: 8, to: Date()),
                summary: "Gunite pool + patio. Gathering contractors & quotes.",
                links: [ProjectLink(url: "https://example.com", title: "Blue Haven Pools")],
                tasks: [
                    ProjectTask(title: "Call three builders", isDone: true),
                    ProjectTask(title: "HOA approval", isDone: false),
                    ProjectTask(title: "Compare quotes", isDone: false),
                ]
            ),
            Project(
                name: "Oliver's big-kid school",
                status: .deciding,
                targetDate: Calendar.current.date(byAdding: .month, value: 3, to: Date()),
                summary: "Leaving Kindercare. Touring Montessori + public magnet.",
                tasks: [ProjectTask(title: "Tour open houses", isDone: true)]
            ),
            Project(name: "Someday: treehouse", status: .dreaming),
        ]
    }
}
