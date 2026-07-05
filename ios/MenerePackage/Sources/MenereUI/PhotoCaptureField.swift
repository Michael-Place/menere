import CoreImage
import PhotosUI
import SwiftUI
import UIKit
import Vision

// MARK: - P26-IMG-C2 — best-in-class capture + subject-lift stickers
//
// A reusable family-surface photo pipeline that feeds the "Layered collage" scrapbook look
// (see ``ScrapbookPhoto``). Three parts, all self-contained in MenereUI so any feature can adopt them:
//   1. ``CaptureImageProcessing`` — square crop + downscale + JPEG(~0.8) + a small thumbnail, run
//      BEFORE bytes reach the existing StorageClient upload (no Storage rebuild).
//   2. ``SubjectLifter`` — on-device Vision foreground-instance mask → a die-cut subject cutout on a
//      transparent background, optionally wrapped in a white "sticker" matte. Never throws; returns
//      nil on any failure so callers fall back to the plain photo.
//   3. Display: ``StickerImage`` (die-cut with a soft lift + ``stickerSlap``) and ``ScrapbookSticker``
//      (the same cutout mounted on the kraft scrapbook mat), plus ``PhotoCaptureField`` — the composed
//      picker + camera + interactive square-crop + retake control.

// MARK: - Image processing

/// Efficient still-image prep for family photos: an interactive/auto **square crop**, a **downscale**
/// to a sane max dimension, **JPEG ~0.8** compression, and a cheap **thumbnail** for snappy preview —
/// all done locally before the bytes are handed to the existing upload path.
public enum CaptureImageProcessing {
    /// The output of ``process(_:)`` — the full (downscaled) JPEG to upload plus a tiny thumbnail
    /// JPEG for immediate on-screen preview while the full image settles.
    public struct Processed: Equatable, Sendable {
        /// Downscaled, ~0.8-quality JPEG — what gets uploaded.
        public let jpeg: Data
        /// A small (~320px) JPEG for a fast local thumbnail.
        public let thumbnail: Data

        public init(jpeg: Data, thumbnail: Data) {
            self.jpeg = jpeg
            self.thumbnail = thumbnail
        }
    }

    /// Downscale so the longest edge is at most `maxEdge`, then JPEG-encode at `quality`.
    public static func downscaledJPEG(from image: UIImage, maxEdge: CGFloat = 1600, quality: CGFloat = 0.8) -> Data? {
        resized(image, maxEdge: maxEdge).jpegData(compressionQuality: quality)
    }

    /// A small square-ish thumbnail JPEG for immediate preview (kept deliberately cheap).
    public static func thumbnailJPEG(from image: UIImage, maxEdge: CGFloat = 320, quality: CGFloat = 0.7) -> Data? {
        resized(image, maxEdge: maxEdge).jpegData(compressionQuality: quality)
    }

    /// Center-crop `image` to a square (largest centered square that fits). A no-op when already square.
    public static func squareCropped(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w != h, w > 0, h > 0 else { return image }
        let side = min(w, h)
        let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Full pipeline: downscale + JPEG(~0.8) for upload plus a thumbnail. `nil` if encoding fails.
    public static func process(_ image: UIImage, maxEdge: CGFloat = 1600, quality: CGFloat = 0.8) -> Processed? {
        guard let jpeg = downscaledJPEG(from: image, maxEdge: maxEdge, quality: quality),
              let thumb = thumbnailJPEG(from: image) else { return nil }
        return Processed(jpeg: jpeg, thumbnail: thumb)
    }

    /// Redraw `image` so its longest edge is `maxEdge` (bakes in orientation, scale 1). A no-op when
    /// already small enough.
    static func resized(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let scale = maxEdge / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Subject lifting (Vision)

/// On-device subject lifting via Vision's `VNGenerateForegroundInstanceMaskRequest` (iOS 17+, works on
/// the simulator). Turns a photo into a **die-cut cutout** — the foreground subject on a transparent
/// background — and can wrap it in a white "sticker" matte. Every entry point is failure-tolerant:
/// no subject / unsupported / error all return `nil` (or the input) so the caller keeps the plain photo.
public enum SubjectLifter {
    /// Lift the foreground subject(s) onto a transparent background, cropped to the subject's extent.
    /// Runs off the main thread; `nil` when Vision finds no subject or the request fails.
    public static func liftSubject(from image: UIImage) async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: cutout(from: image))
            }
        }
    }

    /// Lift the subject AND wrap it in a white die-cut matte in one call (the sticker asset we store).
    /// `nil` when there's no subject; falls back to the bare cutout if the matte step fails.
    public static func liftSticker(from image: UIImage, borderPoints: CGFloat = 14) async -> UIImage? {
        guard let cut = await liftSubject(from: image) else { return nil }
        return diecut(from: cut, borderPoints: borderPoints)
    }

    /// Synchronous Vision pass. Kept private; call ``liftSubject(from:)``.
    private static func cutout(from image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(
            cgImage: cg, orientation: cgOrientation(image.imageOrientation), options: [:]
        )
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateMaskedImage(
                ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true
            )
            let ci = CIImage(cvPixelBuffer: buffer)
            let context = CIContext(options: nil)
            guard let out = context.createCGImage(ci, from: ci.extent) else { return nil }
            return UIImage(cgImage: out)
        } catch {
            return nil   // never crash — the caller keeps the plain photo
        }
    }

    /// Wrap a transparent cutout in a solid-white die-cut border (dilate the alpha, fill white, place
    /// the crisp subject on top). Returns the input unchanged on any Core Image failure.
    public static func diecut(from cutout: UIImage, borderPoints: CGFloat = 14) -> UIImage {
        guard let ci = CIImage(image: cutout) else { return cutout }
        let scale = max(cutout.scale, 1)
        let radius = max(1, borderPoints * scale)
        let dilated = ci.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
        // Force the dilated silhouette to solid white while keeping its (spread) alpha — the matte.
        let matte = dilated.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ])
        let composited = ci.composited(over: matte)
        let extent = composited.extent.integral
        guard extent.isNull == false, extent.isInfinite == false,
              let out = CIContext(options: nil).createCGImage(composited, from: extent)
        else { return cutout }
        return UIImage(cgImage: out, scale: scale, orientation: .up)
    }

    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

