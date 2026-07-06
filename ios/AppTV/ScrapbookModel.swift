import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Observation
import UIKit

/// Gathers family photo Storage paths (pet + plant `careItems.photoPath`, and each
/// `memories.photoPaths[]`) and streams the decoded images to the ambient slideshow.
///
/// ## Storage on tvOS (P27-T2-C2 open question)
/// The BacanTV target only links `FirebaseAuth` + `FirebaseFirestore` (see `project.yml`) — it does
/// **not** link the `FirebaseStorage` SDK, and this chunk is scoped to `AppTV/*` only (no
/// `project.yml`/xcodeproj changes allowed). So instead of `Storage.storage().reference(...).getData`
/// we pull the bytes straight off the Firebase Storage **download REST endpoint**, authorised with
/// the signed-in TV user's Firebase ID token:
///
///   GET https://firebasestorage.googleapis.com/v0/b/{bucket}/o/{urlEncodedPath}?alt=media
///   Authorization: Firebase {idToken}
///
/// This exercises the exact same auth surface the Storage SDK would (bucket + `request.auth != null`
/// rule in `storage.rules`), so a success/failure here is a definitive answer to "can the tvOS app,
/// signed in as `tv-{hid}`, read family photos out of Storage with the shared plist?".
@MainActor
@Observable
final class ScrapbookModel {
    /// A single ready-to-show frame.
    struct Frame: Identifiable, Equatable {
        let id: String
        let image: UIImage
        let caption: String?
        /// `true` for the procedurally-drawn placeholder frames (shown when Storage is unavailable or
        /// the household has no photos yet), `false` for real family photos.
        let isSample: Bool

        static func == (lhs: Frame, rhs: Frame) -> Bool { lhs.id == rhs.id }
    }

    enum LoadState: Equatable {
        case loading
        /// Real photos loaded from Storage. Count is how many.
        case live(Int)
        /// No real photos available — running on sample frames. `reason` is a short human note.
        case sample(reason: String)
    }

    private(set) var frames: [Frame] = []
    private(set) var state: LoadState = .loading

    /// Set once a Storage download definitively succeeds or fails, for the C2 report / on-screen note.
    private(set) var storageDiagnostic: String?

    private let hid: String
    private let db = Firestore.firestore()

    private let bucket: String = FirebaseApp.app()?.options.storageBucket ?? "menere.firebasestorage.app"

    init(hid: String) {
        self.hid = hid
    }

    // MARK: - Load

    /// Gather every photo path, then progressively download + decode them, appending to `frames` as
    /// each arrives so the slideshow can start on the first image.
    func load() async {
        state = .loading
        let paths = await gatherPhotoPaths()

        if paths.isEmpty {
            installSamples(reason: "No family photos yet — add pets, plants or memories on your phone.")
            return
        }

        var loaded = 0
        var firstError: String?
        for path in paths.shuffled() {
            guard !Task.isCancelled else { return }
            do {
                let data = try await downloadImage(path: path)
                guard let image = UIImage(data: data) else { continue }
                let frame = Frame(id: path, image: image, caption: caption(for: path), isSample: false)
                frames.append(frame)
                loaded += 1
                state = .live(loaded)
                if storageDiagnostic == nil {
                    storageDiagnostic = "Storage OK: downloaded \(data.count) bytes for \(path)"
                }
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        if loaded == 0 {
            let reason = firstError ?? "Couldn't reach family photos."
            storageDiagnostic = "Storage FAILED for all \(paths.count) photo(s): \(reason)"
            installSamples(reason: reason)
        }
    }

    // MARK: - Firestore path gathering

    private func gatherPhotoPaths() async -> [String] {
        let household = db.collection("households").document(hid)
        var paths: [String] = []

        // Pet + plant photos.
        if let care = try? await household.collection("careItems").getDocuments() {
            for doc in care.documents {
                if let p = doc.data()["photoPath"] as? String, !p.isEmpty {
                    paths.append(p)
                }
            }
        }

        // Memory pages — each can carry several photos.
        if let memories = try? await household.collection("memories").getDocuments() {
            for doc in memories.documents {
                if let arr = doc.data()["photoPaths"] as? [String] {
                    paths.append(contentsOf: arr.filter { !$0.isEmpty })
                }
            }
        }

        // De-dupe while preserving discovery order.
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private func caption(for path: String) -> String? {
        // Cheap, warm caption derived from the Storage folder ("memories", "careItems"…).
        if path.contains("/memories/") { return "A moment worth keeping" }
        if path.contains("/careItems/") { return "Family HQ" }
        return nil
    }

    // MARK: - Storage download (REST + Firebase ID token)

    private func downloadImage(path: String) async throws -> Data {
        guard let token = try await Auth.auth().currentUser?.getIDToken() else {
            throw NSError(domain: "Scrapbook", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in."])
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        guard let url = URL(string:
            "https://firebasestorage.googleapis.com/v0/b/\(bucket)/o/\(encoded)?alt=media") else {
            throw NSError(domain: "Scrapbook", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "Bad Storage URL."])
        }
        var req = URLRequest(url: url)
        req.setValue("Firebase \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw NSError(domain: "Scrapbook", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) — \(body)"])
        }
        return data
    }

    // MARK: - Sample frames (Storage-independent so the UI always lights up)

    private func installSamples(reason: String) {
        frames = Self.sampleFrames()
        state = .sample(reason: reason)
        if storageDiagnostic == nil {
            storageDiagnostic = "Running on sample frames: \(reason)"
        }
    }

    /// Procedurally-drawn "photos" — warm gradient cards with an emoji + caption — so the Ken-Burns +
    /// crossfade slideshow is fully demonstrable without any Storage bytes.
    static func sampleFrames() -> [Frame] {
        let specs: [(String, String, [UIColor])] = [
            ("🪴", "Oliver's monstera, thriving", [.init(red: 0.20, green: 0.45, blue: 0.32, alpha: 1),
                                                   .init(red: 0.55, green: 0.72, blue: 0.45, alpha: 1)]),
            ("🐾", "Fajita & Sprinkle, best boys", [.init(red: 0.82, green: 0.45, blue: 0.32, alpha: 1),
                                                    .init(red: 0.95, green: 0.72, blue: 0.42, alpha: 1)]),
            ("🎂", "Famfis turns one", [.init(red: 0.36, green: 0.55, blue: 0.72, alpha: 1),
                                       .init(red: 0.68, green: 0.82, blue: 0.90, alpha: 1)]),
            ("🌻", "Summer in the yard", [.init(red: 0.92, green: 0.68, blue: 0.22, alpha: 1),
                                         .init(red: 0.98, green: 0.90, blue: 0.55, alpha: 1)]),
            ("🌮", "Taco night, again", [.init(red: 0.78, green: 0.35, blue: 0.30, alpha: 1),
                                        .init(red: 0.95, green: 0.60, blue: 0.40, alpha: 1)]),
        ]
        return specs.enumerated().map { idx, spec in
            let img = drawSample(emoji: spec.0, colors: spec.2)
            return Frame(id: "sample-\(idx)", image: img, caption: spec.1, isSample: true)
        }
    }

    private static func drawSample(emoji: String, colors: [UIColor]) -> UIImage {
        let size = CGSize(width: 1600, height: 1000)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors.map(\.cgColor) as CFArray,
                locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero,
                                  end: CGPoint(x: size.width, y: size.height), options: [])
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 360),
            ]
            let s = emoji as NSString
            let bounds = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                               y: (size.height - bounds.height) / 2 - 40), withAttributes: attrs)
        }
    }
}
