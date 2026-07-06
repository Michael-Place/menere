import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import Foundation
import LocalCache
import PersistenceClient
import StorageClient
import SwiftUI
import UserDomain

/// The Family-Brain document vault (P7-C1: intake + library, **no AI yet**).
///
/// Handles three intake paths — VisionKit scan, PhotosPicker, and a PDF file import — that all
/// converge on a title prompt, then a JPEG-compress + Storage upload + Firestore create, leaving the
/// document `.pending` for C2's `processDocument` to enrich.
@Reducer
public struct DocsReducer {
    @ObservableState
    public struct State: Equatable {
        var documents: [FamilyDomain.Document] = []
        var isLoading = false
        // H2-ext — true once the Firestore listener has delivered the authoritative (full) set this
        // session. Until then the SQLite mirror drives the instant first-page paint; after, the cache
        // stream is ignored so it can't truncate the full set the listener holds for search/Collections.
        var didLoadFromFirestore = false

        // H3 — display-window pagination for the flat "All" list. The live listener still streams the
        // *full* set (Collections clustering, cross-tab search consistency, and the pending→processed
        // write-back all need every doc), so this bounds only how many rows the List builds/diffs at
        // once: render `visibleCount`, grow by `pageSize` each time the load-more sentinel scrolls in.
        static let pageSize = 20
        var visibleCount = DocsReducer.State.pageSize

        /// The current page of the flat list — a newest-first prefix of the full set.
        var visibleDocuments: [FamilyDomain.Document] {
            documents.count <= visibleCount ? documents : Array(documents.prefix(visibleCount))
        }

        /// True while the flat list still has rows to reveal (drives the load-more sentinel). Only the
        /// flat "All" view paginates — the Collections lens and a drilled-in cluster show in full.
        var canLoadMore: Bool {
            !showCollections && openedCollection == nil && visibleCount < documents.count
        }

        // P24 — Collections lens. `showCollections` flips the flat list to a clustered view;
        // `openedCollection` (when set) drills into one cluster's filtered document list.
        var showCollections = false
        var openedCollection: EntityGraph.Collection?

        /// The vendor / project clusters computed from the whole Brain (≥2 docs each).
        var collections: [EntityGraph.Collection] {
            EntityGraph.collections(documents: documents)
        }

        /// The documents inside the currently-opened collection, in the collection's order.
        var openedCollectionDocuments: [FamilyDomain.Document] {
            guard let collection = openedCollection else { return [] }
            let byId = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return collection.documentIds.compactMap { byId[$0] }
        }

        // Intake staging: raw picked/scanned image bytes (compressed at upload time) OR a PDF blob.
        var pendingPages: [Data] = []
        var pendingPDF: Data?
        var pendingIsPDF = false
        var titleDraft = ""

        // Presentation flags (view-driven pickers).
        var showTitlePrompt = false
        var showPhotosPicker = false
        var showFileImporter = false
        var showScanner = false

        // Pushed document detail (C3).
        @Presents var detail: DocumentDetailReducer.State?

        // A single message-alert channel (scanner-unavailable on sim, upload failures, import errors).
        var alertMessage: String?

        // Upload progress: a lightweight overlay row while a document is being filed.
        var isUploading = false
        var uploadingTitle = ""

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case task
        case documentsLoaded([FamilyDomain.Document])
        case documentsCacheHydrated([FamilyDomain.Document])   // H2-ext — instant paint from SQLite
        case loadMore                      // H3 — reveal the next page of the flat list
        // Intake entry points
        case scanTapped
        case choosePhotosTapped
        case chooseFileTapped
        case photosPicked([Data])       // from PhotosPicker or the VisionKit scanner
        case pdfPicked(Data)
        case importFailed(String)
        // Title prompt → upload
        case confirmUpload
        case cancelIntake
        case uploadSucceeded(FamilyDomain.Document)
        case uploadFailed(String)
        // AI processing (P7-C2)
        case processDocument(String)      // docId — trigger/retry AI enrichment (also the retry action)
        // Library
        case documentTapped(FamilyDomain.Document)
        // Collections lens (P24)
        case collectionOpened(EntityGraph.Collection)
        case collectionClosed
        case detail(PresentationAction<DocumentDetailReducer.Action>)
        case deleteDocuments(IndexSet)
        case dismissAlert
        case binding(BindingAction<State>)
    }

    public init() {}

    private enum CancelID { case observeDocuments, observeDocsCache }

