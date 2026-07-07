import Foundation

/// **Projects PR4 — the AI project brief.** A short, family-voice read on where a project stands,
/// written by the `generateProjectBrief` Cloud Function from everything gathered on the project
/// (tasks, docs, quotes, contacts, notes). Mirrors ``DailyBriefing`` in shape: a `summary` paragraph
/// plus glanceable `highlights`, with an optional `decision` section for the "Help me decide" helper.
///
/// Decode-safe Codable so it can be **cached onto the `Project` document** (`Project.brief`) and
/// round-trip through the normal project load — no separate Firestore read path needed. Every field
/// tolerates a missing/partial payload so an older or half-written brief still resolves.
public struct ProjectBrief: Codable, Equatable, Sendable {
    /// The main paragraph — where things stand, in warm first-name voice.
    public var summary: String
    /// A few glanceable bullet points (next moves, watch-outs).
    public var highlights: [String]
    /// The decision helper's read — pros/cons / a recommendation — populated when the brief was
    /// generated with a decision focus. `nil` for a plain brief.
    public var decision: String?
    /// When this brief was generated (server clock), for the "updated 2h ago" footnote.
    public var generatedAt: Date?

    public init(summary: String, highlights: [String] = [], decision: String? = nil, generatedAt: Date? = nil) {
        self.summary = summary
        self.highlights = highlights
        self.decision = decision
        self.generatedAt = generatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        highlights = (try c.decodeIfPresent([String].self, forKey: .highlights) ?? []).filter { !$0.isEmpty }
        decision = try c.decodeIfPresent(String.self, forKey: .decision)
        // Accept either a Firestore Timestamp-decoded Date or an epoch number, best-effort.
        if let date = try? c.decodeIfPresent(Date.self, forKey: .generatedAt) {
            generatedAt = date
        } else if let epoch = try? c.decodeIfPresent(Double.self, forKey: .generatedAt) {
            generatedAt = Date(timeIntervalSince1970: epoch)
        } else {
            generatedAt = nil
        }
    }

    /// A brief is worth showing once it has a summary (highlights/decision are optional extras).
    public var hasContent: Bool { !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
