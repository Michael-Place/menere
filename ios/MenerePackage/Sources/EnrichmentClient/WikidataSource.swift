import Foundation
import WineDomain

/// Wikidata taxonomy normalization, scoped to **grape → wine color**. For each grape on the candidate
/// we resolve its Wikidata item (via the entity-search MWAPI service, which is diacritic-tolerant — so
/// "Carmenere" still matches "Carménère") and read its *fruit color* (property P11220). Black/blue
/// grapes ⇒ `.red`, white/green/yellow grapes ⇒ `.white`. This deliberately does NOT attempt producer
/// entity-resolution (deferred).
///
/// Requires a descriptive `User-Agent` (WDQS rejects anonymous clients).
enum WikidataSource {
    static let userAgent = "Menere/1.0 (iOS wine app; contact: support@menere.app)"
    static let endpoint = "https://query.wikidata.org/sparql"
    static let confidence = 0.7

    /// Resolve a `WineType` from the candidate's grapes. Returns nil when there are no grapes, the
    /// query yields no fruit-color binding, or the colors are ambiguous (mixed red+white).
    static func fetch(
        grapes: [String],
        session: URLSession = .shared
    ) async throws -> SourceContribution? {
        let names = grapes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstGrape = names.first else { return nil }

        // One SPARQL round-trip per (first) grape keeps it cheap; the first grape determines the wine's
        // color for varietal-led bottlings, which is the common case.
        guard let colors = try await fruitColors(grape: firstGrape, session: session), !colors.isEmpty else {
            return nil
        }

        guard let type = wineType(fromColorLabels: colors) else { return nil }

        var contribution = SourceContribution(fieldSource: .wikidata, confidence: confidence)
        contribution.type = type
        return contribution
    }

    /// Run the entity-search + P11220 SPARQL and return the lowercased fruit-color labels found.
    static func fruitColors(
        grape: String,
        session: URLSession = .shared
    ) async throws -> [String]? {
        let query = """
        SELECT ?item ?colorLabel WHERE {
          SERVICE wikibase:mwapi {
            bd:serviceParam wikibase:api "EntitySearch" .
            bd:serviceParam wikibase:endpoint "www.wikidata.org" .
            bd:serviceParam mwapi:search "\(sparqlEscape(grape))" .
            bd:serviceParam mwapi:language "en" .
            ?item wikibase:apiOutputItem mwapi:item .
          }
          ?item wdt:P11220 ?color .
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        }
        LIMIT 10
        """

        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "query", value: query),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }

        guard let decoded = try? JSONDecoder().decode(SPARQLResponse.self, from: data) else { return nil }
        let colors = decoded.results.bindings.compactMap { $0.colorLabel?.value.lowercased() }
        return colors
    }

    /// Map Wikidata fruit-color labels to a `WineType`. Black/blue ⇒ red, white/green/yellow ⇒ white.
    /// Ambiguous (both present) ⇒ nil rather than guessing.
    static func wineType(fromColorLabels labels: [String]) -> WineType? {
        let red = labels.contains { $0.contains("black") || $0.contains("blue") }
        let white = labels.contains {
            $0.contains("white") || $0.contains("green") || $0.contains("yellow")
        }
        switch (red, white) {
        case (true, false): return .red
        case (false, true): return .white
        default: return nil
        }
    }

    /// Escape a user-supplied grape name for safe inclusion in the SPARQL string literal.
    static func sparqlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

// MARK: - SPARQL JSON results

struct SPARQLResponse: Decodable {
    struct Results: Decodable { var bindings: [Binding] }
    struct Binding: Decodable { var colorLabel: Value? }
    struct Value: Decodable { var value: String }
    var results: Results
}