// MARK: - Sticker display

/// A die-cut sticker: the transparent subject cutout (usually white-matted by ``SubjectLifter/diecut``)
/// lifted off the page with a soft shadow, landing with a ``stickerSlap`` on first appearance.
public struct StickerImage: View {
    private let image: UIImage?
    private let slapOnAppear: Bool
    @State private var landed = false

    public init(image: UIImage?, slapOnAppear: Bool = true) {
        self.image = image
        self.slapOnAppear = slapOnAppear
    }

    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 6)
                    .stickerSlap(isOn: landed)
                    .onAppear { if slapOnAppear { landed = true } }
            }
        }
    }
}

/// The subject cutout mounted on the warm kraft **scrapbook mat** (the sibling of ``ScrapbookPhoto`` for
/// lifted stickers): kraft paper + grain + a seeded tilt + a soft shadow, with the die-cut subject
/// slapping down on appearance. Feeds the same "Layered collage" look as the normal photo. When `image`
/// is `nil` the `fallback` glyph shows on the mat.
public struct ScrapbookSticker<Fallback: View>: View {
    private let image: UIImage?
    private let seed: String
    private let caption: String?
    private let date: Date?
    private let aspect: CGFloat
    private let fallback: Fallback
    @State private var landed = false

    public init(
        image: UIImage?,
        seed: String,
        caption: String? = nil,
        date: Date? = nil,
        aspect: CGFloat = 1,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.image = image
        self.seed = seed
        self.caption = caption
        self.date = date
        self.aspect = aspect
        self.fallback = fallback()
    }

    private var tilt: Double { Scrapbook.tilt(for: seed, max: 2.5) }
    private var hasLabel: Bool { (caption?.isEmpty == false) || date != nil }

    public var body: some View {
        VStack(spacing: hasLabel ? 8 : 0) {
            Color.clear
                .aspectRatio(aspect, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                            .shadow(color: .black.opacity(0.26), radius: 7, x: 0, y: 5)
                            .stickerSlap(isOn: landed)
                    } else {
                        fallback
                    }
                }
            if hasLabel { label }
        }
        .padding(14)
        .padding(.bottom, hasLabel ? 2 : 0)
        .background(mat)
        .shadow(color: .black.opacity(0.22), radius: 9, x: 0, y: 5)
        .rotationEffect(.degrees(tilt))
        .onAppear { landed = true }
    }

    private var mat: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.scrapbookMat)
            .overlay(
                Image(uiImage: ScrapbookTexture.grain)
                    .resizable(resizingMode: .tile)
                    .opacity(0.6)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .allowsHitTesting(false)
            )
    }

    private var label: some View {
        VStack(spacing: 1) {
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
            }
            if let date {
                Text(date, format: .dateTime.month(.abbreviated).day().year())
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Camera (compiles everywhere; unavailable on the simulator)

/// Wraps `UIImagePickerController(.camera)` and hands back the captured `UIImage`. The camera reports
/// unavailable on the simulator, so callers gate the entry point on ``isCameraAvailable``.
public struct CameraPicker: UIViewControllerRepresentable {
    private let onCapture: (UIImage) -> Void
    private let onCancel: () -> Void

    /// `true` only on a real device with a camera — `false` on the simulator (degrade gracefully).
    public static var isCameraAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }

    public init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onCancel = onCancel
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCancel: onCancel) }

    public func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    public final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        public func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { onCapture(image) } else { onCancel() }
        }

        public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}

