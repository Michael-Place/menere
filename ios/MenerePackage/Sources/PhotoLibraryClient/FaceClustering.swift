import CoreGraphics
import CoreML
import Foundation
import Photos
import UIKit
import Vision

// MARK: - FL4 — on-device face grouping ("Photos of {kid}")
//
// Apple does NOT expose its Photos "People" face NAMES to third-party apps, so ¡Bacán! groups faces
// ITSELF, entirely on-device, and lets the family tag a group once (→ ``FaceTagStore``). This is a
// deliberately MODEST first cut:
//
//   1. Bound the work — only favorites + recents, capped at `limit` (default ~200). We never sweep an
//      18k-photo library.
//   2. Detect faces with `VNDetectFaceRectanglesRequest`.
//   3. Crop each face (padded to include the whole head) and feature-print the crop with
//      `VNGenerateImageFeaturePrintRequest`.
//   4. Greedily cluster the feature prints by distance (single-rep threshold) into ``FaceCluster``s.
//
// **Honesty:** a generic image feature print is not a purpose-built face embedding, so grouping is
// approximate — good enough to say "these look like the same kid, tag them," not biometric identity.
// A bundled CoreML face-embedding model (e.g. a FaceNet/ArcFace-style network) would be the real fix.

/// A discovered group of faces that look like the same person, from an on-device ``PhotoLibraryClient/scanFaces``
/// pass. `assetIDs` are the (deduped) photos this face appears in; `sampleFaceThumbnail` is a cropped
/// JPEG of one representative face for the tagging UI.
public struct FaceCluster: Sendable, Equatable, Identifiable {
    /// Stable within a single scan (derived from the representative face) — good for SwiftUI identity.
    public let id: String
    /// The unique asset `localIdentifier`s this face appears in, most-confident first.
    public let assetIDs: [String]
    /// The asset the sample face was cropped from.
    public let sampleAssetID: String
    /// A small cropped-face JPEG for the tag-a-face UI (nil only if the crop couldn't be encoded).
    public let sampleFaceThumbnail: Data?
    /// How many faces landed in this cluster (≥ `assetIDs.count` when one photo held several).
    public let faceCount: Int

    public init(
        id: String,
        assetIDs: [String],
        sampleAssetID: String,
        sampleFaceThumbnail: Data?,
        faceCount: Int
    ) {
        self.id = id
        self.assetIDs = assetIDs
        self.sampleAssetID = sampleAssetID
        self.sampleFaceThumbnail = sampleFaceThumbnail
        self.faceCount = faceCount
    }
}

// MARK: - Engine

/// The real Vision work behind ``PhotoLibraryClient/scanFaces``. Kept off the client so the endpoint
/// stays thin; failure-safe (neutral values, never throws) to match the rest of the engine.
enum FaceScanEngine {
    /// One detected face: which asset it came from, its feature print, and a display crop.
    private struct DetectedFace {
        let assetID: String
        let print: VNFeaturePrintObservation
        let thumbnail: Data?
    }

    /// Feature-print distance below which two faces are treated as the same person. Calibrated against
    /// `VNGenerateImageFeaturePrintRequest` on padded face crops: same-subject pairs land ≈0.25–0.73,
    /// different subjects ≈0.84+. 0.75 is the single biggest lever on grouping quality — tune here.
    static let clusterThreshold: Float = 0.75

    /// Cap on how many discovered clusters we surface (largest first) — keeps the tag-a-face grid sane.
    static let maxClusters = 24

