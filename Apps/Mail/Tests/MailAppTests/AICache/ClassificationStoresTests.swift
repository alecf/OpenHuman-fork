import Foundation
import MailFeatures
import MailModel
import OpenHumanAI
import OpenHumanCore
import SQLite3
import Testing
@testable import OpenHumanMail

@Suite struct ClassificationStoresTests {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oh-classification-\(UUID().uuidString)", isDirectory: true)
    }

    static let now = Date(timeIntervalSince1970: 1_797_200_000)

    static func decision(_ thread: String, at: Date = now, text: String? = nil) -> ClassificationDecision {
        ClassificationDecision(account: AccountID(1), thread: GmailThreadID(thread), latestMessage: GmailMessageID("m-\(thread)"),
                               decidedAt: at, decidedBy: "model", ruleSetVersion: 2, promptID: "autolabel.classify",
                               promptVersion: 2, providerID: "local.test", modelID: "1",
                               featuresJSON: #"{"recipientCount":1,"senderDomain":"people.example"}"#,
                               constraintsJSON: #"{"by":{"default.bulk.never-respond":["respond"]},"forbidden":["respond"]}"#,
                               modelOutput: "Respond", outputLabel: nil, appliedState: .pending, textJSON: text)
    }

    @Test func theRuleSetKeepsVersionsAHeadAndABoundedHistory() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(SQLiteRulesStore.fileName)
        let store = try SQLiteRulesStore(url: url)
        #expect(try await store.head() == nil)
        let shipped = ClassificationConfig.shipped
        #expect(try await store.append(origin: "default", bodyJSON: try shipped.json(), digest: shipped.digest, note: nil,
                                       createdAt: Self.now, historyLimit: 3) == 1)
        let edited = shipped.settingDefault(DefaultRules.withYou, enabled: false)
        for _ in 0..<4 {
            _ = try await store.append(origin: "edit", bodyJSON: try edited.json(), digest: edited.digest, note: "Turned off",
                                       createdAt: Self.now, historyLimit: 3)
        }
        let reopened = try SQLiteRulesStore(url: url)
        let head = try #require(try await reopened.head())
        #expect(head.version == 5 && head.origin == "edit" && head.digest == edited.digest)
        #expect(try ClassificationConfig.decode(head.bodyJSON) == edited)
        #expect(try await reopened.versions(limit: 10).map(\.version) == [5, 4, 3])
        #expect(try await reopened.version(1) == nil, "pruned past the history limit")
        #expect(await reopened.userVersion == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true)
    }

    @Test func examplesRoundTripAreBoundedAndClear() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteRulesStore(url: dir.appendingPathComponent(SQLiteRulesStore.fileName))
        for n in 0..<4 {
            try await store.addExample(LabelledExample(id: "e\(n)", account: AccountID(1), thread: GmailThreadID("t\(n)"),
                                                       createdAt: Self.now.addingTimeInterval(Double(n)), expected: "news",
                                                       rejected: ["pitch"], was: "pitch", decisionID: 7,
                                                       sender: "ed@letters.example", senderDomain: "letters.example",
                                                       featuresJSON: #"{"messageCount":1}"#, scope: "list"),
                                       maxRows: 3)
        }
        let read = try await store.examples(limit: 10)
        #expect(read.map(\.id) == ["e3", "e2", "e1"])
        #expect(read[0].rejected == ["pitch"] && read[0].decisionID == 7 && read[0].scope == "list" && read[0].textJSON == nil)
        try await store.deleteExample(id: "e2")
        #expect(try await store.examples(limit: 10).count == 2)
        try await store.removeAllExamples()
        #expect(try await store.examples(limit: 10).isEmpty)
    }

    @Test func aVersionTwoFileBecomesVersionThreeInPlace() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(SQLiteAutoLabelStore.fileName)
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        let v2 = """
            CREATE TABLE auto_labels (account_id INTEGER NOT NULL, thread_id TEXT NOT NULL,
                latest_message_id TEXT NOT NULL, prompt_version INTEGER NOT NULL, model_id TEXT NOT NULL, category TEXT,
                source TEXT NOT NULL, classified_at REAL NOT NULL, rejected TEXT, written INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (account_id, thread_id));
            INSERT INTO auto_labels VALUES (1, 't-old', 'm-old', 2, 'local.test|1', 'News', 'model', 1791000000, 'Pitch', 1);
            PRAGMA user_version = 2;
            """
        #expect(sqlite3_exec(handle, v2, nil, nil, nil) == SQLITE_OK)
        sqlite3_close_v2(handle)
        let store = try SQLiteAutoLabelStore(url: url)
        #expect(await store.userVersion == 3)
        let old = try #require(try await store.entry(account: AccountID(1), thread: GmailThreadID("t-old")))
        #expect(old.category == "News" && old.rejected == ["Pitch"] && old.writtenToGmail)
        #expect(old.modelOutput == nil && old.ruleID == nil && old.ruleSetVersion == nil, "unknown for older rows")
        var next = old
        next.modelOutput = "Respond"
        next.ruleID = "user.x"
        next.ruleSetVersion = 4
        try await store.put([next])
        let reread = try #require(try await SQLiteAutoLabelStore(url: url).entry(account: AccountID(1), thread: GmailThreadID("t-old")))
        #expect(reread.modelOutput == "Respond" && reread.ruleID == "user.x" && reread.ruleSetVersion == 4)
    }

    @Test func theDecisionLogRoundTripsPrunesAndClears() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteAutoLabelStore(url: dir.appendingPathComponent(SQLiteAutoLabelStore.fileName))
        try await store.appendDecisions([Self.decision("t0", at: Self.now.addingTimeInterval(-181 * 86_400)),
                                         Self.decision("t1"), Self.decision("t2")],
                                        now: Self.now, maxRows: 100_000, maxDays: 180)
        #expect(try await store.decisionCount() == 2, "older than 180 days goes on append")
        let latest = try #require(try await store.latestDecision(account: AccountID(1), thread: GmailThreadID("t2")))
        #expect(latest.decidedBy == "model" && latest.ruleSetVersion == 2 && latest.modelOutput == "Respond"
            && latest.appliedState == .pending && latest.constraintsJSON?.contains("default.bulk.never-respond") == true)
        try await store.setApplied(account: AccountID(1), thread: GmailThreadID("t2"), latestMessage: GmailMessageID("m-t2"),
                                   state: .written, label: "respond")
        #expect(try await store.latestDecision(account: AccountID(1), thread: GmailThreadID("t2"))?.appliedState == .written)
        try await store.appendDecisions([Self.decision("t3"), Self.decision("t4")], now: Self.now, maxRows: 3, maxDays: 180)
        #expect(try await store.decisions(limit: 10).map(\.thread.rawValue) == ["t4", "t3", "t2"])
        try await store.removeAllDecisions()
        #expect(try await store.decisionCount() == 0)
    }

    @Test func noFixtureTextIsInEitherFileWithTheDefaults() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try SQLiteAutoLabelStore(url: dir.appendingPathComponent(SQLiteAutoLabelStore.fileName))
        let rules = try SQLiteRulesStore(url: dir.appendingPathComponent(SQLiteRulesStore.fileName))
        try await log.appendDecisions([Self.decision("t1")], now: Self.now, maxRows: 10, maxDays: 180)
        try await rules.addExample(LabelledExample(createdAt: Self.now, expected: "news",
                                                   featuresJSON: #"{"messageCount":2}"#), maxRows: 10)
        let stored = await log.decisionTextDump + rules.exampleTextDump
        for fixture in ["orchard", "Quarterly plan", "planting schedule"] {
            #expect(!stored.contains { $0.contains(fixture) })
        }
        try await log.appendDecisions([Self.decision("t2", text: #"{"subject":"Quarterly plan"}"#)], now: Self.now,
                                      maxRows: 10, maxDays: 180)
        #expect(await log.decisionTextDump.contains { $0.contains("Quarterly plan") })
    }
}
