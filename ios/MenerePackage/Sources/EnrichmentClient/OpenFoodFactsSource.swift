import Foundation
import WineDomain

/// Open Food Facts product lookup by barcode. OFF is a crowd-sourced, free, on-device-friendly source;
/// wine coverage is thin and JSON shapes vary, so every field is optional and parsing is deliberately
/// tolerant — we only contribute what's reliably present.
///
/// Requires a descriptive `User-Agent` (OFF rejects/throttles anonymous clients).
enum OpenFoodFactsSource {
    /// OFF requires a User-Agent identifying the app + a contact.
    static let userAgent = "Menere/1.0 (iOS wine app; contact: support@menere.app)"

    static let confidence = 0.6

    /// Look up `barcode` and map whatever wine fields are present into a `SourceContribution`.
    /// Returns nil when the barcode is empty, the product is unknown (`status != 1`), or nothing
    /// usable could be parsed. Networking errors propagate (the client wraps this in a timeout/catch).
    static func fetch(
        barcode: String,
        session: URLSession = .shared
    ) async throws -> SourceContribution? {
        let trimmed = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // v2 first; fall back to v0 (older payload shape, same fields we read).
        for path in ["api/v2", "api/v0"] {
            guard let url = URL(string: "https://world.openfoodfacts.org/\(path)/product/\(trimmed).json") else {
                continue
            }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }

            guard
                let decoded = try? JSONDecoder().decode(OFFResponse.self, from: data),
                decoded.status == 1,
                let product = decoded.product
            else { continue }

            if let contribution = map(product) { return contribution }
        }
        return nil
    }

    /// Map a tolerant OFF product into a contribution. Only sets fields actually found.
    static func map(_ product: OFFProduct) -> SourceContribution? {
        var contribution = SourceContribution(fieldSource: .openFoodFacts, confidence: confidence)

        // brands: "Campos de Solana, Único" → first brand is the closest thing to a producer.
        if let brands = product.brands?.trimmingCharacters(in: .whitespacesAndNewlines), !brands.isEmpty {
            let first = brands.split(separator: ",").first.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let first, !first.isEmpty { contribution.producer = first }
        }

        if let name = product.product_name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            contribution.name = name
        }

        if let type = wineType(from: product.categories_tags ?? []) {
            contribution.type = type
        }

        // Alcohol by volume, when present in nutriments.
        if let abv = product.nutriments?.alcohol, abv > 0, abv < 100 {
            contribution.abv = abv
        }

        return contribution.isEmpty ? nil : contribution
    }

    /// Derive a `WineType` from OFF `categories_tags` (e.g. `en:red-wines`). Most specific wins.
    static func wineType(from tags: [String]) -> WineType? {
        let lowered = Set(tags.map { $0.lowercased() })
        func has(_ needle: String) -> Bool { lowered.contains { $0.contains(needle) } }

        if has("sparkling-wine") { return .sparkling }
        if has("fortified-wine") { return .fortified }
        if has("dessert-wine") { return .dessert }
        if has("rose-wine") || has("rosé-wine") { return .rose }
        if has("red-wine") { return .red }
        if has("white-wine") { return .white }
        return nil
    }
}

// MARK: - Tolerant decoding

/// All optional / forgiving — OFF returns wildly inconsistent payloads; never fail the whole decode on
/// an unexpected shape.
struct OFFResponse: Decodable {
    var status: Int?
    var product: OFFProduct?
}

struct OFFProduct: Decodable {
    var product_name: String?
    var brands: String?
    var categories_tags: [String]?
    var nutriments: OFFNutriments?
}

struct OFFNutriments: Decodable {
    /// `% vol`. OFF sometimes serializes numbers as strings, so decode either.
    var alcohol: Double?

    enum CodingKeys: String, CodingKey { case alcohol }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Double.self, forKey: .alcohol) {
            alcohol = value
        } else if let string = try? container.decode(String.self, forKey: .alcohol) {
            alcohol = Double(string.trimmingCharacters(in: .whitespaces))
        } else {
            alcohol = nil
        }
    }
}
