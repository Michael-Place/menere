import Foundation
import WineDomain

/// TTB COLA (Certificate of Label Approval) class/type lookup, via the `ttbColaLookup` Cloud Function
/// (a v2 HTTPS callable in us-central1). The function POSTs the public TTB COLA registry search, parses
/// the results table, and returns the federally-approved *class/type* string for a wine
/// (e.g. "TABLE RED WINE", "SPARKLING GRAPE WINE", "DESSERT /PORT/SHERRY/(COOKING) WINE").
///
/// We map that class/type to a `WineType` and contribute *only* `type` — the class/type is label-derived
/// and authoritative for color/style, but it carries no other fields we could fill without fabricating.
///
/// Fails gracefully: if the function is undeployed/unreachable or returns `found:false`, this returns
/// nil and the rest of enrichment proceeds unaffected.
enum TTBColaSource {
    /// Standard v2 callable endpoint for `ttbColaLookup` (project `menere`, region us-central1).
    static let endpoint = "https://us-central1-menere.cloudfunctions.net/ttbColaLookup"

    /// Authoritative open-data source — same tier as Open Food Facts in the merge engine.
    static let confidence = 0.8

    /// Look up the COLA class/type for `producer` (the brand on the label) and map it to a `WineType`.
    /// Returns nil when there's no producer to search, the function is unreachable, or no class/type maps.
    static func fetch(
        producer: String,
        name: String? = nil,
        session: URLSession = .shared
    ) async throws -> SourceContribution? {
        let brand = producer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brand.isEmpty else { return nil }

        guard let classType = try await lookupClassType(producer: brand, session: session) else {
            return nil
        }
        guard let type = wineType(fromClassType: classType) else { return nil }

        var contribution = SourceContribution(fieldSource: .ttbCola, confidence: confidence)
        contribution.type = type
        return contribution
    }

    /// Invoke the callable and return its `classType` string, or nil on any non-hit / transport error.
    static func lookupClassType(
        producer: String,
        session: URLSession = .shared
    ) async throws -> String? {
        guard let url = URL(string: endpoint) else { return nil }

        // Callable envelope: the function reads `request.data.{productName,brand}`. We search by the
        // brand (producer) and pass it as `brand` too so the function can prefer brand-matching rows.
        let payload = CallableRequest(data: .init(productName: producer, brand: producer))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }

        guard
            let decoded = try? JSONDecoder().decode(CallableResponse.self, from: data),
            decoded.result.found,
            let classType = decoded.result.classType?.trimmingCharacters(in: .whitespacesAndNewlines),
            !classType.isEmpty
        else { return nil }

        return classType
    }

    /// Map a TTB class/type description to a `WineType`. Style keywords (sparkling / fortified / dessert)
    /// are checked before plain color so combined categories like "DESSERT /PORT/SHERRY/(COOKING) WINE"
    /// resolve correctly. Generic classes ("TABLE WINE", "GRAPE WINE") with no color/style ⇒ nil.
    static func wineType(fromClassType classType: String) -> WineType? {
        let c = classType.uppercased()
        func has(_ needle: String) -> Bool { c.contains(needle) }

        if has("SPARKLING") || has("CHAMPAGNE") || has("CARBONATED") || has("CRACKLING") {
            return .sparkling
        }
        if has("PORT") || has("SHERRY") || has("MADEIRA") || has("MARSALA")
            || has("VERMOUTH") || has("FORTIFIED") {
            return .fortified
        }
        if has("DESSERT") { return .dessert }
        if has("ROSE") || has("ROSÉ") || has("BLUSH") || has("PINK") { return .rose }
        if has("RED") { return .red }
        if has("WHITE") { return .white }
        return nil
    }
}

// MARK: - Callable envelope

private struct CallableRequest: Encodable {
    struct Data: Encodable {
        var productName: String
        var brand: String
    }
    var data: Data
}

private struct CallableResponse: Decodable {
    struct Result: Decodable {
        var found: Bool
        var classType: String?
    }
    var result: Result
}
