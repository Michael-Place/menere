import Dependencies
import Photos
import SwiftUI
import UIKit

/// A throwaway harness for the P27-T0 spike. Drives `PhotoCurationClient` end-to-end so we can
/// screenshot a real album being created + populated on the simulator:
///   1. request Photos access,
///   2. ensure the "Bacán — TV" album exists,
///   3. add two generated sample images,
///   4. re-query the album count to prove the writes landed.
///
/// Reached via the `-photoCurationSpike` launch argument (DEBUG only, see `AppView`). Remove the
/// launch-argument branch + this file to retire the spike — nothing else depends on it.
public struct PhotoCurationDemoView: View {
    @Dependency(\.photoCuration) private var photoCuration

    private let albumName = "Bacán — TV"
    @State private var log: [String] = ["Idle. Tap Run to curate the album."]
    @State private var running = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("P27-T0 · Photo Curation Spike")
                .font(.title2.bold())
            Text("Album: \(albumName)")
                .font(.headline)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))

            Button {
                Task { await run() }
            } label: {
                Text(running ? "Running…" : "Run curation")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)
            .accessibilityIdentifier("run-curation")
        }
        .padding(20)
        .task { await run() } // auto-run on appear so a headless screenshot captures a result
    }

    @MainActor
    private func run() async {
        guard !running else { return }
        running = true
        log = []

        // Skip the interactive picker when access is already granted (e.g. a pre-seeded simulator
        // TCC row) so the spike can run headlessly for a screenshot; otherwise prompt.
        var status = photoCuration.addOnlyAuthorizationStatus()
        append("Existing add-only status: \(describe(status))")
        if status != .authorized && status != .limited {
            append("Requesting Photos access…")
            status = await photoCuration.requestAddAccess()
        }
        append("Authorization: \(describe(status))")
        guard status == .authorized || status == .limited else {
            append("Not authorized — cannot curate. (Grant Photos add access.)")
            running = false
            return
        }

        append("Ensuring album \"\(albumName)\"…")
        let albumId = await photoCuration.ensureAlbum(albumName)
        append("Album id: \(albumId ?? "nil")")

        append("Adding 2 sample images…")
        let samples = [
            Self.sampleImageData(seed: "Fajita", color: .systemTeal),
            Self.sampleImageData(seed: "Sprinkle", color: .systemOrange),
        ].compactMap { $0 }
        let result = await photoCuration.addImages(samples, albumName)
        append("Added \(result.addedCount) asset(s).")
        append("New asset ids: \(result.assetLocalIdentifiers.map { String($0.prefix(8)) }.joined(separator: ", "))")

        let count = await photoCuration.albumAssetCount(albumName)
        append("Album now holds \(count) asset(s). ✅")
        running = false
    }

    private func append(_ line: String) {
        log.append(line)
    }

    private func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        @unknown default: "unknown"
        }
    }

    /// Render a simple labeled swatch to PNG data so the spike has real bytes to persist without
    /// bundling asset files.
    static func sampleImageData(seed: String, color: UIColor) -> Data? {
        let size = CGSize(width: 1200, height: 800)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "Bacán · \(seed)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white,
                .font: UIFont.boldSystemFont(ofSize: 96),
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(
                at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                withAttributes: attrs
            )
        }
        return image.pngData()
    }
}

#Preview {
    PhotoCurationDemoView()
}
