import Dependencies
import DependenciesMacros
import FirebaseStorage
import Foundation

/// Firebase Storage access for private per-user media.
///
/// Objects live under `users/{uid}/...` so the owner-only Storage rules apply.
/// Modeled as a `@DependencyClient` so TCA features inject it and tests can swap it.
@DependencyClient
public struct StorageClient: Sendable {
    /// Upload a JPEG tasting photo and return its download URL.
    /// Stored at `users/{uid}/tastings/{tastingId}/{UUID}.jpg`.
    public var uploadTastingPhoto: @Sendable (_ uid: String, _ tastingId: String, _ data: Data) async throws -> URL

    // MARK: Family-Brain documents
    /// Upload one JPEG page of a document and return its **Storage path** (not a download URL —
    /// document pages are member-gated, so readers resolve them through authenticated Storage refs).
    /// Stored at `households/{hid}/documents/{docId}/page-{pageIndex}.jpg`.
    public var uploadDocumentPage: @Sendable (_ hid: String, _ docId: String, _ pageIndex: Int, _ data: Data) async throws -> String
    /// Upload a document stored as a single PDF and return its Storage path.
    /// Stored at `households/{hid}/documents/{docId}/document.pdf`.
    public var uploadDocumentPDF: @Sendable (_ hid: String, _ docId: String, _ data: Data) async throws -> String
    /// Best-effort delete of Storage objects by path (used to clean up document pages on delete or
    /// after a partial-upload failure). Never throws for individual missing objects.
    public var deletePaths: @Sendable (_ paths: [String]) async throws -> Void
}

extension StorageClient: DependencyKey {
    public static let liveValue: StorageClient = {
        StorageClient(
            uploadTastingPhoto: { uid, tastingId, data in
                let ref = Storage.storage().reference()
                    .child("users/\(uid)/tastings/\(tastingId)/\(UUID().uuidString).jpg")
                let metadata = StorageMetadata()
                metadata.contentType = "image/jpeg"
                _ = try await ref.putDataAsync(data, metadata: metadata)
                return try await ref.downloadURL()
            },
            uploadDocumentPage: { hid, docId, pageIndex, data in
                let path = "households/\(hid)/documents/\(docId)/page-\(pageIndex).jpg"
                let ref = Storage.storage().reference().child(path)
                let metadata = StorageMetadata()
                metadata.contentType = "image/jpeg"
                _ = try await ref.putDataAsync(data, metadata: metadata)
                return path
            },
            uploadDocumentPDF: { hid, docId, data in
                let path = "households/\(hid)/documents/\(docId)/document.pdf"
                let ref = Storage.storage().reference().child(path)
                let metadata = StorageMetadata()
                metadata.contentType = "application/pdf"
                _ = try await ref.putDataAsync(data, metadata: metadata)
                return path
            },
            deletePaths: { paths in
                for path in paths where !path.isEmpty {
                    // Best-effort: a missing object (already gone / never uploaded) is not an error.
                    try? await Storage.storage().reference().child(path).delete()
                }
            }
        )
    }()

    public static let previewValue = StorageClient(
        uploadTastingPhoto: { _, _, _ in
            URL(string: "https://example.com/preview.jpg")!
        },
        uploadDocumentPage: { hid, docId, pageIndex, _ in
            "households/\(hid)/documents/\(docId)/page-\(pageIndex).jpg"
        },
        uploadDocumentPDF: { hid, docId, _ in
            "households/\(hid)/documents/\(docId)/document.pdf"
        },
        deletePaths: { _ in }
    )
}

public extension DependencyValues {
    var storage: StorageClient {
        get { self[StorageClient.self] }
        set { self[StorageClient.self] = newValue }
    }
}
