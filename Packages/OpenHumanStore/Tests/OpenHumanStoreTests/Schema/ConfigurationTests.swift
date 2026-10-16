import Foundation
import GRDB
import OpenHumanCore
import Testing
@testable import OpenHumanStore

@Suite struct ConfigurationTests {
    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    @Test func directoriesAre0700AndFilesAre0600() throws {
        let (store, dir) = try openTemp(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let loc = store.location
        for d in [loc.directory, loc.attachmentsDirectory, loc.draftsDirectory, loc.logsDirectory] {
            #expect(try mode(d) == 0o700, "\(d.lastPathComponent)")
        }
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: loc.databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) { #expect(try mode(url) == 0o600, "mail.sqlite\(suffix)") }
        }
        try store.close()
        #expect(try mode(loc.databaseURL) == 0o600)
    }

    @Test func openTightensLooseDirectoryModes() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let (store, _) = try openTemp(dir: dir)
        try store.close()
        #expect(try mode(dir) == 0o700)
    }

    @Test func connectionPragmasMatchTheSpec() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let values = try store.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA synchronous")!, try Int.fetchOne(db, sql: "PRAGMA temp_store")!,
             try Int.fetchOne(db, sql: "PRAGMA cache_size")!, try Int.fetchOne(db, sql: "PRAGMA foreign_keys")!)
        }
        let writerBusy = try store.writeOutsideTransaction { try Int.fetchOne($0, sql: "PRAGMA busy_timeout")! }
        #expect(writerBusy == 5000)
        #expect(values.0 == 1)
        #expect(values.1 == 2)
        #expect(values.2 == -16000)
        #expect(values.3 == 1)
        #expect(try store.read { try Int.fetchOne($0, sql: "PRAGMA secure_delete") } == 1)
        #expect(try store.writeOutsideTransaction { try Int.fetchOne($0, sql: "PRAGMA secure_delete") } == 1)
    }

    #if canImport(Darwin)
    @Test func attachmentsAreExcludedFromBackupsAndTheDatabaseIsNot() throws {
        let (store, dir) = try openTemp(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        let loc = store.location
        func excluded(_ url: URL) throws -> Bool {
            try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
        }
        #expect(try excluded(loc.attachmentsDirectory))
        #expect(try !excluded(loc.directory))
        #expect(try !excluded(loc.draftsDirectory))
        #expect(try !excluded(loc.databaseURL))
        try store.close()
    }
    #endif

    @Test func writerHoldsTheWriteLockForTheWholeTransaction() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = Configuration()
        config.busyMode = .immediateError
        let other = try DatabaseQueue(path: store.location.databaseURL.path, configuration: config)
        try store.write { _ in
            #expect(throws: DatabaseError.self) { try other.writeWithoutTransaction { try $0.execute(sql: "BEGIN IMMEDIATE") } }
        }
    }

    @Test func schemaTooNewIsRejectedReadOnlyToo() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.write { try $0.execute(sql: "UPDATE schema_info SET compat_level = 99") }
        try store.close()
        #expect(throws: StoreError.schemaTooNew(found: 99, supported: 1)) { try openTemp(readOnly: true, dir: dir) }
    }

    @Test func unknownMigrationsAtSameCompatLevelOpenWithoutMigratingOrErasing() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.addAccount(email: "keep@example.com", displayName: nil, scopes: [])
        try store.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v3')")
            try db.execute(sql: "CREATE TABLE from_the_future (x INTEGER)")
        }
        try store.close()
        let (again, _) = try openTemp(dir: dir)
        #expect(try again.accounts().map(\.email) == ["keep@example.com"])
        #expect(try again.read { try $0.tableExists("from_the_future") })
        #expect(try again.doctor().appliedMigrations == ["v1", "v2", "v3"])
    }

    @Test func doctorReportsVersionsAndConfiguration() throws {
        let (store, dir) = try openTemp(kind: .cli)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = try store.doctor()
        #expect(report.fts5Available && report.trigramAvailable)
        #expect(report.sqliteVersion.split(separator: ".").count >= 3)
        #expect(report.journalMode == "wal")
        #expect(report.autoVacuum == 2)
        #expect(report.foreignKeysEnabled)
        #expect(report.compatLevel == 1)
        #expect(report.createdByVersion == "0.0.0-test")
        #expect(report.appliedMigrations == ["v1", "v2"])
        #expect(report.pageCount > 0)
        #expect(!report.isReadOnly && !report.isCorrupt)
        try store.close()
        let (ro, _) = try openTemp(readOnly: true, dir: dir)
        #expect(try ro.doctor().isReadOnly)
    }

    @Test func foreignKeyCheckIsCleanOnAFreshDatabase() throws {
        let store = try MailStore.openInMemoryForTesting()
        let violations = try store.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }
        #expect(violations.isEmpty)
    }
}

@Suite struct LocationTests {
    @Test func resolveOrder() throws {
        #expect(try StoreLocation.resolve(home: "/tmp/oh-home").directory.path == "/tmp/oh-home")
        #expect(try StoreLocation.resolve(home: "").directory.path.hasSuffix("Application Support/OpenHuman/Mail"))
        let def = try StoreLocation.resolve()
        #expect(def.directory.path.hasSuffix("Library/Application Support/OpenHuman/Mail"))
        #expect(def.databaseURL.lastPathComponent == "mail.sqlite")
        #expect(def.attachmentsDirectory.lastPathComponent == "Attachments")
        #expect(def.draftsDirectory.lastPathComponent == "Drafts")
    }

    @Test(arguments: [
        ("report.pdf", "report.pdf"),
        ("../../etc/passwd", "etcpasswd"),
        (".hidden", "hidden"),
        ("...", "attachment-1.2"),
        ("a/b\\c:d.txt", "abcd.txt"),
        ("tab\there\u{0}.txt", "tabhere.txt"),
        ("invoice\u{202E}fdp.exe", "invoicefdp.exe"),
        ("", "attachment-1.2"),
        ("   ", "attachment-1.2"),
        ("résumé 😀.pdf", "résumé 😀.pdf"),
    ])
    func sanitizing(raw: String, expected: String) {
        #expect(StoreLocation.sanitizedFilename(raw, partID: "1.2") == expected)
    }

    @Test func longNamesCapAt120BytesAndKeepTheExtension() {
        let long = String(repeating: "a", count: 300) + ".pdf"
        let name = StoreLocation.sanitizedFilename(long, partID: "1")
        #expect(name.utf8.count <= 120)
        #expect(name.hasSuffix(".pdf"))
        let emoji = String(repeating: "😀", count: 100) + ".txt"
        let e = StoreLocation.sanitizedFilename(emoji, partID: "1")
        #expect(e.utf8.count <= 120 && e.hasSuffix(".txt"))
        #expect(String(decoding: Array(e.utf8), as: UTF8.self) == e)
        let noExt = StoreLocation.sanitizedFilename(String(repeating: "b", count: 500), partID: "1")
        #expect(noExt.utf8.count == 120)
    }
}
