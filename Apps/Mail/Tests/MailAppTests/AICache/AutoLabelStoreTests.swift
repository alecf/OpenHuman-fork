import Foundation
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanStore
import SQLite3
import Testing
@testable import OpenHumanMail

@Suite struct AutoLabelStoreTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oh-auto-labels-\(UUID().uuidString)", isDirectory: true)
    }

    static func entry(_ account: Int64, _ thread: String, category: String? = "News", version: Int = 1) -> AutoLabelEntry {
        AutoLabelEntry(account: AccountID(account), thread: GmailThreadID(thread), latestMessage: GmailMessageID("m-\(thread)"),
                       promptVersion: version, modelID: "local.test|1", category: category, source: .model,
                       classifiedAt: Date(timeIntervalSince1970: 1_791_000_000))
    }

    @Test func rowsRoundTripSurviveARelaunchAndPurgePerAccount() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLiteAutoLabelStore.fileName)
        let store = try SQLiteAutoLabelStore(url: url)
        try await store.put([Self.entry(1, "t1"), Self.entry(1, "t2", category: nil), Self.entry(2, "t3", category: "Pitch")])
        try await store.put([Self.entry(1, "t1", category: "Respond", version: 2)])
        #expect(await store.count == 3)
        let reopened = try SQLiteAutoLabelStore(url: url)
        let t1 = try #require(try await reopened.entry(account: AccountID(1), thread: GmailThreadID("t1")))
        #expect(t1.category == "Respond" && t1.promptVersion == 2 && t1.source == .model)
        #expect(try await reopened.entry(account: AccountID(1), thread: GmailThreadID("t2"))?.category == nil)
        #expect(try await reopened.accountIDs() == [AccountID(1), AccountID(2)])
        try await reopened.removeAll(account: AccountID(2))
        #expect(try await reopened.accountIDs() == [AccountID(1)])
        try await reopened.removeAll()
        #expect(await reopened.count == 0)
        #expect(SQLiteAutoLabelStore.fileName == "classification.sqlite")
    }

    @Test func theFileIsPrivateOutOfBackupsAndADamagedOneIsSetAside() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLiteAutoLabelStore.fileName)
        _ = try SQLiteAutoLabelStore(url: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try Data("not a database".utf8).write(to: url)
        let fresh = try SQLiteAutoLabelStore(url: url)
        #expect(await fresh.count == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.contains("damaged") })
    }

    @Test func versionTwoKeepsRejectionsAndMigratesAVersionOneFileInPlace() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(SQLiteAutoLabelStore.fileName)
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        let v1 = """
            CREATE TABLE auto_labels (account_id INTEGER NOT NULL, thread_id TEXT NOT NULL,
                latest_message_id TEXT NOT NULL, prompt_version INTEGER NOT NULL, model_id TEXT NOT NULL, category TEXT,
                source TEXT NOT NULL, classified_at REAL NOT NULL, PRIMARY KEY (account_id, thread_id));
            INSERT INTO auto_labels VALUES (1, 't-old', 'm-old', 1, 'local.test|1', 'Pitch', 'model', 1791000000);
            PRAGMA user_version = 1;
            """
        #expect(sqlite3_exec(handle, v1, nil, nil, nil) == SQLITE_OK)
        sqlite3_close_v2(handle)
        let store = try SQLiteAutoLabelStore(url: url)
        #expect(await store.userVersion == 3)
        let old = try #require(try await store.entry(account: AccountID(1), thread: GmailThreadID("t-old")))
        #expect(old.category == "Pitch" && old.rejected.isEmpty && !old.writtenToGmail)
        var corrected = Self.entry(1, "t-old", category: nil)
        corrected.source = .user
        corrected.rejected = ["Pitch", "Marketing"]
        corrected.writtenToGmail = true
        try await store.put([corrected])
        let reopened = try SQLiteAutoLabelStore(url: url)
        let read = try #require(try await reopened.entry(account: AccountID(1), thread: GmailThreadID("t-old")))
        #expect(read.source == .user && read.category == nil && read.rejected == ["Marketing", "Pitch"] && read.writtenToGmail)
        #expect(read.rejects("pitch") && !read.rejects("News") && !read.rejects(nil))
        let version = await reopened.userVersion
        let count = await reopened.count
        #expect(version == 3 && count == 1)
        #expect(AutoLabelRejections.encode([]) == nil && AutoLabelRejections.decode("Pitch,nonsense") == ["Pitch"])
    }

    @Test func theCategoryMatcherReadsOurLabelFirstAndNothingWhileOff() {
        let matcher = CategoryImportanceMatcher()
        let account = AccountID(1)
        let ours = GmailLabelID("Label_ours")
        let facts = ImportanceFacts(accountID: account, messages: [
            ImportanceMessageFacts(to: [], cc: [], date: Date(), isFromMe: false, isUnread: true, labelIDs: [ours],
                                   subject: "synthetic"),
        ], threadID: GmailThreadID("t1"))
        matcher.update(AutoLabelIndex(isOn: false, ourLabels: [account: [ours: "Marketing"]]))
        #expect(!matcher.matches(facts, argument: "marketing"), "off: matches nothing")
        let changed = matcher.update(AutoLabelIndex(isOn: true, ourLabels: [account: [ours: "Marketing"]],
                                                    threads: [account: [GmailThreadID("t1"): "News"]]))
        #expect(changed, "on/off and this Mac's results re-evaluate importance")
        #expect(matcher.matches(facts, argument: "marketing"), "the Gmail label wins over this Mac's older result")
        #expect(!matcher.matches(facts, argument: "news"))
        #expect(!matcher.matches(facts, argument: "not-a-category"))
        #expect(matcher.id == "category" && !matcher.readsText)
    }
}