    @Dependency(\.persistence) var persistence
    @Dependency(\.storage) var storage
    @Dependency(\.docs) var docs
    @Dependency(\.analytics) var analytics
    @Dependency(\.localCache) var localCache
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

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
                state.isLoading = true
                // H2-ext — OFFLINE-FIRST INSTANT PAINT: read the SQLite mirror synchronously and seed the
                // first page THIS FRAME (no await, no network). On a warm cache the Brain paints instantly;
                // the live Firestore listener below refreshes behind it and becomes source-of-truth (it
                // holds the FULL set that search / Collections / pagination need). Guarded so a
                // re-navigation with fresh in-memory docs isn't clobbered by the cache.
                localCache.bootstrap()
                if state.documents.isEmpty {
                    let cached = localCache.documents(hid, State.pageSize)
                    if !cached.isEmpty { state.documents = cached.sorted { $0.createdAt > $1.createdAt } }
                }
                return .merge(
                    // H2-ext — keep the fast-paint list live from SQLite until Firestore lands: emits the
                    // current first-page snapshot immediately, then after each write-through.
                    .run { send in
                        for await docs in localCache.observeDocuments(hid, State.pageSize) {
                            await send(.documentsCacheHydrated(docs))
                        }
                    }
                    .cancellable(id: CancelID.observeDocsCache, cancelInFlight: true),
                    // Live library: a Firestore snapshot listener (mirrors ChoresFeature's stats stream).
                    // Every snapshot — uploads, deletes, and the async `processDocument` write-back —
                    // pushes straight into `state.documents` with no navigation required.
                    .run { send in
                        for try await docs in persistence.observeDocuments(hid) {
                            await send(.documentsLoaded(docs))
                        }
                    } catch: { _, _ in
                        // Listener error (e.g. sign-out): stop quietly; re-entry restarts the stream.
                    }
                    .cancellable(id: CancelID.observeDocuments, cancelInFlight: true)
                )

            case let .documentsCacheHydrated(docs):
                // H2-ext — instant paint from the SQLite mirror. Only claims the list until the Firestore
                // listener has delivered this session; afterward the cache's limited (first-page) stream
                // must not truncate the full set the listener holds for search / Collections / pagination.
                guard !state.didLoadFromFirestore else { return .none }
                state.documents = docs.sorted { $0.createdAt > $1.createdAt }
                return .none

            case let .documentsLoaded(docs):
                state.isLoading = false
                state.didLoadFromFirestore = true
                state.documents = docs.sorted { $0.createdAt > $1.createdAt }
                // H2-ext — write the authoritative full set through to the mirror (upsert present, delete
                // missing) so next cold-nav paints instantly and deletions propagate. The Firestore
                // listener never emits while offline, so there's no "nil payload" to guard: no emit = no
                // write-through = the cache is left intact offline.
                let writeThrough: Effect<Action> = hid().map { hid in
                    .run { [docs] _ in localCache.upsertDocuments(hid, docs) }
                } ?? .none
                // Keep a presented detail fresh off the same stream: a pending→processed flip fills
                // its fields live; a doc deleted elsewhere dismisses the detail gracefully.
                if let detailID = state.detail?.doc.id {
                    if let fresh = state.documents.first(where: { $0.id == detailID }) {
                        state.detail?.applyUpdate(fresh)
                    } else {
                        state.detail = nil
                    }
                }
                return writeThrough

            case .loadMore:
                // Grow the display window by one page. Guarded by `canLoadMore` at the call site, so
                // this only fires while more rows remain; capped implicitly by `visibleDocuments`.
                state.visibleCount += State.pageSize
                return .none

            case .scanTapped:
                // Camera-backed document scanning is unavailable on the simulator (and on any device
                // with no usable camera). Rather than dead-ending on an alert, degrade GRACEFULLY to
                // the photo-library import — the exact same route to the Brain (`.photosPicked` →
                // title prompt → upload → `processDocument`), just sourcing pages from the library
                // instead of the live VisionKit scanner. On real hardware this branch never runs.
                if DocumentScanSupport.isAvailable {
                    state.showScanner = true
                } else {
                    state.showPhotosPicker = true
                }
                return .none

            case .choosePhotosTapped:
                state.showPhotosPicker = true
                return .none

            case .chooseFileTapped:
                state.showFileImporter = true
                return .none

            case let .photosPicked(datas):
                guard !datas.isEmpty else { return .none }
                state.pendingPages = datas
                state.pendingPDF = nil
                state.pendingIsPDF = false
                state.titleDraft = Self.defaultTitle(now: date.now)
                state.showTitlePrompt = true
                return .none

            case let .pdfPicked(data):
                state.pendingPages = []
                state.pendingPDF = data
                state.pendingIsPDF = true
                state.titleDraft = Self.defaultTitle(now: date.now)
                state.showTitlePrompt = true
                return .none

