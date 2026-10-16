import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

private func tempStore(kind: ProcessKind = .test, readOnly: Bool = false, dir: URL? = nil) throws -> (MailStore, URL) {
    let directory = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("oh-store-\(UUID().uuidString)")
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: kind,
                                                readOnly: readOnly, appVersion: "0.0.0-test"))
    return (store, directory)
}

@Suite struct SchemaTests {
    @Test func inMemoryHasAllTables() throws {
        let store = try MailStore.openInMemoryForTesting()
        let tables = try store.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for t in ["accounts", "labels", "threads", "thread_labels", "messages", "message_bodies", "attachments",
                  "message_search_docs", "messages_fts", "deleted_messages", "contacts", "drafts", "snippets",
                  "pending_operations", "pending_op_messages", "snoozes", "reminders", "sync_lease", "splits",
                  "sync_state", "sync_log", "settings", "schema_info", "change_feed", "observation_pulse",
                  "maintenance_tasks"] {
            #expect(tables.contains(t), "missing \(t)")
        }
    }

    @Test func fileDatabaseConfiguration() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (journal, vacuum, fk) = try store.read { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode")!, try Int.fetchOne(db, sql: "PRAGMA auto_vacuum")!,
             try Int.fetchOne(db, sql: "PRAGMA foreign_keys")!)
        }
        #expect(journal == "wal")
        #expect(vacuum == 2)
        #expect(fk == 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
    }

    @Test func fts5TrigramAvailable() throws {
        let store = try MailStore.openInMemoryForTesting()
        try store.read { db in
            let version = try String.fetchOne(db, sql: "SELECT sqlite_version()")!
            let parts = version.split(separator: ".").compactMap { Int($0) }
            #expect(parts[0] > 3 || (parts[0] == 3 && parts[1] >= 34), "sqlite \(version)")
            let opts = try String.fetchAll(db, sql: "PRAGMA compile_options")
            #expect(opts.contains("ENABLE_FTS5"))
        }
    }

    @Test func reopenKeepsDataAndChangeFeedBumps() throws {
        let (store, dir) = try tempStore(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let seq = try store.read { db in
            try Int.fetchOne(db, sql: "SELECT seq FROM change_feed WHERE writer_id = ?", arguments: [store.writerID])!
        }
        #expect(seq >= 1)
        try store.close()
        let (again, _) = try tempStore(dir: dir)
        #expect(try again.accounts().map(\.id) == [account])
        let writers = try again.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM change_feed")! }
        #expect(writers == 2)
    }

    @Test func schemaTooNewIsRejected() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.write { try $0.execute(sql: "UPDATE schema_info SET compat_level = 99") }
        try store.close()
        #expect(throws: StoreError.schemaTooNew(found: 99, supported: 1)) { try tempStore(dir: dir) }
    }

    @Test func readOnlyRejectsWrites() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        try store.close()
        let (ro, _) = try tempStore(readOnly: true, dir: dir)
        #expect(try ro.accounts().count == 1)
        #expect(throws: StoreError.readOnly) { try ro.addAccount(email: "x@example.com", displayName: nil, scopes: []) }
    }

    @Test func fkCascadeFiresCountTriggers() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([.fixture("m1", labels: ["INBOX", "UNREAD"])], account: account, generation: 1)
        let inbox = try #require(try store.label(account: account, key: "INBOX"))
        #expect(inbox.totalThreads == 1 && inbox.unreadThreads == 1)
        try store.write { try $0.execute(sql: "DELETE FROM threads") }
        let after = try #require(try store.label(account: account, key: "INBOX"))
        #expect(after.totalThreads == 0 && after.unreadThreads == 0)
    }

    @Test func fkCascadeFiresSearchDocTrigger() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([.fixture("m1")], account: account, generation: 1)
        try store.write { db in
            let mid = try Int64.fetchOne(db, sql: "SELECT mid FROM messages")!
            try db.execute(sql: """
                INSERT INTO message_search_docs (mid, subject, body) VALUES (?, 'hello world', 'abcdef')
                ON CONFLICT (mid) DO UPDATE SET subject = excluded.subject, body = excluded.body
                """, arguments: [mid])
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'abcdef'") == 1)
            try db.execute(sql: "DELETE FROM messages")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'abcdef'") == 0)
        }
    }

    @Test func resolveHonorsAHomeDirectory() throws {
        let loc = try StoreLocation.resolve(home: "/tmp/oh-home")
        #expect(loc.directory.path == "/tmp/oh-home")
        let def = try StoreLocation.resolve(home: nil)
        #expect(def.directory.path.hasSuffix("Application Support/OpenHuman/Mail"))
    }
}
