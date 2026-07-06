import Foundation
import FamilyDomain
import SQLiteData

/// H2-ext — the local SQLite mirror of a ``FamilyDomain/FamilyList`` header row (the Lists screen).
///
/// One row per list, scoped by `hid`. This mirrors only the `FamilyList` container (title / icon / color
/// / type) — the fast paint the Lists screen needs; a list's *items* live in their own subcollection and
/// are loaded on drill-in (ListDetailFeature), so they're intentionally out of this cache. Like the other
/// H2-ext records, the whole (whole-read/write) `Codable` struct is stored as one JSON `TEXT` blob, with
/// `id` (pk), `hid` (scope), and `createdAt` (epoch seconds `REAL`) broken out for querying / ordering.
@Table("listRecords")
public struct ListRecord: Identifiable, Equatable, Sendable {
    /// Primary key — the FamilyList's own id (a globally-unique UUID).
    public var id: String
    /// Household scope. Every read filters on this; every write stamps it.
    public var hid: String
    /// Epoch seconds — the creation sort key (Lists renders oldest-first).
    public var createdAt: Double
    /// The whole ``FamilyDomain/FamilyList`` encoded as JSON.
    public var json: String
}

// MARK: - Mapping FamilyList <-> ListRecord

extension ListRecord {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Build a cache row from a domain ``FamilyList`` for a given household.
    public init?(_ list: FamilyList, hid: String) {
        guard let data = try? Self.encoder.encode(list) else { return nil }
        self.init(
            id: list.id,
            hid: hid,
            createdAt: list.createdAt.timeIntervalSince1970,
            json: String(decoding: data, as: UTF8.self)
        )
    }

    /// Rehydrate the domain ``FamilyList`` from a cache row (nil if the blob can't be decoded).
    public var list: FamilyList? {
        try? Self.decoder.decode(FamilyList.self, from: Data(json.utf8))
    }
}
