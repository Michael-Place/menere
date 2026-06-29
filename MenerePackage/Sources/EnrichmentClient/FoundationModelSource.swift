// Weak-linked for the same reason as IdentifyClient: the `@Generable` macro (built against the iOS 27
// SDK) emits *eager* references to iOS 27-only Foundation Models symbols (e.g. the `Generable`
// `promptRepresentation` witness). With our iOS 26 deployment target those are strong-linked and the
// app fails to launch on iOS 26 with a dyld "Symbol not found". Weak linking resolves the missing
// symbols to null at launch; the `#available(iOS 27)` guards ensure we never call them on iOS 26, and
// the iOS 26 path only touches text APIs that exist on iOS 26. See docs/identify-engine.md.
@_weakLinked import FoundationModels
import Foundation
import OSLog
import WineDomain

/// Diagnostics for the on-device AI gap-fill: which model path ran and how it degraded. Capture with:
/// `xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.mplace.menere"'`.
private let enrichmentFMLog = Logger(subsystem: "com.mplace.menere", category: "enrichment.fm")

/// The four *descriptive* enrichment fields the on-device model is allowed to write. Identity and hard
/// facts (producer/name/vintage/region/grapes/type/abv) are NEVER produced here — those come from the
/// label OCR and the authoritative open-data sources. Used for grounded gap detection + output masking.
enum DescriptiveField: String, CaseIterable, Sendable {
    case summary
    case drinkingWindow
    case foodPairings
    case producerNote
}

/// On-device AI gap-fill via Apple Foundation Models — the **lowest-authority** enrichment source
/// (`fieldSource: .llm`, confidence 0.4). It runs as a *second pass* over the wine that the
/// authoritative sources have already enriched, and only ever writes the four descriptive narrative
/// fields (`summary`, `drinkingWindow`, `foodPairings`, `producerNote`), and only where they are still
/// empty.
///
/// Grounding & safety: the prompt is grounded strictly in the resolved wine identity and is forbidden
/// from inventing verifiable hard facts (scores/ratings, ABV, awards, critic quotes, prices). The merge
/// engine is the backstop — `llm` is outranked by every other source and is rejected outright for hard
/// facts like `abv` — but we also gap-detect up front so we never spend a generation on a filled field.
///
/// Availability: iOS 26 uses the on-device `SystemLanguageModel`; iOS 27 may escalate to the keyless,
/// free, private `PrivateCloudComputeLanguageModel` for richer output, falling back to the system model.
/// Every path is guarded by the model's own availability check and degrades to `nil` on
/// unavailable / `ModelManagerError` / any thrown error, so enrichment (and the scan) always succeed.
enum FoundationModelSource {
    /// `llm` is an estimate, not a verified fact — kept deliberately low.
    static let confidence = 0.4

    /// System instructions shared by every model path: ground strictly, never fabricate hard facts.
    static let instructions = """
    You are a sommelier writing brief, factual descriptive notes about one specific wine. Ground every \
    statement strictly in the wine identity you are given (producer, name, vintage, region, grapes, \
    type). Do NOT invent or assert verifiable hard facts: no numeric scores or ratings, no alcohol / \
    ABV, no awards or medals, no specific critic quotes, no prices, no vineyard or harvest statistics. \
    If a detail is genuinely unknown from the given identity, leave that field empty rather than \
    guessing. Be concise, and write only the fields you are explicitly asked to fill.
    """

    // MARK: - Live entry point

