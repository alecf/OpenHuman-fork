import Foundation
import GRDB
import OpenHumanCore

extension MailStore {
    static let idleSeconds: TimeInterval = 30
    static let checkpointInterval: TimeInterval = 3600
    static let quickCheckInterval: TimeInterval = 7 * 86_400
    static let quickCheckTask = "quick_check"
    static let quickCheckMaxBytes = 4 * 1_073_741_824

    public var isCorrupt: Bool { runtime.isCorrupt }

    public func doctor() throws -> StoreDoctorReport {
        let probe = Self.probeFTS()
        let corrupt = isCorrupt
        let isReadOnly = readOnly
        return try read { db in
            let info = try Row.fetchOne(db, sql: "SELECT compat_level, created_by_version FROM schema_info WHERE id = 1")
            return StoreDoctorReport(
                sqliteVersion: try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "",
                fts5Available: probe.fts5, trigramAvailable: probe.trigram,
                journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
                autoVacuum: try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0,
                foreignKeysEnabled: (try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0) == 1,
                pageCount: try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0,
                freelistCount: try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0,
                compatLevel: info?["compat_level"] ?? 0, createdByVersion: info?["created_by_version"] ?? "",
                appliedMigrations: try db.tableExists("grdb_migrations")
                    ? String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") : [],
                isReadOnly: isReadOnly, isCorrupt: corrupt)
        }
    }

    static func probeFTS() -> (fts5: Bool, trigram: Bool) {
        guard let queue = try? DatabaseQueue() else { return (false, false) }
        let fts5 = (try? queue.write { try $0.execute(sql: "CREATE VIRTUAL TABLE p1 USING fts5(x)") }) != nil
        let trigram = (try? queue.write { try $0.execute(sql: "CREATE VIRTUAL TABLE p2 USING fts5(x, tokenize='trigram')") }) != nil
        return (fts5, trigram)
    }

    @discardableResult
    public func runIdleMaintenance(now: Date = Date(), force: Bool = false) throws -> MaintenanceReport {
        try runIdleMaintenance(now: now, force: force, quickCheckMaxBytes: Self.quickCheckMaxBytes)
    }

