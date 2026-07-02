import ComposableArchitecture
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

        public init(item: CareItem, isEditing: Bool) {
            self.item = item
            self.isEditing = isEditing
        }

        /// The photo to render now: a fresh pick wins over the loaded one.
        var displayPhoto: Data? { pendingPhoto ?? loadedPhoto }
        /// This form is editing a plant — drives plant-flavored copy, option sets, and the photo /
        /// species / notes fields.
        var isPlant: Bool { item.kind == .plant }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case saveTapped
        case deleteTapped
        case addTaskTapped
        case removeTask(id: String)
        case photoPicked(Data)
        case photoLoaded(Data?)
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

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                // Edit mode: fetch the existing photo for display (best-effort).
                guard let path = state.item.photoPath, !path.isEmpty, state.loadedPhoto == nil
                else { return .none }
                return .run { send in
                    @Dependency(\.storage) var storage
                    await send(.photoLoaded(try? await storage.downloadData(path)))
                }

            case let .photoLoaded(data):
                state.loadedPhoto = data
                return .none

            case let .photoPicked(data):
                state.pendingPhoto = data
                return .none

            case .addTaskTapped:
                let interval = CareItem.intervalChoices(for: state.item.kind).first(where: { $0 != nil }) ?? 30
                state.item.tasks.append(CareTask(title: "", intervalDays: interval))
                return .none

            case let .removeTask(id):
                state.item.tasks.removeAll { $0.id == id }
                return .none

            case .saveTapped:
                guard let hid = hid(),
                      !state.item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return .none }
                var item = state.item
                // Trim empty-title tasks and normalize blank optional text to nil.
                item.tasks.removeAll { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                item.location = item.location?.blankToNil
                item.species = item.species?.blankToNil
                item.careNotes = item.careNotes?.blankToNil
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
                Section(store.isPlant ? "Plant" : "Name") {
                    TextField(store.isPlant ? "What's it called?" : "What needs care?", text: $store.item.name)
                        .accessibilityIdentifier("care-name-field")
                }

                if store.isPlant {
                    photoSection
                    speciesSection
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

                if store.isEditing {
                    Section {
                        Button(store.isPlant ? "Delete plant" : "Delete", role: .destructive) {
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
        return store.isEditing ? "Edit care item" : "New care item"
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
            // SEAM (P9-C2 — AI plant identify): an "Identify from photo" button lands here. It runs
            // the scan pipeline (FM/Claude) on `store.displayPhoto` → fills `species`,
            // `speciesLatin`, and a suggested `careNotes`/watering schedule, provenance-badged.
        }
    }

    @ViewBuilder
    private var photoThumbnail: some View {
        Group {
            if let data = store.displayPhoto, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color.bacanGreen.opacity(0.15))
                    Image(systemName: "leaf.fill").font(.title2).foregroundStyle(Color.bacanGreen)
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
        Section("Notes") {
            TextField("Care notes (light, watering quirks…)", text: Binding(
                get: { store.item.careNotes ?? "" },
                set: { store.item.careNotes = $0 }
            ), axis: .vertical)
            .lineLimit(1...4)
            .accessibilityIdentifier("plant-notes-field")
        }
    }
}

/// Wraps `UIImagePickerController` (`.camera`) to photograph a plant. The captured image is encoded
/// to JPEG `Data` and handed to `onCapture` (the reducer compresses/uploads on Save). Mirrors the
/// wine-label capture; a custom `AVCaptureSession` is out of scope.
private struct CarePhotoCamera: UIViewControllerRepresentable {
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
