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
    /// Fetch the raw bytes of a Storage object by path — used to render member-gated document pages
    /// (resolved through an authenticated ref, not a public download URL). Capped at 12 MB/page.
    public var downloadData: @Sendable (_ path: String) async throws -> Data

    // MARK: Care items (P9 — plant photos, kind-agnostic)
    /// Upload a JPEG photo for a ``CareItem`` and return its **Storage path** (member-gated, like
    /// documents). Stored at `households/{hid}/care/{itemId}/photo.jpg` — a single canonical path per
    /// item, so re-uploading replaces the previous photo.
    public var uploadCarePhoto: @Sendable (_ hid: String, _ itemId: String, _ data: Data) async throws -> String

    // MARK: Family journal — memory photos & stickers (P28)
    /// Upload one JPEG photo of a memory (scrapbook page) and return its **Storage path** (member-gated,
    /// like documents/care). Stored at `households/{hid}/memories/{memoryId}/photo-{index}.jpg`, so
    /// re-uploading the same slot replaces it.
    public var uploadMemoryPhoto: @Sendable (_ hid: String, _ memoryId: String, _ index: Int, _ data: Data) async throws -> String
    /// Upload one die-cut **sticker** (transparent PNG) for a memory and return its Storage path.
    /// Stored at `households/{hid}/memories/{memoryId}/sticker-{index}.png`.
    public var uploadMemorySticker: @Sendable (_ hid: String, _ memoryId: String, _ index: Int, _ data: Data) async throws -> String

    // MARK: Projects — initiative workspace photos (Projects PR1)
    /// Upload one JPEG inspiration-board / cover photo for a ``Project`` and return its **Storage
    /// path** (member-gated, like documents/care/memories). Stored at
    /// `households/{hid}/projects/{projectId}/photos/{fileName}.jpg` — the caller supplies a unique
    /// `fileName` (a UUID for board photos, or `cover` for the hero) so paths never collide.
    public var uploadProjectPhoto: @Sendable (_ hid: String, _ projectId: String, _ fileName: String, _ data: Data) async throws -> String
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
            },
            downloadData: { path in
                try await Storage.storage().reference().child(path).data(maxSize: 12 * 1024 * 1024)
            },
            uploadCarePhoto: { hid, itemId, data in
                let path = "households/\(hid)/care/\(itemId)/photo.jpg"
                let ref = Storage.storage().reference().child(path)
                let metadata = StorageMetadata()
                metadata.contentType = "image/jpeg"
                _ = try await ref.putDataAsync(data, metadata: metadata)
                return path
            },
            uploadMemoryPhoto: { hid, memoryId, index, data in
                let path = "households/\(hid)/memories/\(memoryId)/photo-\(index).jpg"
                let ref = Storage.storage().reference().child(path)
                let metadata = StorageMetadata()
                metadata.contentType = "image/jpeg"
                _ = try await ref.putDataAsync(data, metadata: metadata)
                return path
            },
            uploadMemorySticker: { hid, memoryId, index, data in
                let path = "households/\(hid)/memories/\(memoryId)/sticker-\(index).png"
                let ref = Storage.storage().reference().child(path)
                let metadata = StorageMetadata()
                metadata.contentType = "image/png"
                _ = try await ref.putDataAsync(data, metadata: metadata)
                return path
            },
            uploadProjectPhoto: { hid, projectId, fileName, data in
                let path = "households/\(hid)/projects/\(projectId)/photos/\(fileName).jpg"
                let ref = Storage.storage().reference().child(path)
                let metadata = StorageMetadata()
                metadata.contentType = "image/jpeg"
                _ = try await ref.putDataAsync(data, metadata: metadata)
                return path
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
        deletePaths: { _ in },
        downloadData: { _ in Data() },
        uploadCarePhoto: { hid, itemId, _ in
            "households/\(hid)/care/\(itemId)/photo.jpg"
        },
        uploadMemoryPhoto: { hid, memoryId, index, _ in
            "households/\(hid)/memories/\(memoryId)/photo-\(index).jpg"
        },
        uploadMemorySticker: { hid, memoryId, index, _ in
            "households/\(hid)/memories/\(memoryId)/sticker-\(index).png"
        },
        uploadProjectPhoto: { hid, projectId, fileName, _ in
            "households/\(hid)/projects/\(projectId)/photos/\(fileName).jpg"
        }
    )
}

public extension DependencyValues {
    var storage: StorageClient {
        get { self[StorageClient.self] }
        set { self[StorageClient.self] = newValue }
    }
}