    func runIdleMaintenance(now: Date, force: Bool, quickCheckMaxBytes: Int) throws -> MaintenanceReport {
        if readOnly { throw StoreError.readOnly }
        var report = MaintenanceReport()
        let idle = force || now.timeIntervalSince(runtime.lastWriteAt ?? .distantPast) >= Self.idleSeconds
        guard idle else { return report }
        let isFile = bumpsChangeFeed

        let (pages, free, pageSize) = try read { db in
            (try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0, try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0,
             try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096)
        }
        if pages > 0, free * 10 > pages {
            try writeOutsideTransaction { db in try db.execute(sql: "PRAGMA incremental_vacuum(2000)") }
            report.vacuumed = true
        }

        if force || pages * pageSize <= quickCheckMaxBytes, try quickCheckDue(now: now, force: force) {
            let lines = try read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") }
            let result = lines.first ?? "ok"
            if result != "ok" { runtime.markCorrupt() }
            try write { db in
                try db.execute(sql: """
                    INSERT INTO maintenance_tasks (task, state, cursor, updated_at) VALUES (?, 'done', ?, ?)
                    ON CONFLICT(task) DO UPDATE SET state = 'done', cursor = excluded.cursor, updated_at = excluded.updated_at
                    """, arguments: [Self.quickCheckTask, result, Int64((now.timeIntervalSince1970 * 1000).rounded())])
            }
            report.quickCheck = result
        }

        report.maintenanceTasks = try advanceMaintenanceTasks(now: now)

        if isFile, force || runtime.lastCheckpointAt.map({ now.timeIntervalSince($0) >= Self.checkpointInterval }) != false {
            try writeOutsideTransaction { db in _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            runtime.lastCheckpointAt = now
            report.checkpointed = true
        }
        return report
    }

    private func quickCheckDue(now: Date, force: Bool) throws -> Bool {
        if force { return true }
        let last: Int64? = try read { db in
            try Int64.fetchOne(db, sql: "SELECT updated_at FROM maintenance_tasks WHERE task = ?", arguments: [Self.quickCheckTask])
        }
        guard let last else { return true }
        return now.timeIntervalSince1970 * 1000 - Double(last) >= Self.quickCheckInterval * 1000
    }

    func enqueueMaintenanceTask(_ name: String, now: Date = Date()) throws {
        try write { db in
            try db.execute(sql: """
                INSERT INTO maintenance_tasks (task, state, cursor, updated_at) VALUES (?, 'pending', NULL, ?)
                ON CONFLICT(task) DO UPDATE SET state = 'pending', cursor = NULL, updated_at = excluded.updated_at
                WHERE maintenance_tasks.state = 'done'
                """, arguments: [name, Int64((now.timeIntervalSince1970 * 1000).rounded())])
        }
    }

    func registerMaintenanceTask(_ name: String, handler: @escaping MaintenanceHandler) {
        runtime.register(task: name, handler: handler)
    }

    private func advanceMaintenanceTasks(now: Date) throws -> [String] {
        let pending: [(String, String?)] = try read { db in
            try Row.fetchAll(db, sql: """
                SELECT task, cursor FROM maintenance_tasks WHERE state IN ('pending', 'running') AND task <> ?
                ORDER BY updated_at, task
                """, arguments: [Self.quickCheckTask]).map { ($0["task"], $0["cursor"]) }
        }
        var advanced: [String] = []
        let stamp = Int64((now.timeIntervalSince1970 * 1000).rounded())
        for (task, cursor) in pending {
            guard let handler = runtime.handler(for: task) else { continue }
            try write { db in
                let step = try handler(db, cursor)
                try db.execute(sql: "UPDATE maintenance_tasks SET state = ?, cursor = ?, updated_at = ? WHERE task = ?",
                               arguments: [step.done ? "done" : "running", step.cursor, stamp, task])
            }
            advanced.append(task)
        }
        return advanced
    }

    static let participantsDerivedVersion = 3
    static var participantsTask: String { "derived.participants.v\(participantsDerivedVersion)" }

    func reaggregateIfDerivedVersionStale() throws {
        let task = Self.participantsTask
        let state: String? = try read { db in
            try String.fetchOne(db, sql: "SELECT state FROM maintenance_tasks WHERE task = ?", arguments: [task])
        }
        if state == "done" { return }
        var after: Int64 = 0
        while true {
            let tids: [Int64] = try read { db in
                try Int64.fetchAll(db, sql: "SELECT tid FROM threads WHERE tid > ? ORDER BY tid LIMIT 200", arguments: [after])
            }
            guard let last = tids.last else { break }
            try write { db in try ThreadAggregator.refresh(tids: Set(tids), in: db) }
            after = last
        }
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO maintenance_tasks (task, state, cursor, updated_at) VALUES (?, 'done', NULL, ?)
                ON CONFLICT(task) DO UPDATE SET state = 'done', cursor = NULL, updated_at = excluded.updated_at
                """, arguments: [task, nowMillis()])
        }
    }

    static let placementDerivedVersion = 1
    static var placementTask: String { "derived.placement.events.v\(placementDerivedVersion)" }

    func replaceInboxesIfPlacementVersionStale() throws {
        let task = Self.placementTask
        let state: String? = try read { db in
            try String.fetchOne(db, sql: "SELECT state FROM maintenance_tasks WHERE task = ?", arguments: [task])
        }
        if state == "done" { return }
        let accounts: [Int64] = try read { db in try Int64.fetchAll(db, sql: "SELECT account_id FROM accounts") }
        for account in accounts {
            try write { db in _ = try ThreadAggregator.reevaluateSplits(account: account, in: db) }
        }
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO maintenance_tasks (task, state, cursor, updated_at) VALUES (?, 'done', NULL, ?)
                ON CONFLICT(task) DO UPDATE SET state = 'done', cursor = NULL, updated_at = excluded.updated_at
                """, arguments: [task, nowMillis()])
        }
    }

    // Local-only data (drafts, snoozes, pending sends, snippets) stays in the moved file, so the app must tell the user
    @discardableResult
    public static func moveCorruptDatabaseAside(at location: StoreLocation, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let target = URL(fileURLWithPath: location.databaseURL.path + ".corrupt-" + stamp)
        guard fm.fileExists(atPath: location.databaseURL.path) else {
            throw StoreError.notFound("database file")
        }
        for suffix in ["", "-wal", "-shm"] {
            let from = location.databaseURL.path + suffix
            let to = target.path + suffix
            if fm.fileExists(atPath: from) { try fm.moveItem(atPath: from, toPath: to) }
        }
        return target
    }
}
