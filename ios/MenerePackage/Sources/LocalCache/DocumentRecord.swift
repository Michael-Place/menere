import Foundation
import FamilyDomain
import SQLiteData

/// H2-ext — the local SQLite mirror of a ``FamilyDomain/Document`` (Family Brain).
///
/// One row per document, scoped by `hid`. A `Document` is a rich, evolving `Codable` value that the app
/// only ever reads / writes **whole** (never queried column-wise), so — unlike ``CareItemRecord`` which
/// mirrors each field — the entire struct is stored as one JSON `TEXT` blob (`json`). Only the columns
/// the cache actually queries on are broken out: `id` (pk), `hid` (scope filter), and `createdAt`
/// (epoch seconds `REAL`) so the newest-first paint can `ORDER BY … DESC` + `LIMIT` for pagination.
///
/// Storing the whole struct as JSON makes the mapping trivial and future-proof: as `Document` grows new
/// decode-safe fields, the mirror carries them for free with no migration.
@Table("documentRecords")
public struct DocumentRecord: Identifiable, Equatable, Sendable {
    /// Primary key — the Document's own id (a globally-unique UUID).
    public var id: String
    /// Household scope. Every read filters on this; every write stamps it.
    public var hid: String
    /// Epoch seconds — the newest-first sort key (matches DocsFeature's `createdAt >` ordering).
    public var createdAt: Double
    /// The whole ``FamilyDomain/Document`` encoded as JSON.
    public var json: String
}

// MARK: - Mapping Document <-> DocumentRecord

extension DocumentRecord {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Build a cache row from a domain ``Document`` for a given household. Returns nil only if the
    /// (always-`Codable`) struct fails to encode, which in practice never happens.
    public init?(_ doc: FamilyDomain.Document, hid: String) {
        guard let data = try? Self.encoder.encode(doc) else { return nil }
        self.init(
            id: doc.id,
            hid: hid,
            createdAt: doc.createdAt.timeIntervalSince1970,
            json: String(decoding: data, as: UTF8.self)
        )
    }

    /// Rehydrate the domain ``Document`` from a cache row (nil if the blob can't be decoded).
    public var document: FamilyDomain.Document? {
        try? Self.decoder.decode(FamilyDomain.Document.self, from: Data(json.utf8))
    }
}
