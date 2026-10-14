import Foundation
import GRDB
import Testing
@testable import OpenHumanStore

@Suite struct MigrationTests {
    private func migratorWithV2() -> DatabaseMigrator {
        var migrator = MailStore.migrator()
        migrator.registerMigration("test-appended") { db in
            try db.execute(sql: "ALTER TABLE snippets ADD COLUMN note TEXT")
            try db.execute(sql: "CREATE INDEX accounts_added ON accounts(added_at)")
        }
        return migrator
    }

    @Test func v1DataSurvivesAnAppendedMigration() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: "Me", scopes: ["gmail.readonly"])
        try store.close()
        let pool = try DatabasePool(path: store.location.databaseURL.path)
        try MailStore.migrateIfNeeded(pool, migrator: migratorWithV2())
        let facts = try pool.read { db in
            (emails: try String.fetchAll(db, sql: "SELECT email FROM accounts"),
             labels: try Int.fetchOne(db, sql: "SELECT count(*) FROM labels WHERE account_id = ?", arguments: [account.rawValue]) ?? 0,
             hasNote: try db.columns(in: "snippets").contains { $0.name == "note" },
             fkViolations: try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
             applied: try MailStore.migrator().appliedIdentifiers(db))
        }
        #expect(facts.emails == ["me@example.com"])
        #expect(facts.labels >= 5)
        #expect(facts.hasNote)
        #expect(facts.fkViolations == 0)
        #expect(facts.applied == ["v1", "v2", "test-appended"])
        #expect(try backups(of: store.location).isEmpty, "an appended migration is not a schema change of v1")
    }

    @Test func fixtureDatabasesMigrateWithDataIntact() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/schema")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: fixtures.path)) ?? [])
            .filter { $0.hasPrefix("schema-v") && $0.hasSuffix(".sqlite") }
        for name in names {
            let dir = tempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: dir.appendingPathComponent("mail.sqlite"))
            let (store, _) = try openTemp(dir: dir)
            #expect(try store.accounts().map(\.email) == ["fixture@example.com"], "\(name)")
            #expect(try store.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty)
        }
    }

    #if DEBUG
    private func backups(of location: StoreLocation) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: location.directory.path).filter { $0.contains(".pre-erase-") }.sorted()
    }

    private func editedV1() -> DatabaseMigrator {
        MailStore.migrator(sql: SchemaV1.sql + "\nCREATE TABLE edited_in_place (x INTEGER);\n")
    }

    @Test func editedV1BacksUpThenErasesAndRebuildsInDebug() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.addAccount(email: "gone@example.com", displayName: nil, scopes: [])
        try store.close()
        let pool = try DatabasePool(path: store.location.databaseURL.path)
        try MailStore.migrateIfNeeded(pool, migrator: editedV1())
        let facts = try pool.read { db in
            (edited: try db.tableExists("edited_in_place"),
             accounts: try Int.fetchOne(db, sql: "SELECT count(*) FROM accounts") ?? -1,
             autoVacuum: try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? -1)
        }
        #expect(facts.edited)
        #expect(facts.accounts == 0, "erased")
        #expect(facts.autoVacuum == 2, "still incremental after the erase")
        let found = try backups(of: store.location)
        #expect(found.count == 1)
        let backup = try DatabaseQueue(path: store.location.directory.appendingPathComponent(found[0]).path)
        #expect(try backup.read { try String.fetchAll($0, sql: "SELECT email FROM accounts") } == ["gone@example.com"])
    }

    @Test func backupsAreCappedAtTwo() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.close()
        let pool = try DatabasePool(path: store.location.databaseURL.path)
        for i in 0..<4 {
            let m = MailStore.migrator(sql: SchemaV1.sql + "\nCREATE TABLE edit_\(i) (x INTEGER);\n")
            try MailStore.migrateIfNeeded(pool, migrator: m)
            Thread.sleep(forTimeInterval: 1.1)
        }
        #expect(try backups(of: store.location).count == 2)
    }

    @Test func unchangedV1IsNeverErased() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.addAccount(email: "keep@example.com", displayName: nil, scopes: [])
        try store.close()
        let (again, _) = try openTemp(dir: dir)
        #expect(try again.accounts().count == 1)
        #expect(try backups(of: again.location).isEmpty)
    }

    @Test func theEraseCanBeForeseenWithoutTouchingTheFile() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.addAccount(email: "still@example.com", displayName: nil, scopes: [])
        try store.close()
        #expect(!MailStore.schemaChangeWouldErase(store.location), "the registered v1 is the file's")
        #expect(MailStore.schemaChangeWouldErase(store.location, migrator: editedV1()))
        #expect(!MailStore.schemaChangeWouldErase(store.location, migrator: migratorWithV2()), "an appended migration")
        let missing = StoreLocation(directory: dir.appendingPathComponent("nowhere", isDirectory: true))
        #expect(!MailStore.schemaChangeWouldErase(missing, migrator: editedV1()))
        #expect(try backups(of: store.location).isEmpty)
        let (again, _) = try openTemp(dir: dir)
        #expect(try again.accounts().map(\.email) == ["still@example.com"], "asking changed nothing")
        try again.close()
        let pool = try DatabasePool(path: store.location.databaseURL.path)
        try MailStore.migrateIfNeeded(pool, migrator: migratorWithV2())
        try pool.close()
        #expect(!MailStore.schemaChangeWouldErase(store.location, migrator: editedV1()))
    }
    #else
    private func backups(of location: StoreLocation) throws -> [String] { [] }
    #endif
}