    /// Generate the still-empty descriptive fields for `wine`. Returns a `.llm` `SourceContribution`
    /// carrying ONLY the requested (still-empty) fields, or `nil` when there are no gaps, the model is
    /// unavailable, or generation fails. Never throws — any failure collapses to `nil`.
    static func fetch(wine: Wine) async -> SourceContribution? {
        let fields = emptyDescriptiveFields(of: wine)
        guard !fields.isEmpty else {
            enrichmentFMLog.notice("enrichment.fm: no empty descriptive fields → skip generation")
            return nil
        }

        let prompt = buildPrompt(identity: identitySummary(wine), fields: fields)

        // iOS 27: prefer Private Cloud Compute (keyless / free / private) for richer output; fall back
        // to the on-device system model if PCC is unavailable or errors.
        if #available(iOS 27.0, *) {
            if let contribution = await generateWithPrivateCloudCompute(prompt: prompt, fields: fields) {
                return contribution
            }
        }
        return await generateWithSystemModel(prompt: prompt, fields: fields)
    }

    // MARK: - Pure helpers (no Foundation Models — unit-tested offline)

    /// Which of the four descriptive enrichment fields are still empty on `wine`. A field already
    /// filled by an authoritative source (recorded on `enrichment`) is NOT targeted.
    static func emptyDescriptiveFields(of wine: Wine) -> Set<DescriptiveField> {
        let enrichment = wine.enrichment
        var empty: Set<DescriptiveField> = []
        if isBlank(enrichment?.summary) { empty.insert(.summary) }
        if isBlank(enrichment?.drinkingWindow) { empty.insert(.drinkingWindow) }
        if (enrichment?.foodPairings ?? []).isEmpty { empty.insert(.foodPairings) }
        if isBlank(enrichment?.producerNote) { empty.insert(.producerNote) }
        return empty
    }

    /// Build an `llm` contribution from a generated draft, keeping ONLY the requested fields (so the
    /// model can never widen its blast radius beyond the detected gaps). Returns `nil` if, after
    /// cleaning + masking, nothing usable remains. The contribution carries *only* descriptive fields —
    /// never identity or hard facts.
    static func contribution(
        from draft: WineEnrichmentDraft,
        fields: Set<DescriptiveField>
    ) -> SourceContribution? {
        var contribution = SourceContribution(fieldSource: .llm, confidence: confidence)

        if fields.contains(.summary) { contribution.summary = cleaned(draft.summary) }
        if fields.contains(.drinkingWindow) { contribution.drinkingWindow = cleaned(draft.drinkingWindow) }
        if fields.contains(.producerNote) { contribution.producerNote = cleaned(draft.producerNote) }
        if fields.contains(.foodPairings) {
            let pairings = draft.foodPairings.compactMap(cleaned)
            if !pairings.isEmpty { contribution.foodPairings = Array(pairings.prefix(5)) }
        }

        return contribution.isEmpty ? nil : contribution
    }

    /// A compact, grounded identity block fed to the model. Only known fields are included, so the model
    /// is never handed (and can't echo back) a value the wine doesn't actually have.
    static func identitySummary(_ wine: Wine) -> String {
        var lines: [String] = []
        if !wine.producer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Producer: \(wine.producer)")
        }
        if let name = cleaned(wine.name) { lines.append("Name: \(name)") }
        if let vintage = wine.vintage { lines.append("Vintage: \(vintage)") } else { lines.append("Vintage: non-vintage") }
        if let region = regionPhrase(wine.region) { lines.append("Region: \(region)") }
        if !wine.grapes.isEmpty { lines.append("Grapes: \(wine.grapes.joined(separator: ", "))") }
        if wine.type != .other { lines.append("Type: \(wine.type.rawValue)") }
        return lines.joined(separator: "\n")
    }

    /// The per-call prompt: the grounded identity plus a bullet list of ONLY the fields to fill.
    static func buildPrompt(identity: String, fields: Set<DescriptiveField>) -> String {
        // Deterministic, human-readable order so the prompt is stable across runs.
        let bullets = DescriptiveField.allCases
            .filter { fields.contains($0) }
            .map { "- \(fieldInstruction($0))" }
            .joined(separator: "\n")
        return """
        Wine identity:
        \(identity)

        Fill ONLY these fields, and leave every other field empty:
        \(bullets)
        """
    }

    /// Per-field guidance baked into the prompt (mirrors the `@Guide` descriptions).
    private static func fieldInstruction(_ field: DescriptiveField) -> String {
        switch field {
        case .summary:
            return "summary: a concise 1–2 sentence description of this wine's style and character."
        case .drinkingWindow:
            return "drinkingWindow: a short human phrase, e.g. \"Drink now through 2030\"."
        case .foodPairings:
            return "foodPairings: a short list of 3–5 classic food pairings."
        case .producerNote:
            return "producerNote: one sentence about the producer."
        }
    }

    // MARK: - Model paths

    /// On-device `SystemLanguageModel` text generation (iOS 26+). Degrades to `nil` when the model is
    /// unavailable (no Apple Intelligence / not provisioned) or generation throws.
    private static func generateWithSystemModel(
        prompt: String,
        fields: Set<DescriptiveField>
    ) async -> SourceContribution? {
        let model = SystemLanguageModel.default
        enrichmentFMLog.notice("enrichment.fm: engine=SystemLanguageModel(iOS26) availability=\(String(describing: model.availability), privacy: .public)")
        guard case .available = model.availability else {
            enrichmentFMLog.notice("enrichment.fm: SystemLanguageModel unavailable → no llm contribution")
            return nil
        }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: WineEnrichmentDraft.self)
            let contribution = contribution(from: response.content, fields: fields)
            enrichmentFMLog.notice("enrichment.fm: SystemLanguageModel filled \(fields.count, privacy: .public) gap(s), contributed=\(contribution != nil ? "yes" : "no", privacy: .public)")
            return contribution
        } catch {
            enrichmentFMLog.error("enrichment.fm: SystemLanguageModel failed (\(String(describing: error), privacy: .public)) → no llm contribution")
            return nil
        }
    }

    /// iOS 27 escalation to `PrivateCloudComputeLanguageModel` (keyless / free / private). Degrades to
    /// `nil` (and the caller then tries the on-device system model) when PCC is unavailable or errors.
    @available(iOS 27.0, *)
    private static func generateWithPrivateCloudCompute(
        prompt: String,
        fields: Set<DescriptiveField>
    ) async -> SourceContribution? {
        let model = PrivateCloudComputeLanguageModel()
        enrichmentFMLog.notice("enrichment.fm: engine=PrivateCloudCompute(iOS27) availability=\(String(describing: model.availability), privacy: .public)")
        guard case .available = model.availability else {
            enrichmentFMLog.notice("enrichment.fm: PrivateCloudCompute unavailable → trying on-device system model")
            return nil
        }
        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(to: prompt, generating: WineEnrichmentDraft.self)
            let contribution = contribution(from: response.content, fields: fields)
            enrichmentFMLog.notice("enrichment.fm: PrivateCloudCompute filled \(fields.count, privacy: .public) gap(s), contributed=\(contribution != nil ? "yes" : "no", privacy: .public)")
            return contribution
        } catch {
            enrichmentFMLog.error("enrichment.fm: PrivateCloudCompute failed (\(String(describing: error), privacy: .public)) → trying on-device system model")
            return nil
        }
    }
}

