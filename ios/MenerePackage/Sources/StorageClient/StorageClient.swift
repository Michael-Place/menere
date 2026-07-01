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
            }
        )
    }()

    public static let previewValue = StorageClient(
        uploadTastingPhoto: { _, _, _ in
            URL(string: "https://example.com/preview.jpg")!
        }
    )
}

public extension DependencyValues {
    var storage: StorageClient {
        get { self[StorageClient.self] }
        set { self[StorageClient.self] = newValue }
    }
}
