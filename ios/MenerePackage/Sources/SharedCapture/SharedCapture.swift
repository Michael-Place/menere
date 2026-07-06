import Foundation

// MARK: - SharedCapture (Act V — V5 Share Extension ingestion front door)
//
// The tiny, Foundation-only bridge that lets the **Share Extension** (a separate process/target)
// hand a shared item to the **main app** without any Firebase/UI dependency. It owns:
//   • the app-group identifier (must match the entitlement on BOTH targets),
//   • `PendingShare` — the codable descriptor of one shared item,
//   • `PendingShareStore` — the on-disk inbox inside the app-group container, and
//   • `CaptureHandoffStore` — the app-group UserDefaults slot the app parks the routed share in for
//     the in-app smart-capture surface to read (read-and-clear) once it foregrounds.
//
// Flow: Share sheet → extension writes a `PendingShare` (+ copies any image/PDF) into the container →
// app on foreground drains the inbox, stashes the newest share in `CaptureHandoffStore`, clears the
// inbox files, and opens the capture surface (via `AppCore.IntentRouter` `.capture`). The capture
// surface calls `CaptureHandoffStore.take()` to consume it.

public enum SharedCapture {
    /// The app group shared by the main app + the Share Extension. Must match the
    /// `com.apple.security.application-groups` entitlement on BOTH targets.
    public static let appGroupID = "group.com.copoche.menere"
}

// MARK: - PendingShare

/// One item shared into Bacán. Carries the type + payload (text/URL and/or a copied image/PDF file)
/// plus an optional note the user typed in the accept sheet.
public struct PendingShare: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case url    // a web link (public.url)
        case text   // plain / selected text (public.text)
        case image  // a photo (public.image) — bytes copied into the container
        case pdf    // a PDF document (com.adobe.pdf) — bytes copied into the container
    }

    public var id: String
    public var kind: Kind
    /// Shared plain text, selected text, or the page title.
    public var text: String?
    /// Shared URL, as an absolute string.
    public var urlString: String?
    /// Optional note the user typed in the accept sheet ("Save to Bacán").
    public var note: String?
    /// Relative filename of a copied image/PDF in the container's attachments dir (kind image/pdf).
    public var attachmentFilename: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        text: String? = nil,
        urlString: String? = nil,
        note: String? = nil,
        attachmentFilename: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.urlString = urlString
        self.note = note
        self.attachmentFilename = attachmentFilename
        self.createdAt = createdAt
    }

    /// A single line combining note + text + URL, the way the smart-capture compose field wants it.
    /// (The URL front door reuses `CaptureReducer.detectURL`, which reads a URL anywhere in text.)
    public var composeText: String {
        var parts: [String] = []
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            parts.append(note)
        }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            parts.append(text)
        }
        if let urlString, !urlString.isEmpty, urlString != text {
            parts.append(urlString)
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - PendingShareStore (the on-disk inbox inside the app-group container)

public enum PendingShareStore {
    private static let inboxDirName = "ShareInbox"
    private static let attachmentsDirName = "Attachments"

    /// The app-group container root, or nil if the app group isn't provisioned/entitled.
    public static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedCapture.appGroupID)
    }

    private static func inboxURL() -> URL? {
        containerURL()?.appendingPathComponent(inboxDirName, isDirectory: true)
    }

    private static func attachmentsURL() -> URL? {
        inboxURL()?.appendingPathComponent(attachmentsDirName, isDirectory: true)
    }

    private static func ensureDirs() {
        let fm = FileManager.default
        if let inbox = inboxURL() {
            try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        if let atts = attachmentsURL() {
            try? fm.createDirectory(at: atts, withIntermediateDirectories: true)
        }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Copy attachment bytes (image/PDF) into the shared container; returns the relative filename.
    @discardableResult
    public static func saveAttachment(_ data: Data, fileExtension: String) throws -> String {
        ensureDirs()
        guard let atts = attachmentsURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let ext = fileExtension.isEmpty ? "dat" : fileExtension
        let name = UUID().uuidString + "." + ext
        try data.write(to: atts.appendingPathComponent(name), options: .atomic)
        return name
    }

    /// Absolute URL of a stored attachment.
    public static func attachmentURL(for filename: String) -> URL? {
        attachmentsURL()?.appendingPathComponent(filename)
    }

    /// Persist a pending-share descriptor as JSON in the inbox.
    public static func enqueue(_ share: PendingShare) throws {
        ensureDirs()
        guard let inbox = inboxURL() else { throw CocoaError(.fileNoSuchFile) }
        let data = try encoder.encode(share)
        try data.write(to: inbox.appendingPathComponent(share.id + ".json"), options: .atomic)
    }

    /// All pending shares, oldest → newest (by `createdAt`).
    public static func pending() -> [PendingShare] {
        guard
            let inbox = inboxURL(),
            let files = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil
            )
        else { return [] }
        let shares = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(PendingShare.self, from: Data(contentsOf: $0)) }
        return shares.sorted { $0.createdAt < $1.createdAt }
    }

    /// Remove one descriptor's JSON (and, unless `keepAttachment`, its attachment file).
    public static func remove(_ share: PendingShare, keepAttachment: Bool = false) {
        let fm = FileManager.default
        if let inbox = inboxURL() {
            try? fm.removeItem(at: inbox.appendingPathComponent(share.id + ".json"))
        }
        if !keepAttachment, let name = share.attachmentFilename, let url = attachmentURL(for: name) {
            try? fm.removeItem(at: url)
        }
    }

    /// Delete every attachment file **except** those whose filename is in `keeping`.
    public static func pruneAttachments(keeping: Set<String>) {
        guard
            let atts = attachmentsURL(),
            let files = try? FileManager.default.contentsOfDirectory(
                at: atts, includingPropertiesForKeys: nil
            )
        else { return }
        for file in files where !keeping.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - CaptureHandoffStore (app → in-app capture surface, via app-group UserDefaults)

/// The routed share the app parks for the smart-capture surface to consume once it foregrounds.
/// Kept in the app-group UserDefaults so an in-app `@Shared(.appStorage)`-style reader can pick it up
/// without any change to the extension. Read-and-clear via `take()`.
public enum CaptureHandoffStore {
    private static let key = "bacan.pendingCaptureHandoff"

    private static func defaults() -> UserDefaults? {
        UserDefaults(suiteName: SharedCapture.appGroupID)
    }

    /// Park a routed share for the capture surface (last share wins).
    public static func stash(_ share: PendingShare) {
        guard let data = try? JSONEncoder().encode(share) else { return }
        defaults()?.set(data, forKey: key)
    }

    /// Read the parked share WITHOUT clearing it.
    public static func peek() -> PendingShare? {
        guard let data = defaults()?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingShare.self, from: data)
    }

    /// Read-and-clear the parked share (the capture surface consumes it exactly once).
    public static func take() -> PendingShare? {
        let share = peek()
        defaults()?.removeObject(forKey: key)
        return share
    }
}
