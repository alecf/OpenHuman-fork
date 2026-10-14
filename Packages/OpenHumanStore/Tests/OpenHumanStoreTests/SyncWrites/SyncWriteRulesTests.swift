import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct SyncWriteRulesTests {
    @Test func aStaleWriteOnlyFillsEmptyHeadersButStillProvesTheMessageExists() throws {
        let f = try AggregationFixture()
        var bare = MessageUpsert.fixture("m1", labels: ["INBOX"], history: 10)
        bare.headers = nil
        try f.upsert([bare])
        var old = MessageUpsert.fixture("m1", labels: [], subject: "Filled", history: 5)
        old.headers?.listID = "<list.example>"
        let gen = try f.store.beginFullResync(account: f.account)
        let r = try f.store.upsertMessages([old], account: f.account, generation: gen)
        #expect(r.skippedStale == 1)
        let m = try #require(try f.store.message(account: f.account, gmailMessageID: GmailMessageID("m1")))
        #expect(m.labelIDs == [GmailLabelID("INBOX")] && m.subject == "Filled" && m.from?.email == "alice@example.com")
        #expect(try f.store.read { try Int.fetchOne($0, sql: "SELECT sync_generation FROM messages") } == gen)
        #expect(try f.store.sweepGeneration(account: f.account, olderThan: gen, newerThan: nil) == 0)
        try f.store.upsertMessages([.fixture("m1", labels: [], subject: "Other", history: 6)], account: f.account, generation: gen)
        #expect(try f.store.message(account: f.account, gmailMessageID: GmailMessageID("m1"))?.subject == "Filled")
    }

    @Test func deletesAndTheSweepCancelOpsThatLostEveryTarget() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t1"), .fixture("m2", thread: "t1", minutes: 1), .fixture("m3", thread: "t3")])
        let both = try f.op(["m1", "m2"], remove: ["INBOX"])
        let one = try f.op(["m3"], add: ["STARRED"])
        let inFlight = try f.op(["m1"], add: ["UNREAD"], status: "in_flight")
        _ = try f.store.deleteMessages([GmailMessageID("m1")], account: f.account, historyID: HistoryID(50))
        func status(_ op: Int64) throws -> (String, String?) {
            try f.store.read { db in
                let r = try #require(try Row.fetchOne(db, sql: "SELECT status, last_error_code FROM pending_operations WHERE op_id = ?",
                                                      arguments: [op]))
                return (r["status"], r["last_error_code"])
            }
        }
        #expect(try status(both).0 == "pending")
        #expect(try status(inFlight).0 == "in_flight")
        let gen = try f.store.beginFullResync(account: f.account)
        _ = try f.store.upsertMessages([.fixture("m2", thread: "t1", minutes: 1)], account: f.account, generation: gen)
        #expect(try f.store.sweepGeneration(account: f.account, olderThan: gen, newerThan: nil) == 1)
        #expect(try status(one) == ("cancelled", "target_gone"))
        #expect(try f.store.thread(account: f.account, gmailThreadID: GmailThreadID("t3")) == nil)
    }

    @Test func theSweepRunsInChunks() throws {
        let f = try AggregationFixture()
        for batch in 0..<6 {
            try f.upsert((0..<200).map { i in .fixture("m\(batch)-\(i)", thread: "t\(batch)-\(i % 20)", minutes: i) })
        }
        let gen = try f.store.beginFullResync(account: f.account)
        #expect(try f.store.sweepGeneration(account: f.account, olderThan: gen, newerThan: nil) == 1200)
        #expect(try f.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM threads") } == 0)
        #expect(try f.store.label(account: f.account, key: "INBOX")?.totalThreads == 0)
    }

    @Test func attachmentsAreReplacedAndKeepTheirDownloads() throws {
        let f = try AggregationFixture()
        func att(_ part: String, _ name: String, inline: Bool = false) -> AttachmentUpsert {
            AttachmentUpsert(partID: part, gmailAttachmentID: "g-\(part)-\(name)", filename: name, mimeType: "",
                             size: 10, contentID: inline ? "<img1@x>" : nil, isInline: inline)
        }
        var m = MessageUpsert.fixture("m1", body: .fixture())
        m.attachments = [att("1", "a.pdf"), att("2", "logo.png", inline: true)]
        try f.upsert([m])
        var row = try f.threadRow("t-m1")
        #expect(row["attachment_count"] as Int == 1)
        let aid = try #require(try f.store.read { try Int64.fetchOne($0, sql: "SELECT aid FROM attachments WHERE part_id = '1'") })
        try f.store.setAttachmentDownloaded(aid: aid, relativePath: "Attachments/1/m1/1/a.pdf")
        try f.store.storeBodies([(GmailMessageID("m1"), .fixture(), [att("1", "a.pdf"), att("3", "b.txt")])], account: f.account)
        let parts = try f.store.read { db in
            try Row.fetchAll(db, sql: "SELECT part_id, local_path, mime_type, content_id FROM attachments ORDER BY part_id")
        }
        #expect(parts.map { $0["part_id"] as String } == ["1", "3"])
        #expect(parts[0]["local_path"] as String? == "Attachments/1/m1/1/a.pdf")
        #expect(parts[0]["mime_type"] as String == "application/octet-stream")
        row = try f.threadRow("t-m1")
        #expect(row["attachment_count"] as Int == 2)
        #expect(try f.store.message(account: f.account, gmailMessageID: GmailMessageID("m1"))?.attachments.count == 2)
    }

    @Test func downloadPathsMustStayInsideTheStore() throws {
        let f = try AggregationFixture()
        for bad in ["/etc/passwd", "../x", "Attachments/../../x", "", "a//b"] {
            #expect(throws: StoreError.self) { try f.store.setAttachmentDownloaded(aid: 1, relativePath: bad) }
        }
        #expect(throws: StoreError.notFound("attachment 999")) {
            try f.store.setAttachmentDownloaded(aid: 999, relativePath: "Attachments/x")
        }
    }

    @Test func sendAsChangesRederiveFromMe() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t1", from: "work@corp.example", fromName: "Work Me"),
                      .fixture("m2", thread: "t1", minutes: 1, from: "bob@example.com", fromName: "Bob")])
        #expect(try f.store.thread(f.ref("t1"))?.participantsDisplay == "Bob, Work (2)")
        try f.store.updateSendAs(account: f.account, identities: [
            SendAsIdentity(email: "me@example.com", isDefault: true, isPrimary: true),
            SendAsIdentity(email: "Work@Corp.example", isDefault: false, isPrimary: false),
        ])
        #expect(try f.store.message(account: f.account, gmailMessageID: GmailMessageID("m1"))?.isFromMe == true)
        #expect(try f.store.thread(f.ref("t1"))?.participantsDisplay == "Bob (2)")
        try f.store.updateSendAs(account: f.account, identities: [])
        #expect(try f.store.message(account: f.account, gmailMessageID: GmailMessageID("m1"))?.isFromMe == false)
    }

    @Test func sendAsKeepsTheVerificationStatusAndOlderRowsStillRead() throws {
        let f = try AggregationFixture()
        try f.store.updateSendAs(account: f.account, identities: [
            SendAsIdentity(email: "me@example.com", isDefault: true, isPrimary: true, signatureHTML: "<div>Me</div>"),
            SendAsIdentity(email: "relay@corp.example", isDefault: false, isPrimary: false, verificationStatus: "pending"),
        ])
        var stored = try #require(try f.store.accounts().first { $0.id == f.account }).sendAs
        #expect(stored.map(\.verificationStatus) == [nil, "pending"])
        #expect(stored.map(\.signatureHTML) == ["<div>Me</div>", nil])
        try f.store.write { db in
            try db.execute(sql: "UPDATE accounts SET send_as_json = ? WHERE account_id = ?", arguments: [
                #"[{"email":"me@example.com","isDefault":true,"isPrimary":true,"name":"Me"}]"#, f.account.rawValue,
            ])
        }
        stored = try #require(try f.store.accounts().first { $0.id == f.account }).sendAs
        #expect(stored == [SendAsIdentity(email: "me@example.com", name: "Me", isDefault: true, isPrimary: true)])
    }

    @Test func labelRefreshesReaggregateOnlyWhereMeaningChanged() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX", "Label_5"])])
        #expect(try f.store.thread(f.ref("t1"))?.userLabelIDs.isEmpty == true)
        try f.labels([("Label_5", "Work")])
        let rid = try #require(try f.store.label(account: f.account, key: "Label_5")).id
        #expect(try f.store.thread(f.ref("t1"))?.userLabelIDs == [rid])
        #expect(try f.store.label(account: f.account, key: "Label_5")?.totalThreads == 1)
        try f.labels([("Label_5", "Work/Renamed")])
        #expect(try f.store.label(account: f.account, key: "Label_5")?.displayName == "Renamed")
        try f.labels([], removeMissing: true)
        #expect(try f.store.thread(f.ref("t1"))?.userLabelIDs.isEmpty == true)
        #expect(try f.keys("t1") == ["INBOX", "oh:allmail", "oh:split:other"])
    }

    @Test func syncLogDetailNeverKeepsAddresses() throws {
        let f = try AggregationFixture()
        try f.store.appendSyncLog(SyncLogEntry(accountID: f.account, startedAt: Date(), kind: "incremental", outcome: "error",
                                               errorCode: "http_400", detail: "bad recipient bob@example.com, 3 items"))
        #expect(try f.store.syncLog(account: f.account, limit: 1).first?.detail == "bad recipient <address>, 3 items")
        try f.store.updateSyncState(account: f.account) { $0.lastErrorMessage = "rejected: carol@example.com" }
        #expect(try f.store.syncStatus(account: f.account).lastError == "rejected: <address>")
    }
}
