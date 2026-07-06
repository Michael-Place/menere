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
/// Scope: `careItems` (H2 pilot) plus `documents` / `memories` / `lists` (H2-ext) — each the same three
/// verbs (synchronous read, write-through-with-delete-missing, reactive `observe…`). Documents' read /
/// observe take a `limit` so the paginated Brain paints just its first page fast.
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

    // MARK: - Documents (Family Brain) — H2-ext

    /// Instant, synchronous snapshot of a household's documents, newest-first, capped at `limit`
    /// (pagination-friendly — the Brain paints its first page instantly, then the full Firestore
    /// listener takes over). Empty on a cold cache.
    public var documents: @Sendable (_ hid: String, _ limit: Int) -> [FamilyDomain.Document] = { _, _ in [] }

    /// Write-through: replace a household's cached documents with `docs` (upsert present, delete missing).
    /// Called after the Firestore listener delivers so the cache stays fresh and reflects deletions.
    public var upsertDocuments: @Sendable (_ hid: String, _ docs: [FamilyDomain.Document]) -> Void

    /// A reactive stream of a household's documents, newest-first, capped at `limit`. Emits immediately,
    /// then on every write. The `limit` keeps the fast-paint cheap; DocsFeature's full Firestore listener
    /// remains the source of truth for search / Collections / the complete set.
    public var observeDocuments: @Sendable (_ hid: String, _ limit: Int) -> AsyncStream<[FamilyDomain.Document]> = { _, _ in .never }

    // MARK: - Memories — H2-ext

    /// Instant, synchronous snapshot of a household's memories, newest-first. Empty on a cold cache.
    public var memories: @Sendable (_ hid: String) -> [Memory] = { _ in [] }

    /// Write-through: replace a household's cached memories with `memories` (upsert present, delete
    /// missing).
    public var upsertMemories: @Sendable (_ hid: String, _ memories: [Memory]) -> Void

    /// A reactive stream of a household's memories, newest-first. Emits immediately, then on every write.
    public var observeMemories: @Sendable (_ hid: String) -> AsyncStream<[Memory]> = { _ in .never }

    // MARK: - Lists — H2-ext

    /// Instant, synchronous snapshot of a household's list headers, oldest-first (the Lists screen's
    /// order). Empty on a cold cache.
    public var lists: @Sendable (_ hid: String) -> [FamilyList] = { _ in [] }

    /// Write-through: replace a household's cached list headers with `lists` (upsert present, delete
    /// missing).
    public var upsertLists: @Sendable (_ hid: String, _ lists: [FamilyList]) -> Void

    /// A reactive stream of a household's list headers, oldest-first. Emits immediately, then on every
    /// write.
    public var observeLists: @Sendable (_ hid: String) -> AsyncStream<[FamilyList]> = { _ in .never }
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
            },

            // MARK: Documents (H2-ext)
            documents: { hid, limit in
                guard let writer = LocalCacheDatabase.writer else { return [] }
                return (try? writer.read { db in
                    try DocumentRecord
                        .where { $0.hid.eq(hid) }
                        .order { $0.createdAt.desc() }
                        .limit(limit)
                        .fetchAll(db)
                })?.compactMap(\.document) ?? []
            },
            upsertDocuments: { hid, docs in
                guard let writer = LocalCacheDatabase.writer else { return }
                do {
                    try writer.write { db in
                        let incoming = Set(docs.map(\.id))
                        let existing = try DocumentRecord.where { $0.hid.eq(hid) }.fetchAll(db).map(\.id)
                        let stale = existing.filter { !incoming.contains($0) }
                        if !stale.isEmpty {
                            try DocumentRecord.where { $0.id.in(stale) }.delete().execute(db)
                        }
                        for doc in docs {
                            if let record = DocumentRecord(doc, hid: hid) {
                                try DocumentRecord.upsert { record }.execute(db)
                            }
                        }
                    }
                } catch {
                    logger.error("upsertDocuments failed: \(error.localizedDescription, privacy: .public)")
                }
            },
            observeDocuments: { hid, limit in
                guard let writer = LocalCacheDatabase.writer else { return .never }
                let observation = ValueObservation.tracking { db in
                    try DocumentRecord
                        .where { $0.hid.eq(hid) }
                        .order { $0.createdAt.desc() }
                        .limit(limit)
                        .fetchAll(db)
                }
                return AsyncStream { continuation in
                    let task = Task {
                        do {
                            for try await records in observation.values(in: writer) {
                                continuation.yield(records.compactMap(\.document))
                            }
                            continuation.finish()
                        } catch {
                            logger.error("observeDocuments ended: \(error.localizedDescription, privacy: .public)")
                            continuation.finish()
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },

            // MARK: Memories (H2-ext)
            memories: { hid in
                guard let writer = LocalCacheDatabase.writer else { return [] }
                return (try? writer.read { db in
                    try MemoryRecord
                        .where { $0.hid.eq(hid) }
                        .order { $0.date.desc() }
                        .fetchAll(db)
                })?.compactMap(\.memory) ?? []
            },
            upsertMemories: { hid, memories in
                guard let writer = LocalCacheDatabase.writer else { return }
                do {
                    try writer.write { db in
                        let incoming = Set(memories.map(\.id))
                        let existing = try MemoryRecord.where { $0.hid.eq(hid) }.fetchAll(db).map(\.id)
                        let stale = existing.filter { !incoming.contains($0) }
                        if !stale.isEmpty {
                            try MemoryRecord.where { $0.id.in(stale) }.delete().execute(db)
                        }
                        for memory in memories {
                            if let record = MemoryRecord(memory, hid: hid) {
                                try MemoryRecord.upsert { record }.execute(db)
                            }
                        }
                    }
                } catch {
                    logger.error("upsertMemories failed: \(error.localizedDescription, privacy: .public)")
                }
            },
            observeMemories: { hid in
                guard let writer = LocalCacheDatabase.writer else { return .never }
                let observation = ValueObservation.tracking { db in
                    try MemoryRecord
                        .where { $0.hid.eq(hid) }
                        .order { $0.date.desc() }
                        .fetchAll(db)
                }
                return AsyncStream { continuation in
                    let task = Task {
                        do {
                            for try await records in observation.values(in: writer) {
                                continuation.yield(records.compactMap(\.memory))
                            }
                            continuation.finish()
                        } catch {
                            logger.error("observeMemories ended: \(error.localizedDescription, privacy: .public)")
                            continuation.finish()
                        }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },

            // MARK: Lists (H2-ext)
            lists: { hid in
                guard let writer = LocalCacheDatabase.writer else { return [] }
                return (try? writer.read { db in
                    try ListRecord
                        .where { $0.hid.eq(hid) }
                        .order { $0.createdAt.asc() }
                        .fetchAll(db)
                })?.compactMap(\.list) ?? []
            },
            upsertLists: { hid, lists in
                guard let writer = LocalCacheDatabase.writer else { return }
                do {
                    try writer.write { db in
                        let incoming = Set(lists.map(\.id))
                        let existing = try ListRecord.where { $0.hid.eq(hid) }.fetchAll(db).map(\.id)
                        let stale = existing.filter { !incoming.contains($0) }
                        if !stale.isEmpty {
                            try ListRecord.where { $0.id.in(stale) }.delete().execute(db)
                        }
                        for list in lists {
                            if let record = ListRecord(list, hid: hid) {
                                try ListRecord.upsert { record }.execute(db)
                            }
                        }
                    }
                } catch {
                    logger.error("upsertLists failed: \(error.localizedDescription, privacy: .public)")
                }
            },
            observeLists: { hid in
                guard let writer = LocalCacheDatabase.writer else { return .never }
                let observation = ValueObservation.tracking { db in
                    try ListRecord
                        .where { $0.hid.eq(hid) }
                        .order { $0.createdAt.asc() }
                        .fetchAll(db)
                }
                return AsyncStream { continuation in
                    let task = Task {
                        do {
                            for try await records in observation.values(in: writer) {
                                continuation.yield(records.compactMap(\.list))
                            }
                            continuation.finish()
                        } catch {
                            logger.error("observeLists ended: \(error.localizedDescription, privacy: .public)")
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
        observeCareItems: { _ in .never },
        documents: { _, _ in [] },
        upsertDocuments: { _, _ in },
        observeDocuments: { _, _ in .never },
        memories: { _ in [] },
        upsertMemories: { _, _ in },
        observeMemories: { _ in .never },
        lists: { _ in [] },
        upsertLists: { _, _ in },
        observeLists: { _ in .never }
    )
    public static let previewValue = LocalCacheClient(
        bootstrap: {},
        careItems: { _ in [] },
        upsertCareItems: { _, _ in },
        observeCareItems: { _ in .never },
        documents: { _, _ in [] },
        upsertDocuments: { _, _ in },
        observeDocuments: { _, _ in .never },
        memories: { _ in [] },
        upsertMemories: { _, _ in },
        observeMemories: { _ in .never },
        lists: { _ in [] },
        upsertLists: { _, _ in },
        observeLists: { _ in .never }
    )
}

public extension DependencyValues {
    /// The H2 local SQLite mirror.
    var localCache: LocalCacheClient {
        get { self[LocalCacheClient.self] }
        set { self[LocalCacheClient.self] = newValue }
    }
}