// MARK: - Generable draft

/// The descriptive fields the on-device model fills in one guided-generation pass. Scoped to ONLY the
/// four narrative fields — there is deliberately no producer/vintage/region/abv/etc. here, so the model
/// structurally cannot emit identity or hard facts. `@Guide` descriptions constrain each field's shape.
@Generable
struct WineEnrichmentDraft {
    @Guide(description: "A concise 1–2 sentence description of the wine's style and character, grounded only in the given identity. No scores, ABV, awards, or prices. Nil if unknown.")
    var summary: String?

    @Guide(description: "A short human-readable drinking-window phrase such as \"Drink now through 2030\" or \"Best enjoyed young\". Nil if unknown.")
    var drinkingWindow: String?

    @Guide(description: "A short list of 3–5 classic food pairings for this wine. Empty if unknown.")
    var foodPairings: [String]

    @Guide(description: "One sentence about the producer, grounded only in the given identity. No awards, scores, or invented history. Nil if unknown.")
    var producerNote: String?
}

// MARK: - Small helpers

/// Trim a string; return nil if it is missing or blank.
private func cleaned(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

/// True when a string is missing or only whitespace.
private func isBlank(_ value: String?) -> Bool { cleaned(value) == nil }

/// A human region phrase ("Napa Valley, United States") from the most specific known parts, or nil.
private func regionPhrase(_ region: Region?) -> String? {
    guard let region else { return nil }
    let parts = [region.appellation, region.subregion, region.region, region.country]
        .compactMap { cleaned($0) }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
}
