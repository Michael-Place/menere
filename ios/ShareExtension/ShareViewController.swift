import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseStorage
import Social
import SharedCapture
import UIKit
import UniformTypeIdentifiers

// MARK: - Bacán Share Extension (Act V — V5 ingestion front door, DIRECT-TO-CLOUD)
//
// Share a URL / text / image / PDF / file from ANY app → "Bacán" → this compact accept sheet
// (preview + optional note + "Save to Bacán"). What happens on submit depends on the type:
//
//   • **PDF / file / image → straight to Firebase.** Using the signed-in session restored from the
//     SHARED keychain access group (`Z2FNFL3X73.com.copoche.menere.firebase`, set by the main app's
//     `Auth.auth().useUserAccessGroup(_:)`), we upload the bytes to Storage and create a *pending*
//     `households/{hid}/documents/{id}` doc (`needsServerProcessing: true`, `source: "share"`). The
//     peer's `onDocumentCreated` Cloud Function then runs the Family-Brain AI server-side. NO app-open
//     is needed — the doc appears in the Brain on its own.
//   • **URL / text → app-group handoff (unchanged).** These need in-app AI routing (link unfurl /
//     smart capture), so they still land in the `PendingShare` inbox for the app to drain on foreground.
//   • **Not signed in / no shared session → fallback.** If `Auth.auth().currentUser` is nil (or a
//     direct upload fails), the file/image/PDF FALLS BACK to the same app-group `PendingShare` write,
//     so nothing is ever lost.
//
// Firebase (Auth/Firestore/Storage) links into the appex; kept lean (one file upload at a time).
final class ShareViewController: SLComposeServiceViewController {

    /// The shared keychain access group the main app parks its auth token in (team-prefixed). Must
    /// match the app's `useUserAccessGroup(_:)` + the extension's `keychain-access-groups` entitlement.
    private static let authAccessGroup = "Z2FNFL3X73.com.copoche.menere.firebase"

    /// A file the user shared (PDF / image / generic file) — a direct-upload candidate.
    private struct SharedFile {
        let data: Data
        /// Lowercased file extension (no dot); "" if unknown.
        let ext: String
        /// The source filename, if any (used as a document-title fallback).
        let filename: String?
    }

    override func presentationAnimationDidFinish() {
        super.presentationAnimationDidFinish()
        title = "Bacán"
        placeholder = "Add a note (optional)"
    }

    /// Always allow posting — a bare share (no note) is valid; the note is optional flavor.
    override func isContentValid() -> Bool { true }

    /// No extra configuration rows.
    override func configurationItems() -> [Any]! { [] }

