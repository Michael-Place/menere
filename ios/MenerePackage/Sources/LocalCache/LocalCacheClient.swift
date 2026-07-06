import Dependencies
import DependenciesMacros
import FamilyDomain
import Foundation
import GRDB
import OSLog
import SQLiteData

/// H2 — the offline-first local cache seam.
///
/// A thin, dependency-injectable façade over the SQLite mirror (``LocalCacheDatabase``). Features
/// read the cache **synchronously** for an instant first paint, subscribe to an observation stream so
/// later writes reactively update the UI, and write-through fresh Firestore data. The cache is a pure
/// mirror: it is never the source of truth (Firestore is), so it is always safe to drop and rebuild.
///
/// Pilot scope (this wave): `careItems` only. The shape generalizes — documents / memories / lists
/// come next by adding their own record + the same three verbs.
@DependencyClient
public struct LocalCacheClient: Sendable {
    /// Provision + migrate the on-disk DB once. Idempotent; call it before the first read (cheap after
    /// the first call). Safe to call on every screen appearance.
    public var bootstrap: @Sendable () -> Void

    /// Instant, synchronous snapshot of a household's care items from SQLite (empty on a cold cache).
    /// This is the cold-navigation fast path: no `await`, no network — the list paints this frame.
    public var careItems: @Sendable (_ hid: String) -> [CareItem] = { _ in [] }

    /// Write-through: replace a household's cached care items with `items` (upsert present, delete
    /// missing). Called after a Firestore read so the cache stays fresh and reflects deletions.
    public var upsertCareItems: @Sendable (_ hid: String, _ items: [CareItem]) -> Void

    /// A reactive stream of a household's care items — emits the current snapshot immediately, then a
    /// fresh array on every write (GRDB `ValueObservation`). Drives live UI updates after the
    /// background Firestore refresh upserts.
    public var observeCareItems: @Sendable (_ hid: String) -> AsyncStream<[CareItem]> = { _ in .never }
}

extension LocalCacheClient: DependencyKey {
    private static let logger = Logger(subsystem: "menere", category: "LocalCache")

    public static var liveValue: LocalCacheClient {
        LocalCacheClient(
            bootstrap: {
                LocalCacheDatabase.bootstrap()
            },
            careItems: { hid in
                guard let writer = LocalCacheDatabase.writer else { return [] }
                return (try? writer.read { db in
                    try CareItemRecord.where { $0.hid.eq(hid) }.fetchAll(db)
                })?.map(\.careItem) ?? []
            },
            upsertCareItems: { hid, items in
                guard let writer = LocalCacheDatabase.writer else { return }
                do {
                    try writer.write { db in
                        let incoming = Set(items.map(\.id))
                        let existing = try CareItemRecord.where { $0.hid.eq(hid) }.fetchAll(db).map(\.id)
                        let stale = existing.filter { !incoming.contains($0) }
                        if !stale.isEmpty {
                            try CareItemRecord.where { $0.id.in(stale) }.delete().execute(db)
                        }
                        for item in items {
                            try CareItemRecord.upsert { CareItemRecord(item, hid: hid) }.execute(db)
                        }
                    }
                } catch {
                    logger.error("upsertCareItems failed: \(error.localizedDescription, privacy: .public)")
                }
            },
            observeCareItems: { hid in
                guard let writer = LocalCacheDatabase.writer else { return .never }
                let observation = ValueObservation.tracking { db in
                    try CareItemRecord.where { $0.hid.eq(hid) }.fetchAll(db)
                }
                return AsyncStream { continuation in
                    let task = Task {
                        do {
                            for try await records in observation.values(in: writer) {
                                continuation.yield(records.map(\.careItem))
                            }
                            continuation.finish()
                        } catch {
                            logger.error("observeCareItems ended: \(error.localizedDescription, privacy: .public)")
                            continuation.finish()
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )
    }

    /// Tests/previews get a no-op cache (the Firestore path is exercised directly). Explicit no-ops
    /// (not the `@DependencyClient` unimplemented defaults) so features that touch the cache in tests
    /// don't report spurious failures.
    public static let testValue = LocalCacheClient(
        bootstrap: {},
        careItems: { _ in [] },
        upsertCareItems: { _, _ in },
        observeCareItems: { _ in .never }
    )
    public static let previewValue = LocalCacheClient(
        bootstrap: {},
        careItems: { _ in [] },
        upsertCareItems: { _, _ in },
        observeCareItems: { _ in .never }
    )
}

public extension DependencyValues {
    /// The H2 local SQLite mirror.
    var localCache: LocalCacheClient {
        get { self[LocalCacheClient.self] }
        set { self[LocalCacheClient.self] = newValue }
    }
}
