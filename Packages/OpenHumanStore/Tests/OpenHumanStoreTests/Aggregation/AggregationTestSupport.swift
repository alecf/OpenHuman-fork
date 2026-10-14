import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

struct AggregationFixture {
    let store: MailStore
    let account: AccountID

    init() throws {
        (store, account) = try OpenHumanStoreTesting.storeWithAccount()
    }

    func labels(_ list: [(String, String)], removeMissing: Bool = false) throws {
        let user = list.map { LabelUpsert(gmailLabelID: GmailLabelID($0.0), name: $0.1, type: "user") }
        try store.upsertLabels(removeMissing ? OpenHumanStoreTesting.systemLabels + user : user, account: account,
                               removeMissing: removeMissing)
    }

    @discardableResult
    func upsert(_ messages: [MessageUpsert]) throws -> UpsertResult {
        try store.upsertMessages(messages, account: account, generation: 1)
    }

    func tid(_ thread: String) throws -> Int64 {
        try #require(try store.thread(account: account, gmailThreadID: GmailThreadID(thread))).rowID.rawValue
    }

    func ref(_ thread: String) throws -> ThreadRef {
        try #require(try store.thread(account: account, gmailThreadID: GmailThreadID(thread)))
    }

    func keys(_ thread: String) throws -> Set<String> {
        let t = try tid(thread)
        return Set(try store.read { db in
            try String.fetchAll(db, sql: """
                SELECT l.key FROM thread_labels tl JOIN labels l USING (label_rid) WHERE tl.tid = ?
                """, arguments: [t])
        })
    }

    func sortKeys(_ thread: String) throws -> [String: Int64] {
        let t = try tid(thread)
        return try store.read { db in
            var out: [String: Int64] = [:]
            for r in try Row.fetchAll(db, sql: """
                SELECT l.key, tl.sort_at FROM thread_labels tl JOIN labels l USING (label_rid) WHERE tl.tid = ?
                """, arguments: [t]) { out[r["key"]] = r["sort_at"] }
            return out
        }
    }

    func threadRow(_ thread: String) throws -> Row {
        let t = try tid(thread)
        return try #require(try store.read { try Row.fetchOne($0, sql: "SELECT * FROM threads WHERE tid = ?", arguments: [t]) })
    }

    func snooze(_ thread: String) throws -> ScheduleDerivation.Snooze? {
        let t = try tid(thread)
        return try store.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM snoozes WHERE tid = ?", arguments: [t]).map {
                ScheduleDerivation.Snooze(status: .init(rawValue: $0["status"]) ?? .malformed, wakeAt: $0["wake_at"],
                                          labelName: $0["label_name"], stampLabelCount: $0["stamp_label_count"])
            }
        }
    }

    func inbox() throws -> [String] { try view(.system(account, .inbox)) }

    func view(_ view: MailboxView) throws -> [String] {
        try store.threadPage(view: view, after: nil, limit: 100).items.map(\.ref.gmailThreadID.rawValue)
    }

    @discardableResult
    func op(_ messages: [String], add: [String] = [], remove: [String] = [], addNames: [String] = [],
            status: String = "pending") throws -> Int64 {
        try store.write { db in
            let payload = OperationPayload.modifyLabels(ids: messages.map { GmailMessageID($0) },
                                                        add: add.map { GmailLabelID($0) },
                                                        remove: remove.map { GmailLabelID($0) }, addNames: addNames)
            try db.execute(sql: """
                INSERT INTO pending_operations (account_id, kind, payload_json, status, created_at, updated_at)
                VALUES (?, 'modify_labels', ?, ?, 0, 0)
                """, arguments: [account.rawValue, OperationPayloadCodec.encode(payload), status])
            let op = db.lastInsertedRowID
            var mids = Set<Int64>(), tids = Set<Int64>()
            for m in messages {
                let r = try #require(try Row.fetchOne(db, sql: "SELECT mid, tid FROM messages WHERE gmail_message_id = ?",
                                                      arguments: [m]))
                try db.execute(sql: "INSERT INTO pending_op_messages (mid, op_id) VALUES (?, ?)", arguments: [r["mid"] as Int64, op])
                mids.insert(r["mid"]); tids.insert(r["tid"])
            }
            try LabelOverlay.recompute(mids: mids, in: db)
            try ThreadAggregator.refresh(tids: tids, in: db)
            return op
        }
    }

    func mutate(_ body: (Database) throws -> Void) throws {
        try store.write { db in
            try body(db)
            try ThreadAggregator.refresh(tids: Set(try Int64.fetchAll(db, sql: "SELECT tid FROM threads")), in: db)
        }
    }

    func remote(_ draft: String, message: String, thread: String, subject: String = "Draft",
                headers: [String: String] = [:]) -> RemoteDraftUpsert {
        RemoteDraftUpsert(gmailDraftID: GmailDraftID(draft), gmailMessageID: GmailMessageID(message),
                          gmailThreadID: GmailThreadID(thread),
                          content: DraftContent(from: EmailAddress(email: "me@example.com"),
                                                to: [EmailAddress(name: "Bob", email: "bob@example.com")], cc: [], bcc: [],
                                                subject: subject, bodyHTML: "<p>draft</p>", bodyText: nil, attachments: []),
                          extraHeaders: headers)
    }

    func draftRow(gmailDraftID: String) throws -> Row? {
        try store.read { try Row.fetchOne($0, sql: "SELECT * FROM drafts WHERE gmail_draft_id = ?", arguments: [gmailDraftID]) }
    }

    func draftRows() throws -> [Row] {
        try store.read { try Row.fetchAll($0, sql: "SELECT * FROM drafts ORDER BY created_at, draft_uuid") }
    }
}

let baseMillis: Int64 = 1_790_000_000_000

func millis(_ stamp: String) -> Int64 {
    Int64((ScheduleStamp.parse(stamp)?.timeIntervalSince1970 ?? 0) * 1000)
}
