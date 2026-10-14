import Foundation
import GRDB
import OpenHumanCore
import Testing
@testable import OpenHumanStore

@Suite struct MaintenanceTests {
    private func bloat(_ store: MailStore) throws {
        try store.write { db in
            for i in 0..<400 {
                try db.execute(sql: "INSERT INTO settings (scope, key, value_json, updated_at) VALUES ('global', ?, ?, 0)",
                               arguments: ["k\(i)", String(repeating: "x", count: 4000)])
            }
        }
        try store.write { db in try db.execute(sql: "DELETE FROM settings WHERE key LIKE 'k%'") }
    }

    @Test func nothingRunsBeforeThirtySecondsOfIdle() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        #expect(try store.runIdleMaintenance(now: Date().addingTimeInterval(10)) == MaintenanceReport())
        let later = try store.runIdleMaintenance(now: Date().addingTimeInterval(31))
        #expect(later.checkpointed)
        #expect(later.quickCheck == "ok")
    }

    @Test func checkpointTruncatesTheWalAndIsAtMostHourly() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try bloat(store)
        let wal = URL(fileURLWithPath: store.location.databaseURL.path + "-wal")
        let before = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0
        #expect(before > 0)
        let now = Date().addingTimeInterval(60)
        #expect(try store.runIdleMaintenance(now: now).checkpointed)
        #expect(((try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0) == 0)
        #expect(try store.runIdleMaintenance(now: now.addingTimeInterval(120)).checkpointed == false)
        #expect(try store.runIdleMaintenance(now: now.addingTimeInterval(3601)).checkpointed)
    }

    @Test func incrementalVacuumRunsOnlyAboveTenPercentFree() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fresh = try store.runIdleMaintenance(now: Date().addingTimeInterval(60))
        #expect(!fresh.vacuumed)
        try bloat(store)
        let freeBefore = try store.doctor().freelistCount
        #expect(freeBefore > 0)
        let report = try store.runIdleMaintenance(now: Date().addingTimeInterval(120), force: true)
        #expect(report.vacuumed)
        #expect(try store.doctor().freelistCount < freeBefore)
    }

    @Test func theAutomaticQuickCheckIsSkippedAboveTheSizeLimit() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date().addingTimeInterval(60)
        #expect(try store.runIdleMaintenance(now: now, force: false, quickCheckMaxBytes: 1_024).quickCheck == nil)
        #expect(try store.runIdleMaintenance(now: now, force: false, quickCheckMaxBytes: 1 << 40).quickCheck == "ok")
        #expect(try store.runIdleMaintenance(now: now, force: true, quickCheckMaxBytes: 1_024).quickCheck == "ok")
    }

    @Test func leaseHeartbeatsDoNotKeepTheProcessBusy() throws {
        let (store, dir) = try openTemp(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let t0 = Date()
        _ = try store.acquireLease(account: account, ownerID: store.writerID, kind: "app", pid: ProcessInfo.processInfo.processIdentifier,
                                   host: ProcessIdentity.localHostName, now: t0, ttl: .seconds(45))
        let lastBefore = try #require(store.runtime.lastWriteAt)
        #expect(try store.renewLease(account: account, ownerID: store.writerID, now: t0.addingTimeInterval(15), ttl: .seconds(45)))
        #expect(store.runtime.lastWriteAt == lastBefore)
        try store.write { _ in }
        #expect(try #require(store.runtime.lastWriteAt) >= lastBefore)
    }

    @Test func theWalIsCappedByJournalSizeLimit() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let limit = try store.read { try Int.fetchOne($0, sql: "PRAGMA journal_size_limit") }
        #expect(limit == 67_108_864)
    }

    @Test func quickCheckRunsWeeklyAndIsRecorded() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date().addingTimeInterval(60)
        #expect(try store.runIdleMaintenance(now: t0).quickCheck == "ok")
        #expect(try store.runIdleMaintenance(now: t0.addingTimeInterval(3 * 86_400)).quickCheck == nil)
        #expect(try store.runIdleMaintenance(now: t0.addingTimeInterval(8 * 86_400)).quickCheck == "ok")
        let row = try store.read { try Row.fetchOne($0, sql: "SELECT state, cursor FROM maintenance_tasks WHERE task = 'quick_check'") }
        #expect(row?["state"] as String? == "done" && row?["cursor"] as String? == "ok")
    }

    @Test func maintenanceTasksRunInChunksAndResume() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.registerMaintenanceTask("demo_rebuild") { _, cursor in
            let n = Int(cursor ?? "0") ?? 0
            return MaintenanceStep(cursor: String(n + 1), done: n + 1 >= 3)
        }
        try store.enqueueMaintenanceTask("demo_rebuild")
        try store.enqueueMaintenanceTask("no_handler")
        func state(_ task: String) throws -> (String, String?) {
            try store.read { db in
                let r = try Row.fetchOne(db, sql: "SELECT state, cursor FROM maintenance_tasks WHERE task = ?", arguments: [task])!
                return (r["state"], r["cursor"])
            }
        }
        var clock = Date().addingTimeInterval(60)
        var seen: [String] = []
        for _ in 0..<4 {
            clock = clock.addingTimeInterval(60)
            seen += try store.runIdleMaintenance(now: clock).maintenanceTasks
        }
        #expect(seen == ["demo_rebuild", "demo_rebuild", "demo_rebuild"])
        #expect(try state("demo_rebuild") == ("done", "3"))
        #expect(try state("no_handler").0 == "pending")
        try store.enqueueMaintenanceTask("demo_rebuild")
        #expect(try state("demo_rebuild") == ("pending", nil))
    }

    @Test func readOnlyStoresRefuseMaintenance() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.close()
        let (ro, _) = try openTemp(readOnly: true, dir: dir)
        #expect(throws: StoreError.readOnly) { try ro.runIdleMaintenance(force: true) }
    }

    @Test func garbageFileIsReportedAsIntegrityFailureAndCanBeMovedAside() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loc = StoreLocation(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8192).write(to: loc.databaseURL)
        #expect(throws: StoreError.self) { try openTemp(dir: dir) }
        let moved = try MailStore.moveCorruptDatabaseAside(at: loc)
        #expect(moved.lastPathComponent.hasPrefix("mail.sqlite.corrupt-"))
        #expect(!FileManager.default.fileExists(atPath: loc.databaseURL.path))
        let (fresh, _) = try openTemp(dir: dir)
        #expect(try fresh.accounts().isEmpty)
    }

    @Test func quickCheckFailureMarksTheStoreCorrupt() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.write { db in
            for i in 0..<200 {
                try db.execute(sql: "INSERT INTO settings (scope, key, value_json, updated_at) VALUES ('global', ?, ?, 0)",
                               arguments: ["k\(i)", String(repeating: "y", count: 500)])
            }
        }
        try store.runtimeCheckpoint()
        try store.close()
        let handle = try FileHandle(forUpdating: store.location.databaseURL)
        let size = try handle.seekToEnd()
        #expect(size > 8 * 4096)
        try handle.seek(toOffset: size - 4096 * 3)
        handle.write(Data(repeating: 0xFF, count: 4096))
        try handle.close()
        let (again, _) = try openTemp(dir: dir)
        let report = try? again.runIdleMaintenance(now: Date().addingTimeInterval(60), force: true)
        #expect(report?.quickCheck != "ok")
        #expect(again.isCorrupt)
    }
}

extension MailStore {
    fileprivate func runtimeCheckpoint() throws {
        try writeOutsideTransaction { db in _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
    }
}
