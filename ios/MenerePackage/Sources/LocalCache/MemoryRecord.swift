import Foundation
import FamilyDomain
import SQLiteData

/// H2-ext — the local SQLite mirror of a ``FamilyDomain/Memory`` (the scrapbook timeline).
///
/// One row per memory, scoped by `hid`. Like ``DocumentRecord``, a `Memory` is a rich, whole-read/write
/// `Codable` value, so the entire struct is stored as one JSON `TEXT` blob (`json`) and only the queried
/// columns are broken out: `id` (pk), `hid` (scope), and `date` (epoch seconds `REAL`) — the timeline's
/// newest-first sort key.
@Table("memoryRecords")
public struct MemoryRecord: Identifiable, Equatable, Sendable {
    /// Primary key — the Memory's own id (a globally-unique UUID).
    public var id: String
    /// Household scope. Every read filters on this; every write stamps it.
    public var hid: String
    /// Epoch seconds — the timeline sort key (the day the memory happened).
    public var date: Double
    /// The whole ``FamilyDomain/Memory`` encoded as JSON.
    public var json: String
}

// MARK: - Mapping Memory <-> MemoryRecord

extension MemoryRecord {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Build a cache row from a domain ``Memory`` for a given household.
    public init?(_ memory: Memory, hid: String) {
        guard let data = try? Self.encoder.encode(memory) else { return nil }
        self.init(
            id: memory.id,
            hid: hid,
            date: memory.date.timeIntervalSince1970,
            json: String(decoding: data, as: UTF8.self)
        )
    }

    /// Rehydrate the domain ``Memory`` from a cache row (nil if the blob can't be decoded).
    public var memory: Memory? {
        try? Self.decoder.decode(Memory.self, from: Data(json.utf8))
    }
}