            case let .importFailed(message):
                state.alertMessage = message
                return .none

            case .confirmUpload:
                guard let hid = hid(), let uid = uid() else {
                    state.showTitlePrompt = false
                    state.alertMessage = "You'll need to be signed in to a family to file documents."
                    return .none
                }
                let trimmed = state.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = trimmed.isEmpty ? Self.defaultTitle(now: date.now) : trimmed
                let docId = uuid().uuidString
                let now = date.now
                let pages = state.pendingPages
                let pdf = state.pendingPDF
                let isPDF = state.pendingIsPDF

                state.showTitlePrompt = false
                state.isUploading = true
                state.uploadingTitle = title
                state.pendingPages = []
                state.pendingPDF = nil
                state.pendingIsPDF = false

                return .run { send in
                    var uploaded: [String] = []
                    do {
                        if isPDF, let pdf {
                            let path = try await storage.uploadDocumentPDF(hid, docId, pdf)
                            uploaded.append(path)
                        } else {
                            for (index, raw) in pages.enumerated() {
                                let jpeg = DocumentImageProcessing.compressedJPEG(from: raw) ?? raw
                                let path = try await storage.uploadDocumentPage(hid, docId, index, jpeg)
                                uploaded.append(path)
                            }
                        }
                        let doc = FamilyDomain.Document(
                            id: docId,
                            title: title,
                            type: .other,
                            pagePaths: uploaded,
                            uploadedBy: uid,
                            createdAt: now,
                            processingState: .pending
                        )
                        try await persistence.saveDocument(hid, doc)
                        await send(.uploadSucceeded(doc))
                        // ── SEAM (P7-C2): trigger AI processing, post-upload. The callable reads the
                        // uploaded pages, runs Claude vision, and writes back type/tags/summary/
                        // amount/dates/extractedText + flips `processingState` to .processed/.failed.
                        // Fire-and-forget resilience: if it fails, the row simply stays pending and
                        // the "Process again" row action re-invokes it.
                        await send(.processDocument(docId))
                    } catch {
                        // Best-effort cleanup of any partially-uploaded pages.
                        if !uploaded.isEmpty { try? await storage.deletePaths(uploaded) }
                        await send(.uploadFailed(error.localizedDescription))
                    }
                }

            case .cancelIntake:
                state.showTitlePrompt = false
                state.pendingPages = []
                state.pendingPDF = nil
                state.pendingIsPDF = false
                return .none

            case let .uploadSucceeded(doc):
                state.isUploading = false
                state.uploadingTitle = ""
                state.documents.insert(doc, at: 0)
                return .none

            case .uploadFailed:
                state.isUploading = false
                state.uploadingTitle = ""
                state.alertMessage = "That one didn't make it into the vault — the upload failed. Give it another try in a moment."
                return .none

            case let .processDocument(docId):
                return .run { _ in
                    // Best-effort trigger/retry: on failure the row stays pending/failed (server
                    // marks .failed) and "Process again" re-invokes this. No re-fetch — the live
                    // documents listener delivers the server's write-back on its own.
                    try? await docs.process(docId)
                }

            case let .documentTapped(doc):
                state.detail = DocumentDetailReducer.State(doc: doc)
                return .none

            case let .collectionOpened(collection):
                analytics.log("brain_collection_opened", ["kind": collection.kind.rawValue])
                state.openedCollection = collection
                return .none

            case .collectionClosed:
                state.openedCollection = nil
                return .none

            // Keep the library in sync with edits/deletes made from the pushed detail.
            case let .detail(.presented(.delegate(.didChange(doc)))):
                if let idx = state.documents.firstIndex(where: { $0.id == doc.id }) {
                    state.documents[idx] = doc
                }
                return .none

            case let .detail(.presented(.delegate(.didDelete(id)))):
                state.documents.removeAll { $0.id == id }
                return .none

            case .detail:
                return .none

            case let .deleteDocuments(offsets):
                guard let hid = hid() else { return .none }
                let toDelete = offsets.map { state.documents[$0] }
                state.documents.remove(atOffsets: offsets)
                return .run { _ in
                    for doc in toDelete {
                        // Delete Storage pages best-effort, then the Firestore doc.
                        try? await storage.deletePaths(doc.pagePaths)
                        try? await persistence.deleteDocument(hid, doc.id)
                    }
                }

            case .dismissAlert:
                state.alertMessage = nil
                return .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$detail, action: \.detail) {
            DocumentDetailReducer()
        }
    }

    /// Default intake title, e.g. "Scanned Jul 2".
    static func defaultTitle(now: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return "Scanned \(df.string(from: now))"
    }
}
