import Foundation
import GRDB
import OpenHumanCore

public final class MailStore: Sendable {
    public let location: StoreLocation
    public let writerID: String
    let writer: any DatabaseWriter
    let readOnly: Bool
    let bumpsChangeFeed: Bool
    let runtime: StoreRuntime

    static let maxCompatLevel = 1

    init(location: StoreLocation, writerID: String, writer: any DatabaseWriter,
         readOnly: Bool = false, bumpsChangeFeed: Bool = false,
         changeNotificationName: String = OHIdentifiers.storeChangedNotification) {
        self.runtime = StoreRuntime(notificationName: changeNotificationName)
        self.location = location
        self.writerID = writerID
        self.writer = writer
        self.readOnly = readOnly
        self.bumpsChangeFeed = bumpsChangeFeed
    }

    public static func open(_ options: StoreOptions) throws -> MailStore {
        let location = options.location
        do {
            if !options.readOnly { try location.createDirectories() }
            var config = Configuration()
            config.readonly = options.readOnly
            config.busyMode = .timeout(5)
            config.maximumReaderCount = 6
            let readOnly = options.readOnly
            config.prepareDatabase { db in
                if !readOnly {
                    let tables = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") ?? 0
                    // auto_vacuum only takes effect before the first table exists; reader connections are read-only and cannot set it
                    if tables == 0 { try? db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL") }
                }
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
                try db.execute(sql: "PRAGMA temp_store = MEMORY")
                try db.execute(sql: "PRAGMA cache_size = -16000")
                try db.execute(sql: "PRAGMA mmap_size = 268435456")
                try db.execute(sql: "PRAGMA secure_delete = ON")
                if !readOnly { try db.execute(sql: "PRAGMA journal_size_limit = 67108864") }
            }
            let pool = try DatabasePool(path: location.databaseURL.path, configuration: config)
            try checkCompat(pool)
            if !options.readOnly {
                try migrateIfNeeded(pool, migrator: migrator())
            }
            let writerID = UUID().uuidString
            let store = MailStore(location: location, writerID: writerID, writer: pool,
                                  readOnly: options.readOnly, bumpsChangeFeed: true,
                                  changeNotificationName: options.changeNotificationName)
            if !options.readOnly {
                let now = nowMillis()
                let kind = options.processKind.rawValue
                let version = options.appVersion
                try pool.write { db in
                    try db.execute(sql: "DELETE FROM change_feed WHERE updated_at < ?", arguments: [now - 86_400_000])
                    try db.execute(sql: """
                        INSERT INTO change_feed (writer_id, pid, kind, seq, updated_at) VALUES (?, ?, ?, 0, ?)
                        """, arguments: [writerID, Int(ProcessInfo.processInfo.processIdentifier), kind, now])
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO schema_info (id, compat_level, created_by_version, created_at)
                        VALUES (1, ?, ?, ?)
                        """, arguments: [maxCompatLevel, version, now])
                }
                location.hardenFilePermissions()
                try store.reaggregateIfDerivedVersionStale()
                try store.replaceInboxesIfPlacementVersionStale()
            }
            if options.observeExternalChanges && !options.readOnly {
                store.startExternalChangeMonitor(pool: pool)
            }
            return store
        } catch {
            throw mapError(error)
        }
    }

    public static func openInMemoryForTesting() throws -> MailStore {
        do {
            let queue = try DatabaseQueue()
            try migrator().migrate(queue)
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO schema_info (id, compat_level, created_by_version, created_at) VALUES (1, ?, 'test', ?)
                    """, arguments: [maxCompatLevel, nowMillis()])
            }
            return MailStore(location: StoreLocation(directory: URL(fileURLWithPath: "/dev/null")),
                             writerID: UUID().uuidString, writer: queue)
        } catch {
            throw mapError(error)
        }
    }

    public func setExternalChangePollActive(_ active: Bool) {
        runtime.monitor?.setActive(active)
    }

    public func close() throws {
        runtime.flushPendingPost()
        runtime.monitor?.stop()
        runtime.monitor = nil
        do { try writer.close() } catch { throw Self.mapError(error) }
        if !readOnly && bumpsChangeFeed { location.hardenFilePermissions() }
    }

    func write<T>(countsAsActivity: Bool = true, _ body: (Database) throws -> T) throws -> T {
        if readOnly { throw StoreError.readOnly }
        do {
            let result = try writer.write { db in
                let result = try body(db)
                if self.bumpsChangeFeed {
                    try db.execute(sql: "UPDATE change_feed SET seq = seq + 1, updated_at = ? WHERE writer_id = ?",
                                   arguments: [nowMillis(), self.writerID])
                }
                return result
            }
            if countsAsActivity { runtime.noteWrite() }
            if bumpsChangeFeed { runtime.scheduleChangePost() }
            return result
        } catch {
            runtime.noteError(error)
            throw Self.mapError(error)
        }
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        do { return try writer.read(body) } catch {
            runtime.noteError(error)
            throw Self.mapError(error)
        }
    }

    func writeOutsideTransaction<T>(_ body: (Database) throws -> T) throws -> T {
        if readOnly { throw StoreError.readOnly }
        do { return try writer.writeWithoutTransaction(body) } catch {
            runtime.noteError(error)
            throw Self.mapError(error)
        }
    }

    func bumpObservationPulse() throws {
        try writeOutsideTransaction { db in
            try db.inTransaction {
                try db.execute(sql: "UPDATE observation_pulse SET seq = seq + 1 WHERE id = 1")
                return .commit
            }
        }
    }

    static func mapError(_ error: Error) -> Error {
        if error is StoreError { return error }
        if let db = error as? DatabaseError {
            if db.resultCode == .SQLITE_BUSY || db.resultCode == .SQLITE_LOCKED { return StoreError.busy }
            return StoreError.integrity("sqlite \(db.extendedResultCode.rawValue): \(db.message ?? "")")
        }
        return error
    }

    private func startExternalChangeMonitor(pool: DatabasePool) {
        let me = writerID
        let monitor = ExternalChangeMonitor(
            notificationName: runtime.notificationName,
            readOthers: {
                try pool.read { db in
                    var seen: [String: Int64] = [:]
                    for row in try Row.fetchAll(db, sql: "SELECT writer_id, seq FROM change_feed WHERE writer_id <> ?",
                                                arguments: [me]) {
                        seen[row["writer_id"]] = row["seq"]
                    }
                    return seen
                }
            },
            pulse: {
                try pool.write { db in try db.execute(sql: "UPDATE observation_pulse SET seq = seq + 1 WHERE id = 1") }
            })
        runtime.monitor = monitor
        monitor.start()
    }

    private static func checkCompat(_ pool: DatabasePool) throws {
        let found: Int? = try pool.read { db in
            guard try db.tableExists("schema_info") else { return nil }
            return try Int.fetchOne(db, sql: "SELECT compat_level FROM schema_info WHERE id = 1")
        }
        if let found, found > maxCompatLevel {
            throw StoreError.schemaTooNew(found: found, supported: maxCompatLevel)
        }
    }

    static func migrateIfNeeded(_ pool: DatabasePool, migrator: DatabaseMigrator) throws {
        let applied: Set<String> = try pool.read { db in
            guard try db.tableExists("grdb_migrations") else { return [] }
            return try migrator.appliedIdentifiers(db)
        }
        if !applied.isSubset(of: Set(migrator.migrations)) { return }
        #if DEBUG
        try backUpAndEraseIfSchemaChanged(pool, migrator: migrator)
        #endif
        try migrator.migrate(pool)
    }

    public static func schemaChangeWouldErase(_ location: StoreLocation) -> Bool {
        #if DEBUG
        return schemaChangeWouldErase(location, migrator: migrator())
        #else
        return false
        #endif
    }

    #if DEBUG
    static func schemaChangeWouldErase(_ location: StoreLocation, migrator: DatabaseMigrator) -> Bool {
        let path = location.databaseURL.path
        guard FileManager.default.fileExists(atPath: path), let queue = try? DatabaseQueue(path: path) else { return false }
        defer { try? queue.close() }
        let answer: Bool? = try? queue.read { db -> Bool in
            guard try db.tableExists("grdb_migrations") else { return false }
            let applied = try migrator.appliedIdentifiers(db)
            guard applied.isSubset(of: Set(migrator.migrations)) else { return false }
            return try migrator.hasSchemaChanges(db)
        }
        return answer ?? false
    }

    // DEBUG only; must go before release, since the file then holds drafts, snoozes and pending sends that must never be erased
    @discardableResult
    static func backUpAndEraseIfSchemaChanged(_ pool: DatabasePool, migrator: DatabaseMigrator) throws -> Bool {
        let changed = try pool.read { db in
            try db.tableExists("grdb_migrations") && migrator.hasSchemaChanges(db)
        }
        guard changed else { return false }
        let path = pool.path
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backupPath = path + ".pre-erase-" + stamp
        let backup = try DatabaseQueue(path: backupPath)
        try pool.backup(to: backup)
        try backup.close()
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupPath)
        pruneBackups(databasePath: path, keeping: 2)
        Log(.store).notice("debug build: schema v1 changed; the store was backed up (pre-erase-\(stamp)) and is erased now")
        try pool.erase()
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            try db.execute(sql: "VACUUM")
        }
        return true
    }

    private static func pruneBackups(databasePath: String, keeping: Int) {
        let url = URL(fileURLWithPath: databasePath)
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".pre-erase-"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }.sorted()
        for name in names.dropLast(keeping) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }
    #endif

    static func migrator(sql: String = SchemaV1.sql) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        migrator.registerMigration("v1") { db in
            try db.execute(sql: sql)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: SchemaV2.sql)
        }
        return migrator
    }
}

func nowMillis() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

// Log only the error kind: `Log` is public and a GRDB error can carry statement arguments (mail content)
func storeLogCode(_ error: any Error) -> String {
    if let database = error as? DatabaseError { return "sqlite \(database.extendedResultCode.rawValue)" }
    return String(describing: type(of: error))
}
