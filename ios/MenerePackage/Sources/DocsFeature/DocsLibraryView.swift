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
                        Button {
                            store.send(.documentTapped(doc))
                        } label: {
                            DocumentRow(doc: doc) {
                                store.send(.processDocument(doc.id))
                            }
                        }
                        .buttonStyle(.plain)
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
        .navigationDestination(
            item: $store.scope(state: \.detail, action: \.detail)
        ) { detailStore in
            DocumentDetailView(store: detailStore)
        }
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

/// A single document row. Pending: type symbol + title + hourglass. Processed (P7-C2): the row
/// upgrades to type name, vendor + amount, a 2-line summary, and tiny tag chips. Failed: a subtle
/// warning + "Tap to retry" wired to the same re-process action (also available via long-press).
struct DocumentRow: View {
    let doc: FamilyDomain.Document
    /// Re-invoke `processDocument` for this row (post-upload retry / manual re-run).
    let onReprocess: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Self.tint(for: doc.type).opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: doc.type.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Self.tint(for: doc.type))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .foregroundStyle(Color.ink)

                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)

                if doc.processingState == .processed, let summary = doc.summary,
                   !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("doc-summary")
                }

                if doc.processingState == .processed, !doc.tags.isEmpty {
                    tagChips
                }

                if let expiry = doc.expiryDate {
                    DocumentDateChip(date: expiry, kind: .expiry)
                } else if let due = doc.dueDate {
                    DocumentDateChip(date: due, kind: .due)
                }

                if doc.processingState == .failed {
                    Label("Needs another pass", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("doc-failed-badge")
                }
            }

            Spacer(minLength: 0)

            if doc.processingState == .pending {
                Image(systemName: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Processing")
                    .accessibilityIdentifier("doc-pending-badge")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            if doc.processingState != .processed {
                Button {
                    onReprocess()
                } label: {
                    Label("Process again", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("doc-reprocess-button")
            }
        }
    }

    /// The secondary line. Processed docs lead with vendor + amount when present; otherwise (pending,
    /// failed, or sparse) fall back to the C1 "Type · date" line.
    private var metaLine: String {
        if doc.processingState == .processed {
            var parts: [String] = []
            if let vendor = doc.vendor?.trimmingCharacters(in: .whitespacesAndNewlines), !vendor.isEmpty {
                parts.append(vendor)
            }
            if let amount = doc.amount {
                parts.append(Self.amountText(amount))
            }
            if !parts.isEmpty {
                return "\(doc.type.displayName) · " + parts.joined(separator: " · ")
            }
        }
        return "\(doc.type.displayName) · \(Self.dateText(doc))"
    }

    /// Up to 3 tag chips, then a "+N" overflow chip.
    private var tagChips: some View {
        let shown = Array(doc.tags.prefix(3))
        let overflow = doc.tags.count - shown.count
        return HStack(spacing: 4) {
            ForEach(shown, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Self.tint(for: doc.type).opacity(0.15), in: Capsule())
                    .foregroundStyle(Self.tint(for: doc.type))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.caption2)
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .accessibilityIdentifier("doc-tags")
    }

    private static func amountText(_ amount: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = "USD"
        return fmt.string(from: NSNumber(value: amount)) ?? String(format: "$%.2f", amount)
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
