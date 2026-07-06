import Dependencies
import DependenciesMacros
import Foundation
import Photos
import UIKit

// MARK: - Lightweight asset refs (Sendable)

/// Which kind of media an asset holds. Mirrors ``PHAssetMediaType`` but stays a plain, `Sendable`
/// enum so asset refs cross actor hops freely (a raw `PHAsset` is not `Sendable`).
public enum PhotoMediaType: String, Sendable, Equatable, CaseIterable {
    case image
    case video
    case audio
    case unknown

    init(_ phType: PHAssetMediaType) {
        switch phType {
        case .image: self = .image
        case .video: self = .video
        case .audio: self = .audio
        default: self = .unknown
        }
    }
}

/// A lightweight, `Sendable` snapshot of a `PHAsset` — everything the browser + FL2/FL3 need without
/// holding a live PhotoKit object. `id` is the asset's `localIdentifier`; feed it back to
/// ``PhotoLibraryClient/loadThumbnail`` / ``loadFullImage``.
public struct PhotoAsset: Sendable, Equatable, Identifiable {
    public let id: String
    public let creationDate: Date?
    public let isFavorite: Bool
    public let mediaType: PhotoMediaType
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        id: String,
        creationDate: Date?,
        isFavorite: Bool,
        mediaType: PhotoMediaType,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.creationDate = creationDate
        self.isFavorite = isFavorite
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    init(_ asset: PHAsset) {
        self.id = asset.localIdentifier
        self.creationDate = asset.creationDate
        self.isFavorite = asset.isFavorite
        self.mediaType = PhotoMediaType(asset.mediaType)
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
    }
}

/// A `Sendable` snapshot of a photo album / collection, for the browser's "Albums" filter.
public struct PhotoAlbum: Sendable, Equatable, Identifiable {
    /// The collection's `localIdentifier`; feed it into ``PhotoAssetFilter/albumID``.
    public let id: String
    public let title: String
    public let assetCount: Int

    public init(id: String, title: String, assetCount: Int) {
        self.id = id
        self.title = title
        self.assetCount = assetCount
    }
}

/// A declarative query for ``PhotoLibraryClient/fetchAssets`` — compose date range, album, favorites,
/// and media type; everything is optional (a bare filter = "everything, newest first").
public struct PhotoAssetFilter: Sendable, Equatable {
    /// Only assets created within this range (inclusive).
    public var dateRange: ClosedRange<Date>?
    /// Only assets in this album/collection (`PHAssetCollection.localIdentifier`).
    public var albumID: String?
    /// Only favorited assets.
    public var onlyFavorites: Bool
    /// Only this media type (nil = any).
    public var mediaType: PhotoMediaType?
    /// Cap on the number of assets returned (nil = uncapped). The browser passes a page size.
    public var limit: Int?

    public init(
        dateRange: ClosedRange<Date>? = nil,
        albumID: String? = nil,
        onlyFavorites: Bool = false,
        mediaType: PhotoMediaType? = .image,
        limit: Int? = nil
    ) {
        self.dateRange = dateRange
        self.albumID = albumID
        self.onlyFavorites = onlyFavorites
        self.mediaType = mediaType
        self.limit = limit
    }
}

// MARK: - Client

/// The real PhotoKit door for ¡Bacán! (FL1 — "the family lens"). Where ``PhotoCurationClient`` only
/// *writes* an add-only album (for the Apple TV screensaver), this client *reads* the library so the
/// family can browse/search their own photos into a memory:
///
/// - `authorizationStatus()` / `requestAccess()` — read authorization. **`.limited` is a first-class
///   valid state**, not an error: the user picked a subset and we browse just that.
/// - `fetchAssets(filter:)` — lightweight ``PhotoAsset`` refs by date/album/favorite/media type.
/// - `loadThumbnail` / `loadFullImage` — decode via `PHImageManager` (thumbnails downsized for a
///   smooth grid; full image for upload).
/// - `observeLibraryChanges()` — an `AsyncStream` off `PHPhotoLibraryChangeObserver` (FL2's new-photo
///   nudge listens here).
/// - `recentlyAdded(since:)` — assets added since a date (FL2/FL3 curation).
///
/// Every read endpoint is failure-safe: on missing authorization or any PhotoKit hiccup it returns an
/// empty/neutral value rather than throwing, so callers can call blindly and gate on the auth status.
@DependencyClient
public struct PhotoLibraryClient: Sendable {
    /// Current read (`.readWrite`) authorization. `.limited` means the user granted a chosen subset.
    public var authorizationStatus: @Sendable () -> PHAuthorizationStatus = { .notDetermined }

