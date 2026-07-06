import Dependencies
import Foundation
import OSLog
import SQLiteData

/// H2 — owns the on-disk SQLite mirror: a single ``DatabaseWriter`` (a GRDB `DatabasePool`) living in
/// Application Support, provisioned + migrated exactly once per process.
///
/// ## Why a module-owned writer *and* `defaultDatabase`
/// The app entry point (`MenereApp`) is off-limits this wave, so we can't call `prepareDependencies`
/// at launch. Instead the writer is created lazily the first time a feature touches the cache
/// (`LocalCacheClient.bootstrap()`), which:
///   1. builds + migrates the pool, storing it in this module-level box (the client reads/writes
///      through it directly — no dependency-timing hazard), and
///   2. best-effort seeds `@Dependency(\.defaultDatabase)` with the same pool, so future callers can
///      use `@FetchAll`/`@SharedReader(.fetch(...))` reactive reads out of the box.
///
/// Idempotent: only the first call provisions; later calls are no-ops.
enum LocalCacheDatabase {
    private static let logger = Logger(subsystem: "menere", category: "LocalCache")

    /// The shared writer, guarded so bootstrap runs exactly once even under concurrent first-touch.
    private static let box = LockIsolated<(any DatabaseWriter)?>(nil)

    /// Provision + migrate the pool once, returning the shared writer. Safe to call repeatedly.
    @discardableResult
    static func bootstrap() -> (any DatabaseWriter)? {
        box.withValue { existing in
            if let existing { return existing }
            do {
                let writer = try makeWriter()
                try migrate(writer)
                existing = writer
                // Best-effort: make this the app-wide default so reactive @FetchAll reads work for
                // any future consumer. Guarded to a single call; ignored if already prepared.
                prepareDependencies { $0.defaultDatabase = writer }
                logger.info("LocalCache ready at \(writer.path, privacy: .public)")
                return writer
            } catch {
                logger.error("LocalCache bootstrap failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// The shared writer, bootstrapping on first access.
    static var writer: (any DatabaseWriter)? { bootstrap() }

    // MARK: Provisioning

    private static func makeWriter() throws -> any DatabaseWriter {
        @Dependency(\.context) var context
        var configuration = Configuration()
        #if DEBUG
        configuration.prepareDatabase { db in
            db.trace(options: .profile) { logger.debug("\($0.expandedDescription, privacy: .public)") }
        }
        #endif
        // In live app context this lands a `menere-cache.db` file in Application Support; in
        // previews/tests `defaultDatabase` hands back a throwaway temp DB automatically.
        let path: String?
        if context == .live {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            path = dir.appendingPathComponent("menere-cache.db").path
        } else {
            path = nil
        }
        return try defaultDatabase(path: path, configuration: configuration)
    }

    // MARK: Migrations (append-only; never edit a shipped migration)

    private static func migrate(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // During development, rebuild the cache from scratch when the schema changes. The cache is a
        // disposable mirror of Firestore, so this is always safe.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        migrator.registerMigration("H2-create-careItems") { db in
            try #sql(
                """
                CREATE TABLE "careItemRecords" (
                    "id" TEXT NOT NULL PRIMARY KEY,
                    "hid" TEXT NOT NULL,
                    "kind" TEXT NOT NULL,
                    "name" TEXT NOT NULL,
                    "iconSymbol" TEXT NOT NULL,
                    "location" TEXT,
                    "createdAt" REAL NOT NULL,
                    "photoPath" TEXT,
                    "stickerPath" TEXT,
                    "species" TEXT,
                    "speciesLatin" TEXT,
                    "careNotes" TEXT,
                    "careContext" TEXT,
                    "familyNotes" TEXT,
                    "lightLevel" TEXT,
                    "breed" TEXT,
                    "birthday" REAL,
                    "vetName" TEXT,
                    "vetPhone" TEXT,
                    "tasksJSON" TEXT NOT NULL,
                    "speciesProfileJSON" TEXT
                ) STRICT
                """
            )
            .execute(db)
            try #sql(
                """
                CREATE INDEX "careItemRecords_hid" ON "careItemRecords" ("hid")
                """
            )
            .execute(db)
        }
        try migrator.migrate(writer)
    }
}
