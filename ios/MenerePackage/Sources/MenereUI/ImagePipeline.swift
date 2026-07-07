import CryptoKit
import Foundation
import ImageIO
import os
import UIKit
import UniformTypeIdentifiers

/// H1 — the single cached image layer for ¡Bacán!.
///
/// One pipeline backs every remote image in the app (``BacanImage``). It has two tiers:
///
/// - **Memory** — an `NSCache` of decoded `UIImage`s, keyed by *fetch key + target size* so a grid
///   thumbnail and a full-res detail of the same photo coexist. Thread-safe and probed
///   *synchronously* (``cachedImage(forKey:)``) so a warm cache renders with **zero flash**.
/// - **Disk** — raw bytes under `Caches/BacanImageCache/`, keyed by a SHA-256 of the fetch key.
///   Survives app launches.
///
/// Keying: **Firebase Storage paths are immutable per image** (`households/{hid}/care/{id}/photo.jpg`
/// is re-written in place, never versioned) → cached **forever** (no TTL, never re-downloaded).
/// **http URLs** get a standard TTL (``httpTTL``) so recipe/label art refreshes eventually.
///
/// Duplicate in-flight requests for the same key are **coalesced** (one backend fetch feeds all
/// awaiters). Decoding + downsampling happen **off the main thread**.
public final class ImagePipeline: Sendable {
    public static let shared = ImagePipeline()

    /// http images re-validate after this long; Storage paths never expire.
    public static let httpTTL: TimeInterval = 7 * 24 * 60 * 60

    private let memory = MemoryImageCache()
    private let coordinator: FetchCoordinator
    private let log = Logger(subsystem: "com.menere.bacan", category: "ImagePipeline")

    public init() {
        let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BacanImageCache", isDirectory: true)
        coordinator = FetchCoordinator(store: DiskStore(directory: dir))
    }

    // MARK: Memory-cache key

    /// Stable memory-cache key folding in the target size (a downsampled variant is a distinct entry).
    public static func memKey(_ key: String, _ size: CGSize?) -> String {
        guard let size, size.width > 0, size.height > 0 else { return key }
        return "\(key)@\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    /// Synchronous warm-cache probe — used by ``BacanImage`` to seed its initial state so a memory
    /// hit paints on the first frame (no placeholder flash, no reload).
    public func cachedImage(forKey memKey: String) -> UIImage? {
        memory.image(forKey: memKey)
    }

    // MARK: Images

    /// A decoded image for a **Firebase Storage path** (cached forever). `loader` is the miss path —
    /// typically `StorageClient.downloadData`. Only invoked on a true cache miss.
    public func image(
        forStoragePath path: String,
        targetSize: CGSize? = nil,
        loader: @escaping @Sendable () async throws -> Data
    ) async throws -> UIImage {
        try await image(key: path, ttl: nil, targetSize: targetSize, loader: loader)
    }

    /// A decoded image for an **http URL** (TTL-cached).
    public func image(forURL url: URL, targetSize: CGSize? = nil) async throws -> UIImage {
        try await image(key: url.absoluteString, ttl: Self.httpTTL, targetSize: targetSize) {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ImagePipelineError.badResponse(http.statusCode)
            }
            return data
        }
    }

    private func image(
        key: String,
        ttl: TimeInterval?,
        targetSize: CGSize?,
        loader: @escaping @Sendable () async throws -> Data
    ) async throws -> UIImage {
        let mk = Self.memKey(key, targetSize)
        if let hit = memory.image(forKey: mk) { return hit }
        let data = try await coordinator.data(key: key, ttl: ttl, loader: loader)
        // Decode + downsample OFF the main thread.
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            Self.decode(data, targetSize: targetSize)
        }.value
        guard let image = decoded else { throw ImagePipelineError.decodeFailed }
        memory.insert(image, forKey: mk, cost: data.count)
        return image
    }

    // MARK: Raw bytes (for reducers that still hold Data in state)

    /// Cached raw bytes for a Storage path — same disk/dedup layer as ``image(forStoragePath:targetSize:loader:)``,
    /// for call sites that keep `Data` in TCA state rather than rendering a ``BacanImage`` directly.
    public func data(
        forStoragePath path: String,
        loader: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        try await coordinator.data(key: path, ttl: nil, loader: loader)
    }

    // MARK: Instrumentation (cache-hit evidence)

    /// Number of times a *real backend fetch* actually ran (disk + memory hits and coalesced
    /// duplicates do NOT count). A second appearance of a cached image must not increment this.
    public func backendFetchCount() async -> Int {
        await coordinator.fetchCount
    }

    // MARK: Decoding

    private static func decode(_ data: Data, targetSize: CGSize?) -> UIImage? {
        guard let targetSize, targetSize.width > 0, targetSize.height > 0 else {
            return UIImage(data: data)
        }
        let scale = UIScreen.main.scale
        let maxPixel = Int(max(targetSize.width, targetSize.height) * scale)
        let srcOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
}

public enum ImagePipelineError: Error {
    case decodeFailed
    case badResponse(Int)
}

// MARK: - Memory tier (thread-safe, synchronous)

/// Thin `NSCache` wrapper. `NSCache` is itself thread-safe, so this needs no lock and can be probed
/// synchronously from any thread (including the main thread, for the zero-flash initial render).
private final class MemoryImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    init() {
        // ~80 MB of decoded pixels in memory before eviction — generous for a family photo app.
        cache.totalCostLimit = 80 * 1024 * 1024
    }

    func image(forKey key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func insert(_ image: UIImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: max(cost, 1))
    }
}

// MARK: - Fetch coordination (disk tier + in-flight dedup)

/// Serializes disk reads/writes and coalesces duplicate in-flight fetches. An `actor` so the
/// `inflight` map and the fetch counter are race-free.
private actor FetchCoordinator {
    private let store: DiskStore
    private var inflight: [String: Task<Data, Error>] = [:]
    private let log = Logger(subsystem: "com.menere.bacan", category: "ImagePipeline")

    /// Count of real backend fetches (misses that hit the loader). Cache-hit evidence.
    private(set) var fetchCount = 0

    init(store: DiskStore) { self.store = store }

    func data(
        key: String,
        ttl: TimeInterval?,
        loader: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        // 1. Disk hit (respecting TTL for http keys; forever for Storage paths).
        if let bytes = store.read(key: key, ttl: ttl) {
            log.debug("cache HIT (disk) \(key, privacy: .public)")
            return bytes
        }
        // 2. Join an in-flight fetch for the same key (dedup).
        if let existing = inflight[key] {
            log.debug("cache HIT (coalesced) \(key, privacy: .public)")
            return try await existing.value
        }
        // 3. True miss — fetch once, persist, share.
        let store = store
        let task = Task<Data, Error> {
            let bytes = try await loader()
            store.write(key: key, data: bytes)
            return bytes
        }
        inflight[key] = task
        fetchCount += 1
        log.debug("cache MISS -> fetch #\(self.fetchCount) \(key, privacy: .public)")
        defer { inflight[key] = nil }
        return try await task.value
    }
}

// MARK: - Disk tier

/// Raw-bytes disk cache under `Caches/`. Keyed by SHA-256 of the fetch key so paths/URLs of any
/// shape map to a safe filename. Storage-path entries never expire; http entries honour a TTL.
private struct DiskStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    func read(key: String, ttl: TimeInterval?) -> Data? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let ttl {
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
            if let modified, Date().timeIntervalSince(modified) > ttl {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        return data
    }

    func write(key: String, data: Data) {
        try? data.write(to: fileURL(for: key), options: .atomic)
    }
}
