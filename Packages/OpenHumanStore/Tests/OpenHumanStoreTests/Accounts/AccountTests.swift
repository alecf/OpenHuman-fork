import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct AccountTests {
    private func splitRows(_ store: MailStore, _ account: AccountID) throws -> [Row] {
        try store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.*, l.key AS label_key, l.kind AS label_kind FROM splits s JOIN labels l ON l.label_rid = s.label_rid
                WHERE s.account_id = ? ORDER BY s.position
                """, arguments: [account.rawValue])
        }
    }

    @Test func addAccountCreatesVirtualLabelsSyncStateAndTheDefaultSplits() throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: "Me", scopes: ["gmail.readonly"])
        let keys = try store.labels(account: account).map(\.key)
        for key in ["oh:allmail", "oh:snoozed", "oh:scheduled", "oh:reminders", "oh:split:other"] { #expect(keys.contains(key), "\(key)") }
        let splits = try splitRows(store, account)
        #expect(splits.count == 2)
        let important = try #require(splits.first)
        #expect(important["name"] as String == "Important" && important["rule_text"] as String == "is:important")
        #expect(important["position"] as Int == 0 && important["enabled"] as Int == 1)
        #expect(important["role"] as String? == "important")
        #expect((important["label_key"] as String) == "oh:split:" + (important["split_id"] as String))
        #expect(important["label_kind"] as String == "split")
        let rule = try JSONDecoder().decode(SplitRule.self, from: Data((important["rule_json"] as String).utf8))
        #expect(rule == .isImportant)
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_state WHERE account_id = ?", arguments: [account.rawValue]) } == 1)
    }

    @Test func addAccountSeedsACalendarSplitHiddenWhileEmpty() throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: "Me", scopes: ["gmail.readonly"])
        let calendar = try #require(try splitRows(store, account).last)
        #expect(calendar["name"] as String == "Calendar" && calendar["rule_text"] as String == "is:event")
        #expect(calendar["position"] as Int == 1 && calendar["enabled"] as Int == 1)
        #expect(calendar["role"] as String? == nil, "only Important is the importance split")
        #expect((calendar["label_key"] as String) == "oh:split:" + (calendar["split_id"] as String))
        let rule = try JSONDecoder().decode(SplitRule.self, from: Data((calendar["rule_json"] as String).utf8))
        #expect(rule == .isEvent)
        #expect(try store.setting(.hideSplitWhenEmpty, scope: .account(account)) == [calendar["split_id"] as String])
        #expect(try store.splits(account: account).map(\.name) == ["Important", "Calendar"])
    }

    @Test func aCalendarInviteLandsInTheSeededCalendarSplitAndAnImportantOneStaysInImportant() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        func invite(_ id: String, labels: [String]) -> MessageUpsert {
            .fixture(id, thread: "t-\(id)", labels: labels,
                     body: MessageBodyUpsert(text: "x", hasCalendarInvite: true, decodeWarnings: [], searchText: "x"))
        }
        _ = try store.upsertMessages([invite("plain", labels: ["INBOX"]), invite("vip", labels: ["INBOX", "IMPORTANT"]),
                                      .fixture("other", thread: "t-other", labels: ["INBOX"])],
                                     account: account, generation: 1)
        let splits = try store.splits(account: account)
        let calendar = try #require(splits.first { $0.name == "Calendar" })
        let important = try #require(splits.first { $0.name == "Important" })
        #expect(calendar.totalThreads == 2, "both invites: the events split lists the important one too")
        #expect(important.totalThreads == 1, "importance comes first: the important invite stays in Important")
        let other = try #require(try store.label(account: account, key: "oh:split:other"))
        #expect(other.totalThreads == 1, "the plain message only")
    }

    @Test func readdingAnAccountDoesNotDuplicateOrRestoreTheSplits() throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: ["a"])
        #expect(try store.addAccount(email: "ME@example.com", displayName: nil, scopes: ["a", "b"]) == account)
        #expect(try splitRows(store, account).count == 2)
        try store.write { try $0.execute(sql: "DELETE FROM splits") }
        _ = try store.addAccount(email: "me@example.com", displayName: nil, scopes: ["a", "b"])
        #expect(try splitRows(store, account).isEmpty, "seeding happens only at account creation")
    }

    @Test func eachAccountGetsItsOwnSplits() throws {
        let store = try MailStore.openInMemoryForTesting()
        let a = try store.addAccount(email: "a@example.com", displayName: nil, scopes: [])
        let b = try store.addAccount(email: "b@example.com", displayName: nil, scopes: [])
        #expect(try splitRows(store, a).count == 2 && splitRows(store, b).count == 2)
        #expect(try splitRows(store, a)[0]["split_id"] as String != splitRows(store, b)[0]["split_id"] as String)
        #expect(try store.setting(.hideSplitWhenEmpty, scope: .account(a)) != store.setting(.hideSplitWhenEmpty, scope: .account(b)))
    }

    @Test func removalDeletesInChunksReportsMonotonicProgressAndSparesOtherAccounts() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        let other = try store.addAccount(email: "other@example.com", displayName: nil, scopes: [])
        try store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: other, removeMissing: false)
        _ = try store.upsertMessages((1...11).map { .fixture("m\($0)", thread: "t\($0)", minutes: $0, labels: ["INBOX", "UNREAD"]) },
                                     account: account, generation: 1)
        _ = try store.upsertMessages([.fixture("o1", labels: ["INBOX"])], account: other, generation: 1)
        try store.setSetting(.bodyHorizonDays, 7, scope: .account(account))
        nonisolated(unsafe) var seen: [Double] = []
        try store.removeAccountData(account, chunk: 3) { seen.append($0) }
        #expect(seen.count >= 4 && seen.last == 1)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 })
        let facts = try store.read { db in
            (accounts: try String.fetchAll(db, sql: "SELECT email FROM accounts"),
             threads: try Int.fetchOne(db, sql: "SELECT count(*) FROM threads") ?? -1,
             messages: try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1,
             labels: try Int.fetchOne(db, sql: "SELECT count(*) FROM labels WHERE account_id = ?", arguments: [account.rawValue]) ?? -1,
             splits: try Int.fetchOne(db, sql: "SELECT count(*) FROM splits WHERE account_id = ?", arguments: [account.rawValue]) ?? -1)
        }
        #expect(facts.accounts == ["other@example.com"])
        #expect(facts.threads == 1 && facts.messages == 1 && facts.labels == 0 && facts.splits == 0)
        #expect(try store.thread(account: other, gmailThreadID: GmailThreadID("t-o1")) != nil)
        #expect(try store.label(account: other, key: "INBOX")?.totalThreads == 1)
    }

    @Test func removalDeletesTheAttachmentDirectoryAndMarksTheAccountRemovingFirst() throws {
        let (store, dir) = try openTemp(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let attachments = store.location.attachmentsDirectory.appendingPathComponent(String(account.rawValue)).appendingPathComponent("m1/1")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: attachments.appendingPathComponent("a.txt"))
        let keep = store.location.attachmentsDirectory.appendingPathComponent("999")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        nonisolated(unsafe) var statusDuring: String?
        try store.removeAccountData(account) { _ in
            statusDuring = statusDuring ?? (try? store.read { try String.fetchOne($0, sql: "SELECT status FROM accounts") }) ?? "gone"
        }
        #expect(statusDuring == "removing" || statusDuring == "gone")
        #expect(!FileManager.default.fileExists(atPath: store.location.attachmentsDirectory.appendingPathComponent(String(account.rawValue)).path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func removalDeletesTheAccountsDraftFoldersOnly() throws {
        let (store, dir) = try openTemp(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let other = try store.addAccount(email: "other@example.com", displayName: nil, scopes: [])
        let mine = UUID().uuidString, theirs = UUID().uuidString
        try store.write { db in
            for (uuid, owner) in [(mine, account), (theirs, other)] {
                try db.execute(sql: "INSERT INTO drafts (draft_uuid, account_id, created_at, updated_at) VALUES (?, ?, 0, 0)",
                               arguments: [uuid, owner.rawValue])
            }
        }
        for uuid in [mine, theirs] {
            let folder = store.location.draftsDirectory.appendingPathComponent(uuid, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("draft.json"))
        }
        try store.removeAccountData(account) { _ in }
        #expect(!FileManager.default.fileExists(atPath: store.location.draftsDirectory.appendingPathComponent(mine).path))
        #expect(FileManager.default.fileExists(atPath: store.location.draftsDirectory.appendingPathComponent(theirs).path))
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM drafts") } == 1)
    }

    @Test func filesThatCannotBeDeletedKeepTheAccountForARetry() throws {
        let (store, dir) = try openTemp(kind: .app)
        let files = FileManager.default
        let locks = [store.location.attachmentsDirectory, store.location.draftsDirectory]
        defer {
            for folder in locks { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            try? files.removeItem(at: dir)
        }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let draft = UUID().uuidString
        try store.write { db in
            try db.execute(sql: "INSERT INTO drafts (draft_uuid, account_id, created_at, updated_at) VALUES (?, ?, 0, 0)",
                           arguments: [draft, account.rawValue])
        }
        let attachments = store.location.attachmentsDirectory.appendingPathComponent(String(account.rawValue), isDirectory: true)
        try files.createDirectory(at: attachments.appendingPathComponent("m1/1"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: attachments.appendingPathComponent("m1/1/a.txt"))
        let draftFolder = store.location.draftsDirectory.appendingPathComponent(draft, isDirectory: true)
        try files.createDirectory(at: draftFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: draftFolder.appendingPathComponent("draft.json"))

        for locked in locks {
            try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            #expect(throws: (any Error).self, "\(locked.lastPathComponent)") { try store.removeAccountData(account) { _ in } }
            #expect(try store.accounts().first { $0.id == account }?.status == .removing)
            #expect(try store.read {
                try Int.fetchOne($0, sql: "SELECT count(*) FROM drafts WHERE draft_uuid = ?", arguments: [draft])
            } == 1)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        #expect(!files.fileExists(atPath: attachments.path), "the first retry deleted the attachments")
        #expect(files.fileExists(atPath: draftFolder.path))

        try store.removeAccountData(account) { _ in }
        #expect(try store.accounts().isEmpty)
        #expect(!files.fileExists(atPath: draftFolder.path))
    }

    @Test func removalWithoutAnyFilesOnDiskSucceeds() throws {
        let (store, dir) = try openTemp(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        try store.write { db in
            try db.execute(sql: "INSERT INTO drafts (draft_uuid, account_id, created_at, updated_at) VALUES (?, ?, 0, 0)",
                           arguments: [UUID().uuidString, account.rawValue])
        }
        try store.removeAccountData(account) { _ in }
        #expect(try store.accounts().isEmpty)
    }

    @Test func theAliasIsSetAndCleared() throws {
        let store = try MailStore.openInMemoryForTesting()
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        try store.setAccountAlias(account, "Work")
        #expect(try store.accounts().first?.alias == "Work")
        try store.setAccountAlias(account, nil)
        #expect(try store.accounts().first?.alias == nil)
        #expect(throws: StoreError.notFound("account 42")) { try store.setAccountAlias(AccountID(42), "x") }
    }

    @Test func removingAnUnknownAccountThrowsNotFound() throws {
        let store = try MailStore.openInMemoryForTesting()
        #expect(throws: StoreError.notFound("account 42")) { try store.removeAccountData(AccountID(42)) { _ in } }
    }
}