    /// Prompt for read access. Returns the resulting status — treat `.authorized` **and** `.limited`
    /// as "we can browse".
    public var requestAccess: @Sendable () async -> PHAuthorizationStatus = { .notDetermined }

    /// Fetch lightweight asset refs matching `filter`, newest first. Empty when unauthorized.
    public var fetchAssets: @Sendable (_ filter: PhotoAssetFilter) async -> [PhotoAsset] = { _ in [] }

    /// The user's albums (regular + smart favorites), for the browser's album chips. Empty when
    /// unauthorized.
    public var fetchAlbums: @Sendable () async -> [PhotoAlbum] = { [] }

    /// Decode a downsized thumbnail JPEG for `assetID` at (roughly) `targetSize` in points — cheap
    /// enough to scroll a grid. Returns nil when the asset is missing or unauthorized.
    public var loadThumbnail: @Sendable (_ assetID: String, _ targetSize: CGSize) async -> Data?

    /// Decode the full-resolution image JPEG for `assetID` (for upload into a memory). Returns nil on
    /// failure. May fetch from iCloud (network allowed).
    public var loadFullImage: @Sendable (_ assetID: String) async -> Data?

    /// An `AsyncStream` that emits once whenever the photo library changes (new photos, edits,
    /// deletions, or a change to the limited selection). FL2's new-photo nudge listens here. The
    /// underlying `PHPhotoLibraryChangeObserver` is unregistered when the stream is cancelled.
    public var observeLibraryChanges: @Sendable () -> AsyncStream<Void> = { AsyncStream { $0.finish() } }

    /// Assets added to the library since `date`, newest first (FL2/FL3). Empty when unauthorized.
    public var recentlyAdded: @Sendable (_ since: Date) async -> [PhotoAsset] = { _ in [] }

    /// Lightweight refs for a specific set of asset `localIdentifier`s, in the given order (missing ids
    /// dropped). FL4 uses this to resolve a tagged person's stored asset ids back into browsable assets.
    public var assetsByIDs: @Sendable (_ ids: [String]) async -> [PhotoAsset] = { _ in [] }

    /// FL4 — the on-device face-grouping pass. Over a BOUNDED candidate set (favorites + recents, capped
    /// at `limit`), detects faces (`VNDetectFaceRectanglesRequest`), feature-prints each face crop
    /// (`VNGenerateImageFeaturePrint`), and greedily clusters the prints by distance into
    /// ``FaceCluster``s (largest first). Entirely on-device, cancellable, and off the main actor.
    /// **Approximate by design** — a generic image feature print is not a purpose-built face embedding.
    /// Empty when unauthorized or when no faces are found.
    public var scanFaces: @Sendable (_ limit: Int) async -> [FaceCluster] = { _ in [] }
}

// MARK: - Live

extension PhotoLibraryClient: DependencyKey {
    public static let liveValue = PhotoLibraryClient(
        authorizationStatus: {
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        },
        requestAccess: {
            await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    cont.resume(returning: status)
                }
            }
        },
        fetchAssets: { filter in
            PhotoLibraryEngine.fetchAssets(filter)
        },
        fetchAlbums: {
            PhotoLibraryEngine.fetchAlbums()
        },
        loadThumbnail: { id, size in
            await PhotoLibraryEngine.loadImage(id: id, targetSize: size, thumbnail: true)
        },
        loadFullImage: { id in
            await PhotoLibraryEngine.loadImage(id: id, targetSize: nil, thumbnail: false)
        },
        observeLibraryChanges: {
            PhotoLibraryEngine.changeStream()
        },
        recentlyAdded: { since in
            let range = since...Date.distantFuture
            return PhotoLibraryEngine.fetchAssets(PhotoAssetFilter(dateRange: range, mediaType: nil))
        },
        assetsByIDs: { ids in
            PhotoLibraryEngine.assetsByIDs(ids)
        },
        scanFaces: { limit in
            await FaceScanEngine.scan(limit: limit)
        }
    )

    public static let previewValue = PhotoLibraryClient(
        authorizationStatus: { .authorized },
        requestAccess: { .authorized },
        fetchAssets: { _ in [] },
        fetchAlbums: { [] },
        loadThumbnail: { _, _ in nil },
        loadFullImage: { _ in nil },
        observeLibraryChanges: { AsyncStream { $0.finish() } },
        recentlyAdded: { _ in [] },
        assetsByIDs: { _ in [] },
        scanFaces: { _ in [] }
    )

    /// The unimplemented `testValue` comes from `@DependencyClient`'s defaults (each closure above has
    /// a neutral default), so tests get a safe, no-op client unless they override endpoints.
}

