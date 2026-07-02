import ComposableArchitecture
import FamilyDomain
import Foundation
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
        case detail(PresentationAction<DocumentDetailReducer.Action>)
        case deleteDocuments(IndexSet)
        case dismissAlert
        case binding(BindingAction<State>)
    }

    public init() {}

    @Dependency(\.persistence) var persistence
    @Dependency(\.storage) var storage
    @Dependency(\.docs) var docs
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
                return .run { send in
                    let docs = (try? await persistence.documents(hid)) ?? []
                    await send(.documentsLoaded(docs))
                }

            case let .documentsLoaded(docs):
                state.isLoading = false
                state.documents = docs.sorted { $0.createdAt > $1.createdAt }
                return .none

            case .scanTapped:
                // Camera-backed document scanning is unavailable on the simulator: the code path
                // exists but degrades to a friendly alert rather than crashing.
                if DocumentScanSupport.isAvailable {
                    state.showScanner = true
                } else {
                    state.alertMessage = "The document scanner needs a real camera — it's not available on the simulator. Try “Choose photos” or “Choose file” instead."
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
                guard let hid = hid() else { return .none }
                return .run { send in
                    // Best-effort: on failure the row stays pending/failed (server marks .failed);
                    // the user can retry via "Process again". Re-fetch either way so the row reflects
                    // the server's latest state.
                    try? await docs.process(docId)
                    let updated = (try? await persistence.documents(hid)) ?? []
                    await send(.documentsLoaded(updated))
                }

            case let .documentTapped(doc):
                state.detail = DocumentDetailReducer.State(doc: doc)
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
