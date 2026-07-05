import Dependencies
import DependenciesMacros
import Foundation
import Photos
import UIKit

/// The result of an add-to-album run: how many assets we saved, the ids we created, and the local
/// identifier of the album they landed in. Everything is plain `Sendable` so it crosses actor
/// hops freely.
public struct CurationResult: Sendable, Equatable {
    /// Number of new `PHAsset`s successfully created + added.
    public var addedCount: Int
    /// Local identifiers of the newly created assets (`PHAsset.localIdentifier`).
    public var assetLocalIdentifiers: [String]
    /// Local identifier of the album the assets were added to (`PHAssetCollection.localIdentifier`).
    public var albumLocalIdentifier: String?
    /// Total number of assets the album holds after the run (re-queried), for a sanity check.
    public var albumAssetCount: Int

    public init(
        addedCount: Int = 0,
        assetLocalIdentifiers: [String] = [],
        albumLocalIdentifier: String? = nil,
        albumAssetCount: Int = 0
    ) {
        self.addedCount = addedCount
        self.assetLocalIdentifiers = assetLocalIdentifiers
        self.albumLocalIdentifier = albumLocalIdentifier
        self.albumAssetCount = albumAssetCount
    }
}

/// First-party Photos curation, Apple-only (PhotoKit / `Photos`). The T0 Apple-TV screensaver
/// spike (see `PhotoCuration-FINDINGS.md`): tvOS has NO third-party screensaver API, so the only
/// path to "our content as the idle screensaver" is Photos. This client CURATES family shots into
/// a **regular** `PHAssetCollection` — which PhotoKit can create + write to freely — that the user
/// then points the Apple TV screensaver at with a one-time step.
///
/// Every endpoint is fire-and-forget-safe: on missing authorization or any PhotoKit failure it
/// returns an empty/neutral result rather than throwing or crashing, so a caller can call it
/// blindly without guarding.
@DependencyClient
public struct PhotoCurationClient: Sendable {
    /// Current Photos authorization for the **add-only** (`.addOnly`) access level — the least
    /// intrusive level that still lets us create albums and add assets.
    public var addOnlyAuthorizationStatus: @Sendable () -> PHAuthorizationStatus = { .notDetermined }

    /// Prompt for **read-write** access (needed to *find* an existing album and re-query its
    /// contents; add-only can create + add but cannot enumerate). Returns the resulting status.
    public var requestAddAccess: @Sendable () async -> PHAuthorizationStatus = { .notDetermined }

    /// Find-or-create a regular (user) album by title and return its `localIdentifier`. Uses
    /// `PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)`. Returns nil
    /// only when unauthorized or the change fails.
    public var ensureAlbum: @Sendable (_ named: String) async -> String?

    /// Save each image `Data` as a new `PHAsset` and add them all to the named album (find-or-
    /// created first). Uses `PHAssetCreationRequest.forAsset()` + `addResource(with:.photo)`
    /// and `PHAssetCollectionChangeRequest.addAssets`. Never throws — returns a `CurationResult`
    /// describing what actually landed (empty on failure).
    public var addImages: @Sendable (_ data: [Data], _ toAlbumNamed: String) async -> CurationResult = { _, _ in CurationResult() }

    /// Re-query how many assets a named album currently holds. Handy for the spike to prove the
    /// writes landed. Returns 0 when the album is missing or unauthorized.
    public var albumAssetCount: @Sendable (_ named: String) async -> Int = { _ in 0 }
}

extension PhotoCurationClient: DependencyKey {
    public static let liveValue = PhotoCurationClient(
        addOnlyAuthorizationStatus: {
            PHPhotoLibrary.authorizationStatus(for: .addOnly)
        },
        requestAddAccess: {
            // Request read-write: add-only is enough to write, but the spike (and any future
            // "verify what we curated" UI) needs to *read* the album back, which add-only forbids.
            await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    cont.resume(returning: status)
                }
            }
        },
        ensureAlbum: { name in
            await PhotoCurationEngine.ensureAlbum(named: name)?.localIdentifier
        },
        addImages: { data, albumName in
            await PhotoCurationEngine.addImages(data, toAlbumNamed: albumName)
        },
        albumAssetCount: { name in
            guard let album = await PhotoCurationEngine.findAlbum(named: name) else { return 0 }
            return PHAsset.fetchAssets(in: album, options: nil).count
        }
    )

    public static let previewValue = PhotoCurationClient(
        addOnlyAuthorizationStatus: { .authorized },
        requestAddAccess: { .authorized },
        ensureAlbum: { _ in "preview-album-id" },
        addImages: { data, _ in
            CurationResult(
                addedCount: data.count,
                assetLocalIdentifiers: data.indices.map { "preview-asset-\($0)" },
                albumLocalIdentifier: "preview-album-id",
                albumAssetCount: data.count
            )
        },
        albumAssetCount: { _ in 2 }
    )
}

// MARK: - Engine

/// The real PhotoKit work, factored out of the client so the endpoints stay one-liners. All calls
/// swallow failures and return neutral values — the T0 spike is explicitly "never crashes".
enum PhotoCurationEngine {
    /// Look up an existing regular album by exact title (read requires read-write access).
    static func findAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options
        )
        return result.firstObject
    }

    /// Find-or-create a regular album. Creating an album is allowed with add-only access; the
    /// find step needs read access, so we try the write path when the lookup comes back empty.
    static func ensureAlbum(named name: String) async -> PHAssetCollection? {
        if let existing = findAlbum(named: name) { return existing }

        var placeholderId: String?
        let ok = await performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholderId = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard ok, let id = placeholderId else {
            // The create may have failed because the album already exists but wasn't visible to a
            // stale fetch — fall back to another lookup.
            return findAlbum(named: name)
        }
        let fetched = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil
        )
        return fetched.firstObject ?? findAlbum(named: name)
    }

    /// Save images as assets and add them to the album, in a single change block so the album
    /// membership is transactional with the asset creation.
    static func addImages(_ data: [Data], toAlbumNamed name: String) async -> CurationResult {
        guard !data.isEmpty else { return CurationResult(albumLocalIdentifier: nil) }
        guard let album = await ensureAlbum(named: name) else { return CurationResult() }

        var placeholderIds: [String] = []
        let ok = await performChanges {
            guard let albumChange = PHAssetCollectionChangeRequest(for: album) else { return }
            for imageData in data {
                let creation = PHAssetCreationRequest.forAsset()
                creation.addResource(with: .photo, data: imageData, options: nil)
                if let placeholder = creation.placeholderForCreatedAsset {
                    placeholderIds.append(placeholder.localIdentifier)
                    albumChange.addAssets([placeholder] as NSArray)
                }
            }
        }

        let count = PHAsset.fetchAssets(in: album, options: nil).count
        guard ok else {
            return CurationResult(albumLocalIdentifier: album.localIdentifier, albumAssetCount: count)
        }
        return CurationResult(
            addedCount: placeholderIds.count,
            assetLocalIdentifiers: placeholderIds,
            albumLocalIdentifier: album.localIdentifier,
            albumAssetCount: count
        )
    }

    /// `PHPhotoLibrary.performChanges` bridged to async, returning success rather than throwing.
    private static func performChanges(_ changes: @escaping () -> Void) async -> Bool {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges(changes) { success, _ in
                cont.resume(returning: success)
            }
        }
    }
}

public extension DependencyValues {
    var photoCuration: PhotoCurationClient {
        get { self[PhotoCurationClient.self] }
        set { self[PhotoCurationClient.self] = newValue }
    }
}
