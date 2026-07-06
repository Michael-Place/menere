import Social
import SharedCapture
import UIKit
import UniformTypeIdentifiers

// MARK: - Bacán Share Extension (Act V — V5 ingestion front door)
//
// The flagship "open front door": share a URL / text / image / PDF from ANY app → "Bacán" → this
// compact accept sheet (preview + optional note + "Save to Bacán"). On submit we write a
// `PendingShare` (and copy any image/PDF bytes) into the app-group container. The main app drains
// that inbox on foreground and routes it through the existing smart-capture surface.
//
// Deliberately lightweight: links only `SharedCapture` (Foundation-only) — no Firebase, no app UI —
// so the extension stays fast and memory-cheap.
final class ShareViewController: SLComposeServiceViewController {

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
        var shares: [PendingShare] = []
        func append(_ share: PendingShare) { lock.lock(); shares.append(share); lock.unlock() }

        for provider in providers {
            // Order matters: images/PDFs also conform to `public.data`/`public.url` (as file URLs),
            // so test the most specific concrete types first, URL last.
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { fileURL, _ in
                    defer { group.leave() }
                    guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
                    let ext = fileURL.pathExtension.isEmpty ? "jpg" : fileURL.pathExtension
                    if let name = try? PendingShareStore.saveAttachment(data, fileExtension: ext) {
                        append(PendingShare(kind: .image, note: note, attachmentFilename: name))
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { fileURL, _ in
                    defer { group.leave() }
                    guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
                    if let name = try? PendingShareStore.saveAttachment(data, fileExtension: "pdf") {
                        append(PendingShare(
                            kind: .pdf, text: fileURL.lastPathComponent, note: note, attachmentFilename: name
                        ))
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    guard let url = item as? URL else { return }
                    if url.isFileURL {
                        // A file dropped in as a generic URL — treat by extension where we can.
                        guard let data = try? Data(contentsOf: url) else { return }
                        let ext = url.pathExtension.lowercased()
                        let kind: PendingShare.Kind = (ext == "pdf") ? .pdf : .image
                        if let name = try? PendingShareStore.saveAttachment(
                            data, fileExtension: ext.isEmpty ? "dat" : ext
                        ) {
                            append(PendingShare(
                                kind: kind, text: url.lastPathComponent, note: note, attachmentFilename: name
                            ))
                        }
                    } else {
                        append(PendingShare(kind: .url, urlString: url.absoluteString, note: note))
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
                        append(PendingShare(kind: .text, text: text, note: note))
                    } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                        append(PendingShare(kind: .text, text: text, note: note))
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            // Nothing recognizable but the user typed a note → keep the note as a text capture.
            if shares.isEmpty, let note, !note.isEmpty {
                append(PendingShare(kind: .text, text: note))
            }
            for share in shares { try? PendingShareStore.enqueue(share) }
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    private func trimmedNote() -> String? {
        let n = (contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }
}