    override func didSelectPost() {
        let note = trimmedNote()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        let group = DispatchGroup()
        let lock = NSLock()
        // Files (pdf/image/generic) → try direct-to-cloud; url/text → app-group handoff.
        var files: [SharedFile] = []
        var handoffs: [PendingShare] = []
        func addFile(_ file: SharedFile) { lock.lock(); files.append(file); lock.unlock() }
        func addHandoff(_ share: PendingShare) { lock.lock(); handoffs.append(share); lock.unlock() }

        for provider in providers {
            // Order matters: images/PDFs also conform to `public.data`/`public.url` (as file URLs),
            // so test the most specific concrete types first, URL last.
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { fileURL, _ in
                    defer { group.leave() }
                    guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
                    let ext = fileURL.pathExtension.isEmpty ? "jpg" : fileURL.pathExtension.lowercased()
                    addFile(SharedFile(data: data, ext: ext, filename: fileURL.lastPathComponent))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { fileURL, _ in
                    defer { group.leave() }
                    guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
                    addFile(SharedFile(data: data, ext: "pdf", filename: fileURL.lastPathComponent))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    guard let url = item as? URL else { return }
                    if url.isFileURL {
                        // A file dropped in as a generic URL — upload it as a Brain document by its
                        // real extension (previously non-pdf files were mislabeled `.image`).
                        guard let data = try? Data(contentsOf: url) else { return }
                        let ext = url.pathExtension.lowercased()
                        addFile(SharedFile(data: data, ext: ext, filename: url.lastPathComponent))
                    } else {
                        // A web link → in-app AI routing (unfurl / smart capture) via the handoff inbox.
                        addHandoff(PendingShare(kind: .url, urlString: url.absoluteString, note: note))
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                        || provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                group.enter()
                let tid = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                    ? UTType.plainText.identifier : UTType.text.identifier
                provider.loadItem(forTypeIdentifier: tid, options: nil) { item, _ in
                    defer { group.leave() }
                    if let text = item as? String {
                        addHandoff(PendingShare(kind: .text, text: text, note: note))
                    } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                        addHandoff(PendingShare(kind: .text, text: text, note: note))
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // Nothing recognizable but the user typed a note → keep the note as a text capture.
            if files.isEmpty, handoffs.isEmpty, let note, !note.isEmpty {
                handoffs.append(PendingShare(kind: .text, text: note))
            }
            Task { await self.finishPost(files: files, handoffs: handoffs, note: note) }
        }
    }

    // MARK: - Direct-to-cloud + handoff

    /// Upload every shared file straight to Firebase when signed in; fall back to the app-group inbox
    /// otherwise. URL/text handoffs always go to the inbox. Then show a brief result + complete.
    private func finishPost(files: [SharedFile], handoffs: [PendingShare], note: String?) async {
        let uid = Self.restoreSignedInUID()

        var savedToCloud = 0
        var anyFailure = false

        for file in files {
            if let uid {
                do {
                    try await Self.uploadDocument(uid: uid, file: file, note: note)
                    savedToCloud += 1
                    continue
                } catch {
                    anyFailure = true
                    // fall through → don't lose it; park in the app-group inbox for the app to drain.
                }
            }
            enqueueFileFallback(file, note: note)
        }

        // URL/text always route through the in-app capture surface.
        for share in handoffs { try? PendingShareStore.enqueue(share) }

        let handedOff = handoffs.count + (uid == nil ? files.count : (files.count - savedToCloud))
        completeShowing(savedToCloud: savedToCloud, handedOff: handedOff, failed: anyFailure && savedToCloud == 0)
    }

    /// Configure Firebase (guarded), restore the shared-keychain auth session, and return the signed-in
    /// uid — or nil when there is no shared session (user not signed in on this device).
    private static func restoreSignedInUID() -> String? {
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        // Point Auth at the SHARED keychain group so it restores the token the main app stored there.
        try? Auth.auth().useUserAccessGroup(authAccessGroup)
        return Auth.auth().currentUser?.uid
    }

    /// Upload one shared file to Storage and create a *pending* Family-Brain document that the peer's
    /// `onDocumentCreated` Cloud Function will process server-side.
    private static func uploadDocument(uid: String, file: SharedFile, note: String?) async throws {
        let db = Firestore.firestore()

        // Resolve the household from the caller's profile.
        let userSnap = try await db.collection("users").document(uid).getDocument()
        guard let hid = userSnap.data()?["householdId"] as? String, !hid.isEmpty else {
            throw NSError(domain: "BacanShare", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No household for user"])
        }

        let docId = UUID().uuidString
        let ext = file.ext.isEmpty ? "pdf" : file.ext
        // PDFs land at the canonical `document.pdf`; other files/images at `document.{ext}`.
        let storagePath = "households/\(hid)/documents/\(docId)/document.\(ext)"

        // Upload the bytes.
        let ref = Storage.storage().reference().child(storagePath)
        let metadata = StorageMetadata()
        metadata.contentType = contentType(forExt: ext)
        _ = try await ref.putDataAsync(file.data, metadata: metadata)

        // Create the pending document. Field shape matches `FamilyDomain.Document`'s Codable keys; the
        // extra `needsServerProcessing` / `source` flags signal the share intake to `onDocumentCreated`
        // (and are ignored by the app's `Document` decoder).
        let title = documentTitle(note: note, file: file)
        let doc: [String: Any] = [
            "id": docId,
            "title": title,
            "type": "other",
            "tags": [String](),
            "linkedMemberIds": [String](),
            "linkedPetIds": [String](),
            "pagePaths": [storagePath],
            "uploadedBy": uid,
            "createdAt": Timestamp(date: Date()),
            "processingState": "pending",
            "needsServerProcessing": true,
            "source": "share",
        ]
        try await db.collection("households").document(hid)
            .collection("documents").document(docId).setData(doc)
    }

    /// A friendly document title: the user's note wins; else the source filename (sans extension);
    /// else a type-appropriate default.
    private static func documentTitle(note: String?, file: SharedFile) -> String {
        if let note, !note.isEmpty { return note }
        if let name = file.filename, !name.isEmpty {
            let stem = (name as NSString).deletingPathExtension
            if !stem.isEmpty { return stem }
        }
        switch file.ext {
        case "pdf": return "Shared PDF"
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "Shared photo"
        default: return "Shared to Bacán"
        }
    }

    private static func contentType(forExt ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    /// Not-signed-in / upload-failed fallback: copy the file bytes into the app-group container and
    /// enqueue a `PendingShare` so the app can drain + upload it on next foreground.
    private func enqueueFileFallback(_ file: SharedFile, note: String?) {
        let ext = file.ext.isEmpty ? "dat" : file.ext
        guard let name = try? PendingShareStore.saveAttachment(file.data, fileExtension: ext) else { return }
        let kind: PendingShare.Kind = (ext == "pdf") ? .pdf : .image
        let share = PendingShare(kind: kind, text: file.filename, note: note, attachmentFilename: name)
        try? PendingShareStore.enqueue(share)
    }

    private func trimmedNote() -> String? {
        let n = (contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    // MARK: - Result UI

    /// Show a brief confirmation over the sheet, then complete the request.
    private func completeShowing(savedToCloud: Int, handedOff: Int, failed: Bool) {
        let message: String
        if failed {
            message = "Couldn’t save — try again"
        } else if savedToCloud > 0 {
            message = "Saved to Bacán ✓"
        } else if handedOff > 0 {
            message = "Sent to Bacán ✓"
        } else {
            message = "Saved to Bacán ✓"
        }
        showToast(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    /// A small centered pill shown briefly before the sheet dismisses.
    private func showToast(_ text: String) {
        let label = PaddedLabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.textAlignment = .center
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
    }
}

/// A `UILabel` with interior padding, for the confirmation pill.
private final class PaddedLabel: UILabel {
    private let inset = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: inset)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + inset.left + inset.right,
                      height: s.height + inset.top + inset.bottom)
    }
}
