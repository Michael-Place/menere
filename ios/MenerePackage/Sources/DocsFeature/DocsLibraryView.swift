import ComposableArchitecture
import FamilyDomain
import MenereUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

public struct DocsLibraryView: View {
    @Bindable var store: StoreOf<DocsReducer>
    @State private var pickerItems: [PhotosPickerItem] = []

    public init(store: StoreOf<DocsReducer>) {
        self.store = store
    }

    public var body: some View {
        List {
            if store.isUploading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Filing “\(store.uploadingTitle)”…")
                            .foregroundStyle(Color.inkSoft)
                    }
                    .accessibilityIdentifier("docs-uploading-row")
                }
                .listRowBackground(Color.familySurface)
            }

            if store.documents.isEmpty && !store.isUploading {
                Section {
                    if store.isLoading {
                        ProgressView()
                    } else {
                        Text("Nothing filed yet. Scan the kitchen-counter pile — receipts, school forms, vet records — and Bacán will keep track.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("docs-empty-state")
                    }
                }
                .listRowBackground(Color.familySurface)
            } else {
                Section {
                    ForEach(store.documents) { doc in
                        DocumentRow(doc: doc)
                    }
                    .onDelete { store.send(.deleteDocuments($0)) }
                }
                .listRowBackground(Color.familySurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Family Brain")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        store.send(.scanTapped)
                    } label: {
                        Label("Scan document", systemImage: "doc.viewfinder")
                    }
                    .accessibilityIdentifier("scan-doc-button")

                    Button {
                        store.send(.choosePhotosTapped)
                    } label: {
                        Label("Choose photos", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("choose-photos-button")

                    Button {
                        store.send(.chooseFileTapped)
                    } label: {
                        Label("Choose file", systemImage: "doc")
                    }
                    .accessibilityIdentifier("choose-file-button")
                } label: {
                    Image(systemName: "plus").appearBounce()
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("docs-add-menu")
            }
        }
        .task { store.send(.task) }
        // Choose photos → up to ~8 pages, converted to Data in onChange.
        .photosPicker(
            isPresented: $store.showPhotosPicker,
            selection: $pickerItems,
            maxSelectionCount: 8,
            matching: .images
        )
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var datas: [Data] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        datas.append(data)
                    }
                }
                pickerItems = []
                if datas.isEmpty {
                    store.send(.importFailed("Couldn't read those photos. Try picking them again."))
                } else {
                    store.send(.photosPicked(datas))
                }
            }
        }
        // Choose file → a single PDF, stored as-is as one "page".
        .fileImporter(
            isPresented: $store.showFileImporter,
            allowedContentTypes: [.pdf]
        ) { result in
            switch result {
            case let .success(url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    store.send(.pdfPicked(data))
                } else {
                    store.send(.importFailed("Couldn't open that PDF. Try again or pick a different file."))
                }
            case .failure:
                store.send(.importFailed("Couldn't open that file. Try again."))
            }
        }
        // Scan document (real devices only) → JPEG pages.
        .fullScreenCover(isPresented: $store.showScanner) {
            DocumentScannerView(
                onComplete: { datas in
                    store.showScanner = false
                    store.send(.photosPicked(datas))
                },
                onCancel: { store.showScanner = false }
            )
            .ignoresSafeArea()
        }
        // Title prompt — the one interaction between intake and upload.
        .alert("Name this document", isPresented: $store.showTitlePrompt) {
            TextField("Title", text: $store.titleDraft)
                .accessibilityIdentifier("doc-title-field")
            Button("Cancel", role: .cancel) { store.send(.cancelIntake) }
            Button("Save") { store.send(.confirmUpload) }
                .accessibilityIdentifier("doc-title-save")
        } message: {
            Text("Bacán will read it and fill in the details in a moment.")
        }
        // Friendly message channel (scanner-unavailable on sim, upload/import failures).
        .alert(
            "Heads up",
            isPresented: Binding(
                get: { store.alertMessage != nil },
                set: { if !$0 { store.send(.dismissAlert) } }
            )
        ) {
            Button("OK", role: .cancel) { store.send(.dismissAlert) }
        } message: {
            Text(store.alertMessage ?? "")
        }
    }
}

/// A single document row: type symbol in a tinted circle, title, "Type · date" line, and a
/// pending-processing hourglass badge.
struct DocumentRow: View {
    let doc: FamilyDomain.Document

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Self.tint(for: doc.type).opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: doc.type.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Self.tint(for: doc.type))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title)
                    .foregroundStyle(Color.ink)
                Text("\(doc.type.displayName) · \(Self.dateText(doc))")
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
            }

            Spacer()

            // ── SEAM (P7-C2): provenance-badged extracted fields (amount / vendor / dates) render
            // here / in a detail screen once `processDocument` fills them, mirroring the wine
            // enrichment provenance badges. ──────────────────────────────────────────────────────
            if doc.processingState == .pending {
                Image(systemName: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Processing")
                    .accessibilityIdentifier("doc-pending-badge")
            }
        }
        .padding(.vertical, 2)
    }

    private static func dateText(_ doc: FamilyDomain.Document) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        return df.string(from: doc.docDate ?? doc.createdAt)
    }

    /// Type-appropriate tint drawn from the family palette.
    static func tint(for type: DocumentType) -> Color {
        switch type {
        case .receipt: .marigold
        case .medical: .terracotta
        case .school: .sky
        case .pet: .bacanGreen
        case .tax: .bacanGreen
        case .manual: .sky
        case .other: .inkSoft
        }
    }
}
