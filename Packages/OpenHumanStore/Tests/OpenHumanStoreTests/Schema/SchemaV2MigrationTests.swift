import Foundation
import GRDB
import Testing
@testable import OpenHumanStore

@Suite struct SchemaV2MigrationTests {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/schema/schema-v1.sqlite")

    private func copyOfV1Fixture() throws -> URL {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixture, to: dir.appendingPathComponent("mail.sqlite"))
        return dir
    }

    @Test func migrationsAreRegisteredOnceInOrder() {
        #expect(MailStore.migrator().migrations == ["v1", "v2"])
    }

    @Test func v2IsAdditiveOnly() {
        let sql = SchemaV2.sql.split(separator: "\n").filter { !$0.hasPrefix("--") }.joined(separator: "\n").uppercased()
        let statements = sql.replacingOccurrences(of: "ON DELETE CASCADE", with: "")
        #expect(sql.components(separatedBy: "ON DELETE CASCADE").count == 2, "only waiting_overrides cascades")
        for forbidden in ["DROP ", "RENAME", "UPDATE ", "DELETE ", "CREATE TRIGGER", "VIRTUAL TABLE", "REPLACE"] {
            #expect(!statements.contains(forbidden), "v2 contains \(forbidden)")
        }
        #expect(statements.components(separatedBy: "INSERT ").count == 2)
        #expect(statements.contains("INSERT INTO LABELS") && statements.contains("'OH:WAITING'"))
        #expect(MailStore.maxCompatLevel == 1, "an additive migration keeps the compat level")
    }

    @Test func theV1FixtureMigratesWithEveryRowIntact() throws {
        let dir = try copyOfV1Fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try DatabaseQueue(path: dir.appendingPathComponent("mail.sqlite").path)
        let counts: [String: Int] = try before.read { db in
            var out: [String: Int] = [:]
            for table in ["accounts", "threads", "messages", "message_bodies", "message_search_docs", "snippets", "contacts", "settings"] {
                out[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
            }
            return out
        }
        try before.close()

        let (store, _) = try openTemp(dir: dir)
        let facts = try store.read { db in
            (applied: try MailStore.migrator().appliedMigrations(db),
             compat: try Int.fetchOne(db, sql: "SELECT compat_level FROM schema_info") ?? -1,
             fk: try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
             integrity: try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "",
             snippet: try Row.fetchOne(db, sql: "SELECT * FROM snippets WHERE snippet_id = 'fixture-snippet-1'"),
             body: try String.fetchOne(db, sql: "SELECT text FROM message_bodies WHERE mid = 1"),
             counts: try ["accounts", "threads", "messages", "message_bodies", "message_search_docs", "snippets", "contacts",
                          "settings"].reduce(into: [String: Int]()) { out, table in
                 out[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
             })
        }
        #expect(facts.applied == ["v1", "v2"])
        #expect(facts.compat == 1)
        #expect(facts.fk == 0)
        #expect(facts.integrity == "ok")
        for (table, n) in counts { #expect(facts.counts[table] == n, "\(table) lost rows") }
        let snippet = try #require(facts.snippet)
        #expect(snippet["name"] as String == "Fixture snippet" && snippet["use_count"] as Int == 3)
        #expect(snippet["to_json"] as String == "[]" && snippet["cc_json"] as String == "[]")
        #expect(snippet["bcc_json"] as String == "[]" && snippet["attachments_json"] as String == "[]")
        #expect(facts.body?.contains("second line") == true)
        #expect(try store.read { try String.fetchOne($0, sql: "SELECT text_format FROM message_bodies WHERE mid = 1") } == "fixed")
        #expect(try store.body(MessageRowID(rawValue: 1))?.textFormat == .fixed)
        let item = try #require(try store.snippets(account: nil).first { $0.id == "fixture-snippet-1" })
        #expect(item.to.isEmpty && item.cc.isEmpty && item.bcc.isEmpty && item.attachments.isEmpty)
        #expect(item.variables == [SnippetVariable(name: "first_name", defaultValue: "there")])
        #expect(try store.accounts().map(\.email) == ["fixture@example.com"])
        let waiting = try store.read { try Row.fetchOne($0, sql: "SELECT kind, sort_direction, total_threads FROM labels WHERE key = 'oh:waiting'") }
        #expect(waiting?["kind"] as String? == "virtual" && waiting?["sort_direction"] as Int? == 1)
        #expect(waiting?["total_threads"] as Int? == 0)
        #expect(try store.read { try String.fetchOne($0, sql: "SELECT state FROM maintenance_tasks WHERE task = ?",
                                                    arguments: [MailStore.participantsTask]) } == "done")
    }

    @Test func theSearchIndexIsUntouchedByV2() throws {
        let dir = try copyOfV1Fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, _) = try openTemp(dir: dir)
        let hits = try store.read { db in
            try Int64.fetchAll(db, sql: "SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?", arguments: ["\"fixture body\""])
        }
        #expect(hits == [1], "the v1 row is still in the trigram index")
        let v1Only = try DatabaseQueue()
        var v1 = DatabaseMigrator()
        v1.registerMigration("v1") { db in try db.execute(sql: SchemaV1.sql) }
        try v1.migrate(v1Only)
        let ftsObjects = "('messages_fts', 'message_search_docs', 'message_search_docs_ai', 'message_search_docs_ad', 'message_search_docs_au')"
        let sql = "SELECT name, sql FROM sqlite_master WHERE name IN \(ftsObjects) ORDER BY name"
        let migrated = try store.read { try Row.fetchAll($0, sql: sql).map { "\($0["name"] as String)|\($0["sql"] as String)" } }
        let original = try v1Only.read { try Row.fetchAll($0, sql: sql).map { "\($0["name"] as String)|\($0["sql"] as String)" } }
        #expect(migrated == original)
        #expect(migrated.count == 5)
    }

    @Test func aV1OnlyBinaryOpensAV2FileAsIs() throws {
        let (store, dir) = try openTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.addAccount(email: "v2@example.com", displayName: nil, scopes: [])
        try store.close()
        let pool = try DatabasePool(path: store.location.databaseURL.path)
        var v1Only = DatabaseMigrator()
        v1Only.registerMigration("v1") { db in try db.execute(sql: SchemaV1.sql) }
        try MailStore.migrateIfNeeded(pool, migrator: v1Only)
        #expect(try pool.read { try String.fetchAll($0, sql: "SELECT email FROM accounts") } == ["v2@example.com"])
        #expect(try pool.read { db in try db.columns(in: "snippets").contains { $0.name == "attachments_json" } })
        #if DEBUG
        #expect(!MailStore.schemaChangeWouldErase(store.location, migrator: v1Only))
        #endif
    }

    @Test func aFreshStoreAndAMigratedV1StoreHaveTheSameSchema() throws {
        let dir = try copyOfV1Fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (migrated, _) = try openTemp(dir: dir)
        let fresh = try MailStore.openInMemoryForTesting()
        #expect(try migrated.read(schemaDump) == fresh.read(schemaDump))
    }
}