// MARK: - Interactive square crop

/// A pan + pinch **square crop** sheet: the picked/captured image fills a square viewport that the user
/// can drag and zoom; "Use photo" renders exactly what's framed (via `ImageRenderer`) and reports it.
/// Auto-fits the image on open, so a straight "Use photo" gives a sensible centered square.
public struct SquareCropSheet: View {
    private let image: UIImage
    private let onCrop: (UIImage) -> Void
    private let onCancel: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    public init(image: UIImage, onCrop: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.image = image
        self.onCrop = onCrop
        self.onCancel = onCancel
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 40
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                cropSquare(side: side)
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity)
                Text("Drag to reposition · pinch to zoom")
                    .font(.footnote)
                    .foregroundStyle(Color.inkSoft)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.headline)
                            .foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("crop-cancel")
                    Button {
                        onCrop(rendered(side: side))
                    } label: {
                        Text("Use photo")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.bacanGreen, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("crop-confirm")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.familyCanvas.ignoresSafeArea())
        }
    }

    /// The framed content — reused for both display and `ImageRenderer` output so what you see is what
    /// you crop.
    private func cropSquare(side: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .scaleEffect(zoom)
            .offset(offset)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            offset = CGSize(width: committedOffset.width + v.translation.width,
                                            height: committedOffset.height + v.translation.height)
                        }
                        .onEnded { _ in committedOffset = offset },
                    MagnificationGesture()
                        .onChanged { s in zoom = max(1, committedZoom * s) }
                        .onEnded { _ in committedZoom = zoom }
                )
            )
    }

    /// Render the exact framed square to a UIImage, upscaled toward ~1200px for upload quality.
    @MainActor private func rendered(side: CGFloat) -> UIImage {
        let renderer = ImageRenderer(content: cropSquare(side: side))
        renderer.scale = max(displayScale, 1200 / max(side, 1))
        return renderer.uiImage ?? CaptureImageProcessing.squareCropped(image)
    }
}

// MARK: - PhotoCaptureField (composed reusable control)

/// A polished, self-contained capture control for family surfaces: a thumbnail of the current image,
/// a system **PhotosPicker**, a **camera** path (hidden on the simulator), and an interactive
/// **square crop** step — reporting the processed (cropped + downscaled + JPEG ~0.8) bytes via
/// `onProcessed`, plus a fast thumbnail. Retake = pick/shoot again. Designed to sit inside a `Form`
/// section or a plain stack.
public struct PhotoCaptureField: View {
    private let image: UIImage?
    private let fallbackSymbol: String
    private let tint: Color
    private let onProcessed: (CaptureImageProcessing.Processed) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var cropCandidate: CropCandidate?

    /// A picked/captured image awaiting the crop step (Identifiable so it drives a `.sheet(item:)`).
    private struct CropCandidate: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    public init(
        image: UIImage?,
        fallbackSymbol: String,
        tint: Color,
        onProcessed: @escaping (CaptureImageProcessing.Processed) -> Void
    ) {
        self.image = image
        self.fallbackSymbol = fallbackSymbol
        self.tint = tint
        self.onProcessed = onProcessed
    }

    public var body: some View {
        HStack(spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 10) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(image == nil ? "Choose photo" : "Change photo", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("capture-photo-picker")

                if CameraPicker.isCameraAvailable {
                    Button { showCamera = true } label: {
                        Label("Take photo", systemImage: "camera")
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("capture-photo-camera")
                }
            }
            Spacer()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    cropCandidate = CropCandidate(image: ui)
                }
                pickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(
                onCapture: { ui in showCamera = false; cropCandidate = CropCandidate(image: ui) },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $cropCandidate) { candidate in
            SquareCropSheet(
                image: candidate.image,
                onCrop: { cropped in
                    cropCandidate = nil
                    if let processed = CaptureImageProcessing.process(cropped) { onProcessed(processed) }
                },
                onCancel: { cropCandidate = nil }
            )
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(tint.opacity(0.15))
                    Image(systemName: fallbackSymbol).font(.title2).foregroundStyle(tint)
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(Circle())
        .accessibilityIdentifier("capture-photo-thumbnail")
    }
}
