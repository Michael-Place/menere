import Dependencies
import StorageClient
import SwiftUI
import UIKit

/// H1 — the one cached image view for ¡Bacán!.
///
/// `BacanImage(path:)` renders a **member-gated Firebase Storage** image (resolved through
/// `StorageClient.downloadData`, cached forever by path). `BacanImage(url:)` renders an **http**
/// image (TTL-cached). Both read through the shared ``ImagePipeline``:
///
/// - A **warm memory cache paints on the first frame** — no placeholder flash, no re-download when a
///   plant/pet/memory scrolls back into view.
/// - A **cold miss** shows the placeholder, fetches + decodes off-main, then swaps in.
/// - Grids pass a `targetSize` so the pipeline **downsamples** at decode time (no full-res in a 44pt chip).
///
/// The default initializers use a soft branded placeholder; the `placeholder:` overloads let care
/// rows keep their leaf / pawprint fallbacks.
public struct BacanImage<Placeholder: View>: View {
    enum Source: Equatable {
        case storage(String)
        case remote(URL)

        var key: String {
            switch self {
            case let .storage(path): return path
            case let .remote(url): return url.absoluteString
            }
        }
    }

    private let source: Source?
    private let targetSize: CGSize?
    private let contentMode: ContentMode
    private let placeholder: Placeholder

    @Dependency(\.storage) private var storage
    @State private var image: UIImage?

    // MARK: Storage path

    public init(
        path: String?,
        targetSize: CGSize? = nil,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        let source: Source? = (path.map { !$0.isEmpty } ?? false) ? .storage(path!) : nil
        self.source = source
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.placeholder = placeholder()
        _image = State(initialValue: Self.warm(source, targetSize))
    }

    // MARK: http URL

    public init(
        url: URL?,
        targetSize: CGSize? = nil,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        let source: Source? = url.map(Source.remote)
        self.source = source
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.placeholder = placeholder()
        _image = State(initialValue: Self.warm(source, targetSize))
    }

    /// Synchronous warm-cache seed so a memory hit renders on frame one.
    private static func warm(_ source: Source?, _ size: CGSize?) -> UIImage? {
        guard let source else { return nil }
        return ImagePipeline.shared.cachedImage(forKey: ImagePipeline.memKey(source.key, size))
    }

    public var body: some View {
        content
            .task(id: source) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            placeholder
        }
    }

    private func load() async {
        guard image == nil, let source else { return }
        do {
            switch source {
            case let .storage(path):
                image = try await ImagePipeline.shared.image(forStoragePath: path, targetSize: targetSize) {
                    try await storage.downloadData(path)
                }
            case let .remote(url):
                image = try await ImagePipeline.shared.image(forURL: url, targetSize: targetSize)
            }
        } catch {
            // Leave `image` nil → the placeholder stands in as the graceful failure state.
        }
    }
}

// MARK: - Default placeholder

/// A soft branded placeholder (a faint tint + spinner) for the no-argument initializers.
public struct BacanImagePlaceholder: View {
    public init() {}
    public var body: some View {
        ZStack {
            Color.bacanGreen.opacity(0.10)
            ProgressView().tint(Color.bacanGreen)
        }
    }
}

public extension BacanImage where Placeholder == BacanImagePlaceholder {
    init(path: String?, targetSize: CGSize? = nil, contentMode: ContentMode = .fill) {
        self.init(path: path, targetSize: targetSize, contentMode: contentMode) { BacanImagePlaceholder() }
    }

    init(url: URL?, targetSize: CGSize? = nil, contentMode: ContentMode = .fill) {
        self.init(url: url, targetSize: targetSize, contentMode: contentMode) { BacanImagePlaceholder() }
    }
}