    static func scan(limit: Int) async -> [FaceCluster] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) != .denied else { return [] }

        // 1. Bounded candidate set: favorites first (usually the "keepers" with people), then recents,
        //    deduped and capped. We deliberately do NOT scan the whole library.
        let half = max(1, limit)
        let favorites = PhotoLibraryEngine.fetchAssets(
            PhotoAssetFilter(onlyFavorites: true, mediaType: .image, limit: half)
        )
        let recents = PhotoLibraryEngine.fetchAssets(
            PhotoAssetFilter(mediaType: .image, limit: limit)
        )
        var seen = Set<String>()
        var candidates: [PhotoAsset] = []
        for asset in favorites + recents where seen.insert(asset.id).inserted {
            candidates.append(asset)
            if candidates.count >= limit { break }
        }

        // 2 + 3. Detect faces → crop → feature-print. Cancellable between assets (TCA cancels the Effect).
        var faces: [DetectedFace] = []
        for asset in candidates {
            if Task.isCancelled { break }
            guard let cg = await loadCGImage(id: asset.id) else { continue }
            for observation in detectFaces(cg) {
                guard let crop = cropFace(cg, boundingBox: observation.boundingBox),
                      let print = featurePrint(crop) else { continue }
                faces.append(DetectedFace(assetID: asset.id, print: print, thumbnail: faceThumbnail(crop)))
            }
        }

        // 4. Greedy single-representative clustering.
        return cluster(faces)
    }

    // MARK: Clustering

    private static func cluster(_ faces: [DetectedFace]) -> [FaceCluster] {
        var groups: [[DetectedFace]] = []
        var reps: [VNFeaturePrintObservation] = []

        for face in faces {
            var bestIdx = -1
            var bestDist = Float.greatestFiniteMagnitude
            for (i, rep) in reps.enumerated() {
                var dist = Float.greatestFiniteMagnitude
                do { try rep.computeDistance(&dist, to: face.print) } catch { continue }
                if dist < bestDist { bestDist = dist; bestIdx = i }
            }
            if bestIdx >= 0, bestDist < clusterThreshold {
                groups[bestIdx].append(face)
            } else {
                groups.append([face])
                reps.append(face.print)
            }
        }

        // Largest groups first (most-photographed people), capped. Singletons are kept only after
        // multi-face clusters so the grid leads with confident groups.
        let ordered = groups.sorted { $0.count > $1.count }
        return ordered.prefix(maxClusters).map { group -> FaceCluster in
            var order: [String] = []
            var s = Set<String>()
            for f in group where s.insert(f.assetID).inserted { order.append(f.assetID) }
            let sample = group.first
            return FaceCluster(
                id: "cluster-\(sample?.assetID ?? UUID().uuidString)-\(order.count)-\(group.count)",
                assetIDs: order,
                sampleAssetID: sample?.assetID ?? "",
                sampleFaceThumbnail: sample?.thumbnail,
                faceCount: group.count
            )
        }
    }

    // MARK: Vision helpers

    private static func detectFaces(_ cg: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        forceCPU(request)
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        return request.results ?? []
    }

    private static func featurePrint(_ cg: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        forceCPU(request)
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    /// The iOS Simulator has no Apple Neural Engine, so Vision's default compute path fails to "create
    /// an inference context." Pin these requests to the CPU so face grouping works in the sim; on a real
    /// device Vision still picks the best (ANE) path when a supported compute device is set.
    private static func forceCPU(_ request: VNImageBasedRequest) {
        #if targetEnvironment(simulator)
        if #available(iOS 17.0, *) {
            let cpu = MLComputeDevice.allComputeDevices.first { if case .cpu = $0 { return true }; return false }
            if let cpu {
                request.setComputeDevice(cpu, for: .main)
                return
            }
        }
        request.usesCPUOnly = true
        #endif
    }

    /// Crop `cg` to a face `boundingBox` (Vision-normalized, origin bottom-left), padded ~45% to take in
    /// the whole head, clamped to the image, converted to top-left pixel space.
    private static func cropFace(_ cg: CGImage, boundingBox: CGRect) -> CGImage? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let padded = boundingBox.insetBy(dx: -boundingBox.width * 0.45, dy: -boundingBox.height * 0.45)
        let unit = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !unit.isNull, unit.width > 0, unit.height > 0 else { return nil }
        let px = CGRect(
            x: unit.origin.x * w,
            y: (1 - unit.origin.y - unit.height) * h,
            width: unit.width * w,
            height: unit.height * h
        ).integral
        // Skip vanishingly small faces (background noise) — they cluster poorly.
        guard px.width >= 48, px.height >= 48 else { return nil }
        return cg.cropping(to: px)
    }

    /// A ~160pt JPEG of a face crop for the tag-a-face grid.
    private static func faceThumbnail(_ cg: CGImage) -> Data? {
        let source = UIImage(cgImage: cg)
        let side: CGFloat = 160
        let scale = min(1, side / max(source.size.width, source.size.height))
        let target = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }

    /// Request a downsized (aspect-fit, so faces aren't cropped away) `CGImage` for scanning.
    private static func loadCGImage(id: String) async -> CGImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let target = CGSize(width: 900, height: 900)
        return await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            var resumed = false
            manager.requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: image?.cgImage)
            }
        }
    }
}
