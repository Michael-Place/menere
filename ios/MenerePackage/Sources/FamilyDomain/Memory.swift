import Foundation

/// A **family memory** — one scrapbook page (P28-C2). The emotional heart of the app: a rich-text
/// story (portable Markdown, from Rich-Text C1) laid out with one or more photos as a collage, with
/// optional die-cut **stickers** of the boys, a date, which kid(s) it's about, and an optional
/// milestone tag. Collected into a scrollable timeline in the Memories tab.
///
/// Persisted at `households/{hid}/memories/{id}`; photo + sticker JPEG/PNG files live in Storage under
/// `households/{hid}/memories/{id}/…` (paths recorded in `photoPaths` / `stickerPaths`, in order).
///
/// Decode-safe (a custom `init(from:)` defaults every optional/collection) so the schema can grow.
public struct Memory: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// An optional short headline ("Oliver's first word!"). The story lives in `richText`.
    public var title: String?
    /// The story, stored as a portable **Markdown string** (Rich-Text C1) so bold/italic survive and a
    /// future web client can render it. Empty/plain strings render as unformatted text.
    public var richText: String
    /// Storage paths of the memory's photos, in layout order.
    public var photoPaths: [String]
    /// Storage paths of the die-cut **subject-lift stickers** (transparent PNGs) for this memory —
    /// parallel to `photoPaths` where a photo was turned into a sticker. Rendered floating on the page.
    public var stickerPaths: [String]
    /// The `HouseholdMember.id`s this memory is about (Oliver, Famfis, or the whole family).
    public var kidMemberIds: [String]
    /// The day the memory happened (defaults to today at capture) — drives the timeline order + header.
    public var date: Date
    /// An optional milestone tag — a ``Milestone`` suggestion or free text ("First word", "Lost tooth").
    public var milestone: String?
    /// The uid of the family member who captured it.
    public var createdBy: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String? = nil,
        richText: String = "",
        photoPaths: [String] = [],
        stickerPaths: [String] = [],
        kidMemberIds: [String] = [],
        date: Date = Date(),
        milestone: String? = nil,
        createdBy: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.richText = richText
        self.photoPaths = photoPaths
        self.stickerPaths = stickerPaths
        self.kidMemberIds = kidMemberIds
        self.date = date
        self.milestone = milestone
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        richText = try c.decodeIfPresent(String.self, forKey: .richText) ?? ""
        photoPaths = try c.decodeIfPresent([String].self, forKey: .photoPaths) ?? []
        stickerPaths = try c.decodeIfPresent([String].self, forKey: .stickerPaths) ?? []
        kidMemberIds = try c.decodeIfPresent([String].self, forKey: .kidMemberIds) ?? []
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        milestone = try c.decodeIfPresent(String.self, forKey: .milestone)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? (try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date())
    }

    /// The story with no formatting markers — a plain preview line for accessibility / previews.
    public var plainStory: String {
        richText.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when there's nothing worth saving (no story, no photos) — the editor guards Save on this.
    public var isBlank: Bool {
        plainStory.isEmpty && photoPaths.isEmpty && (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// The suggested **milestone** tags offered as chips in the memory editor (free text is allowed too).
/// Kept as a plain string list so `FamilyDomain` stays UI-free and the tag persists as portable text.
public enum Milestone {
    /// The curated first-run suggestions — the milestones a young family reaches for most.
    public static let suggestions: [String] = [
        "First steps",
        "First word",
        "First tooth",
        "Birthday",
        "Lost tooth",
        "First day of school",
        "First haircut",
        "Rolled over",
        "Crawling",
        "First swim",
        "New food",
        "Holiday",
    ]

    /// A friendly SF Symbol for a milestone tag (matched loosely, case-insensitive) — a soft star
    /// default so any free-text milestone still glyphs. UI-agnostic (just a symbol name).
    public static func symbol(for milestone: String) -> String {
        let m = milestone.lowercased()
        if m.contains("step") { return "figure.walk" }
        if m.contains("word") || m.contains("said") { return "text.bubble.fill" }
        if m.contains("tooth") { return "mouth.fill" }
        if m.contains("birthday") { return "birthday.cake.fill" }
        if m.contains("school") { return "backpack.fill" }
        if m.contains("haircut") { return "scissors" }
        if m.contains("roll") { return "arrow.2.circlepath" }
        if m.contains("crawl") { return "figure.roll" }
        if m.contains("swim") { return "figure.pool.swim" }
        if m.contains("food") || m.contains("eat") { return "fork.knife" }
        if m.contains("holiday") || m.contains("christmas") { return "gift.fill" }
        return "star.fill"
    }
}
