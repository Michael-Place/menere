import Foundation
import FamilyDomain

/// The Family-Brain document ranking, replicated for the `search_brain` agent tool (the original
/// lives in `DocsFeature.BrainSearchReducer`, which is a UI module we don't want to depend on).
/// Case/diacritic-insensitive, tiered: title/vendor (0) > tags/summary (1) > extracted text (2),
/// then newest-first within a tier.
enum BrainRanking {
    static let recentLimit = 12

    static func results(documents: [Document], query: String, type: DocumentType?) -> [Document] {
        let filtered = type.map { t in documents.filter { $0.type == t } } ?? documents
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            // Empty query → the N most recent (assume caller passes newest-first, but sort to be safe).
            return filtered.sorted { $0.createdAt > $1.createdAt }.prefix(recentLimit).map { $0 }
        }

        struct Ranked { let doc: Document; let tier: Int }
        var ranked: [Ranked] = []
        for doc in filtered {
            let inTitle = contains(doc.title, trimmed)
            let inVendor = contains(doc.vendor, trimmed)
            let inTags = doc.tags.contains { contains($0, trimmed) }
            let inSummary = contains(doc.summary, trimmed)
            let inText = contains(doc.extractedText, trimmed)

            let tier: Int
            if inTitle || inVendor { tier = 0 }
            else if inTags || inSummary { tier = 1 }
            else if inText { tier = 2 }
            else { continue }
            ranked.append(Ranked(doc: doc, tier: tier))
        }
        return ranked
            .sorted { a, b in a.tier != b.tier ? a.tier < b.tier : a.doc.createdAt > b.doc.createdAt }
            .map(\.doc)
    }

    private static func contains(_ haystack: String?, _ needle: String) -> Bool {
        guard let haystack else { return false }
        return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
