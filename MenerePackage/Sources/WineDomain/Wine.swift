import Foundation

/// A wine *bottling* — the abstract product (one per producer + cuvée + vintage), independent of any
/// physical bottle you own. Lives in the shared `wines` catalog, keyed by a canonical key so the same
/// wine logged by different people resolves to one record. Grows organically as users scan/log.
public struct Wine: Codable, Equatable, Identifiable, Sendable {
    /// Canonical key — also the Firestore document id. See `Wine.canonicalKey(...)`.
    public let id: String
    public var producer: String
    /// Cuvée / bottling name (e.g. "Reserva", "Clos du Marquis"). Nil for simple varietal bottlings.
    public var name: String?
    /// Vintage year; nil = non-vintage (NV).
    public var vintage: Int?
    public var region: Region?
    public var grapes: [String]
    public var type: WineType
    /// Alcohol by volume, percent (e.g. 13.5).
    public var abv: Double?
    public var labelImageURL: URL?
    /// Source-derived facts + per-field provenance (AI/open data). Nil until enriched.
    public var enrichment: Enrichment?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        producer: String,
        name: String? = nil,
        vintage: Int? = nil,
        region: Region? = nil,
        grapes: [String] = [],
        type: WineType = .other,
        abv: Double? = nil,
        labelImageURL: URL? = nil,
        enrichment: Enrichment? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.producer = producer
        self.name = name
        self.vintage = vintage
        self.region = region
        self.grapes = grapes
        self.type = type
        self.abv = abv
        self.labelImageURL = labelImageURL
        self.enrichment = enrichment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Convenience init that derives the canonical `id` from producer/name/vintage.
    public init(
        producer: String,
        name: String? = nil,
        vintage: Int? = nil,
        region: Region? = nil,
        grapes: [String] = [],
        type: WineType = .other,
        abv: Double? = nil,
        labelImageURL: URL? = nil,
        enrichment: Enrichment? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.init(
            id: Wine.canonicalKey(producer: producer, name: name, vintage: vintage),
            producer: producer,
            name: name,
            vintage: vintage,
            region: region,
            grapes: grapes,
            type: type,
            abv: abv,
            labelImageURL: labelImageURL,
            enrichment: enrichment,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public extension Wine {
    /// Stable identity for a bottling = normalized(producer) + normalized(name) + vintage.
    /// The recurring hard problem in wine apps is dedup; commit to this key everywhere.
    /// Produces a Firestore-safe id (lowercased, diacritics stripped, non-alphanumerics → '-').
    static func canonicalKey(producer: String, name: String?, vintage: Int?) -> String {
        func normalize(_ string: String) -> String {
            string
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
        }
        let parts = [
            normalize(producer),
            name.map(normalize) ?? "",
            vintage.map(String.init) ?? "nv",
        ].filter { !$0.isEmpty }
        return parts.joined(separator: "_")
    }
}