public extension DependencyValues {
    var photoLibrary: PhotoLibraryClient {
        get { self[PhotoLibraryClient.self] }
        set { self[PhotoLibraryClient.self] = newValue }
    }
}

// MARK: - Engine

/// The real PhotoKit work, factored out so the client endpoints stay thin. Mirrors the failure-safe
/// posture of ``PhotoCurationEngine``: neutral values instead of throws.
enum PhotoLibraryEngine {
    static func fetchAssets(_ filter: PhotoAssetFilter) -> [PhotoAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        var predicates: [NSPredicate] = []
        if let range = filter.dateRange {
            predicates.append(NSPredicate(
                format: "creationDate >= %@ AND creationDate <= %@",
                range.lowerBound as NSDate, range.upperBound as NSDate
            ))
        }
        if filter.onlyFavorites {
            predicates.append(NSPredicate(format: "favorite == YES"))
        }
        if let media = filter.mediaType {
            predicates.append(NSPredicate(format: "mediaType == %d", mediaTypeRaw(media)))
        }
        if !predicates.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
        if let limit = filter.limit {
            options.fetchLimit = limit
        }

        let result: PHFetchResult<PHAsset>
        if let albumID = filter.albumID,
           let collection = PHAssetCollection.fetchAssetCollections(
               withLocalIdentifiers: [albumID], options: nil
           ).firstObject {
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }

        var assets: [PhotoAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(PhotoAsset(asset)) }
        return assets
    }

    /// Resolve specific `localIdentifier`s to lightweight refs, preserving the requested order and
    /// dropping any that no longer exist. FL4's "Photos of {name}" replays a person's stored asset ids.
    static func assetsByIDs(_ ids: [String]) -> [PhotoAsset] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var byID: [String: PhotoAsset] = [:]
        result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = PhotoAsset(asset) }
        return ids.compactMap { byID[$0] }
    }

    static func fetchAlbums() -> [PhotoAlbum] {
        var albums: [PhotoAlbum] = []

        func collect(_ result: PHFetchResult<PHAssetCollection>) {
            result.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: nil).count
                guard count > 0 else { return }
                albums.append(PhotoAlbum(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Untitled",
                    assetCount: count
                ))
            }
        }

        // User-created regular albums.
        collect(PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil
        ))
        // Handy smart albums (recents / screenshots / selfies etc.) that the family actually browses.
        for subtype in [
            PHAssetCollectionSubtype.smartAlbumUserLibrary,
            .smartAlbumScreenshots,
            .smartAlbumSelfPortraits,
            .smartAlbumPanoramas,
        ] {
            collect(PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: subtype, options: nil
            ))
        }
        return albums
    }

    static func loadImage(id: String, targetSize: CGSize?, thumbnail: Bool) async -> Data? {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [id], options: nil
        ).firstObject else { return nil }

        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        // Fast-then-sharp for thumbnails; a single high-quality pass for the full image so we don't
        // resume the continuation twice.
        options.deliveryMode = thumbnail ? .highQualityFormat : .highQualityFormat
        options.resizeMode = thumbnail ? .fast : .none

        let size = targetSize.map { CGSize(width: $0.width * 2, height: $0.height * 2) }
            ?? PHImageManagerMaximumSize

        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            var resumed = false
            manager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: thumbnail ? .aspectFill : .aspectFit,
                options: options
            ) { image, info in
                // With .highQualityFormat + async, PhotoKit may still deliver a degraded frame first;
                // ignore it and wait for the final image so we resume exactly once.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                guard !resumed else { return }
                resumed = true
                let quality: CGFloat = thumbnail ? 0.8 : 0.9
                cont.resume(returning: image?.jpegData(compressionQuality: quality))
            }
        }
    }

    static func changeStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = LibraryChangeObserver { continuation.yield(()) }
            PHPhotoLibrary.shared().register(observer)
            continuation.onTermination = { _ in
                PHPhotoLibrary.shared().unregisterChangeObserver(observer)
            }
        }
    }

    private static func mediaTypeRaw(_ type: PhotoMediaType) -> Int {
        switch type {
        case .image: return PHAssetMediaType.image.rawValue
        case .video: return PHAssetMediaType.video.rawValue
        case .audio: return PHAssetMediaType.audio.rawValue
        case .unknown: return PHAssetMediaType.unknown.rawValue
        }
    }
}

/// Bridges `PHPhotoLibraryChangeObserver` (an `NSObject` delegate) to a closure the ``AsyncStream``
/// yields from. Held alive by the stream's continuation closure until termination.
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
}
