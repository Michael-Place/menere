import SwiftUI
import UIKit
import VisionKit

/// Whether the in-app document camera is usable on this device. `false` on the simulator, which the
/// reducer uses to degrade "Scan document" to a friendly alert.
///
/// Runtime checks are unreliable on the iOS 26 simulator — both `VNDocumentCameraViewController
/// .isSupported` and `UIImagePickerController.isSourceTypeAvailable(.camera)` report `true` there,
/// after which VisionKit presents a broken scanner behind its own "Camera Unavailable" alert. A
/// compile-time `targetEnvironment(simulator)` guard is the only reliable signal: the scanner code
/// path still exists and compiles, but on simulator builds it degrades to our friendly alert.
public enum DocumentScanSupport {
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return VNDocumentCameraViewController.isSupported
        #endif
    }
}

/// JPEG compression + downscaling shared by every intake path (scan / photos).
public enum DocumentImageProcessing {
    /// Downscale to a long edge of `maxEdge` and JPEG-encode at `quality`. Returns `nil` if the bytes
    /// aren't a decodable image (caller falls back to the original bytes).
    public static func compressedJPEG(from data: Data, maxEdge: CGFloat = 2200, quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return compressedJPEG(from: image, maxEdge: maxEdge, quality: quality)
    }

    public static func compressedJPEG(from image: UIImage, maxEdge: CGFloat = 2200, quality: CGFloat = 0.7) -> Data? {
        let resized = downscale(image, maxEdge: maxEdge)
        return resized.jpegData(compressionQuality: quality)
    }

    static func downscale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
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

/// VisionKit document scanner wrapped for SwiftUI. Returns the scanned pages as JPEG `Data` (one per
/// scanned page). Only presented when `DocumentScanSupport.isAvailable` is true.
struct DocumentScannerView: UIViewControllerRepresentable {
    var onComplete: ([Data]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var datas: [Data] = []
            for index in 0..<scan.pageCount {
                let page = scan.imageOfPage(at: index)
                if let jpeg = DocumentImageProcessing.compressedJPEG(from: page) {
                    datas.append(jpeg)
                }
            }
            parent.onComplete(datas)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}
