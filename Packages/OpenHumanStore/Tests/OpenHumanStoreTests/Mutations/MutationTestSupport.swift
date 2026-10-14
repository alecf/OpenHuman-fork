import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

struct MutationFixture {
    let store: MailStore
    let account: AccountID

    init() throws {
        (store, account) = try OpenHumanStoreTesting.storeWithAccount()
    }

    func labels(_ list: [(String, String)]) throws {
        try store.upsertLabels(list.map { LabelUpsert(gmailLabelID: GmailLabelID($0.0), name: $0.1, type: "user") },
                               account: account, removeMissing: false)
    }

    @discardableResult
    func upsert(_ messages: [MessageUpsert]) throws -> UpsertResult {
        try store.upsertMessages(messages, account: account, generation: 1)
    }

    @discardableResult
    func seed(_ count: Int = 3) throws -> [ThreadRef] {
        try upsert((1...count).map { .fixture("m\($0)", thread: "t\($0)", minutes: $0, labels: ["INBOX", "UNREAD"]) })
        return try (1...count).map { try ref("t\($0)") }
    }

    func ref(_ thread: String) throws -> ThreadRef {
        try #require(try store.thread(account: account, gmailThreadID: GmailThreadID(thread)))
    }

    func view(_ box: SystemMailbox) throws -> [String] {
        try store.threadPage(view: .system(account, box), after: nil, limit: 200).items.map(\.ref.gmailThreadID.rawValue)
    }

    func inbox() throws -> [String] { try view(.inbox) }

    func effective(_ message: String) throws -> Set<String> { try labelSets(message).effective }
    func server(_ message: String) throws -> Set<String> { try labelSets(message).server }

    func labelSets(_ message: String) throws -> (effective: Set<String>, server: Set<String>) {
        try store.read { db in
            let row = try #require(try Row.fetchOne(db, sql: """
                SELECT label_ids, server_label_ids FROM messages WHERE gmail_message_id = ?
                """, arguments: [message]))
            return (Labels.split(row["label_ids"]), Labels.split(row["server_label_ids"]))
        }
    }

    func op(_ id: OperationID) throws -> OperationItem { try #require(try store.operation(id)) }

    func ops(_ statuses: Set<OperationStatus> = []) throws -> [OperationItem] {
        try store.operations(account: account, statuses: statuses, limit: 500)
    }

    func links(_ op: OperationID) throws -> Int {
        try store.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM pending_op_messages WHERE op_id = ?", arguments: [op.rawValue]) ?? 0
        }
    }

    func raw(_ sql: String, _ arguments: StatementArguments = []) throws -> [Row] {
        try store.read { try Row.fetchAll($0, sql: sql, arguments: arguments) }
    }

    func threadRow(_ thread: String) throws -> Row {
        try #require(try raw("SELECT * FROM threads WHERE gmail_thread_id = ?", [thread]).first)
    }

    func draftRow(_ id: DraftID) throws -> Row {
        try #require(try raw("SELECT * FROM drafts WHERE draft_uuid = ?", [id.rawValue]).first)
    }

    func snoozeRow(_ thread: String) throws -> Row? {
        try raw("SELECT s.* FROM snoozes s JOIN threads t USING (tid) WHERE t.gmail_thread_id = ?", [thread]).first
    }

    func reminders(_ thread: String) throws -> [Row] {
        try raw("""
            SELECT r.* FROM reminders r JOIN threads t ON t.tid = r.tid WHERE t.gmail_thread_id = ? ORDER BY r.set_at, r.rowid
            """, [thread])
    }

    func setting(markUnread: Bool) throws {
        try store.setSetting(.snoozeMarkUnread, markUnread, scope: .global)
    }

    @discardableResult
    func claim(_ now: Date = Date().addingTimeInterval(1)) throws -> [OperationItem] {
        try store.claimReadyOperations(account: account, now: now, limit: 500, ownerID: "test-owner")
    }

    @discardableResult
    func drain(now: Date = Date().addingTimeInterval(1)) throws -> [OperationItem] {
        var done: [OperationItem] = []
        var round = 0
        while round < 20 {
            round += 1
            let batch = try claim(now)
            if batch.isEmpty { break }
            for op in batch {
                try store.complete(op.id, outcome: outcome(for: op))
                done.append(op)
            }
        }
        return done
    }

    func outcome(for op: OperationItem) throws -> OperationOutcome {
        switch op.payload {
        case .modifyLabels, .trash, .untrash: return .labelsApplied
        case let .createLabel(name):
            return .labelCreated(LabelUpsert(gmailLabelID: GmailLabelID("Label_\(abs(name.hashValue % 1_000_000))_\(op.id.rawValue)"),
                                             name: name, type: "user"))
        case let .upsertDraft(id, version):
            let row = try draftRow(id)
            let gmailDraft = (row["gmail_draft_id"] as String?) ?? "r-\(id.rawValue.prefix(8))"
            return .draftSaved(gmailDraftID: GmailDraftID(gmailDraft), gmailMessageID: GmailMessageID("dm-\(op.id.rawValue)"),
                               version: version)
        case .deleteDraft: return .draftDeleted
        case .sendDraft: throw StoreError.conflict("the test drainer never sends")
        }
    }

    static func content(_ subject: String = "Hello", body: String = "<p>Hi</p>", to: String = "bob@example.com") -> DraftContent {
        DraftContent(from: EmailAddress(email: "me@example.com"), to: [EmailAddress(name: "Bob", email: to)], cc: [], bcc: [],
                     subject: subject, bodyHTML: body, bodyText: nil, attachments: [])
    }

    func newDraft(origin: DraftOrigin = .user, review: DraftReviewState = .none, replyTo: String? = nil,
                  note: String? = nil, headers: [String: String] = [:]) throws -> DraftID {
        try store.createDraft(account: account, mode: replyTo == nil ? .new : .reply,
                              replyTo: replyTo.map { GmailMessageID($0) }, content: Self.content(), origin: origin,
                              reviewState: review, agentNote: note, extraHeaders: headers)
    }

    func syncedDraft(origin: DraftOrigin = .user, review: DraftReviewState = .none, replyTo: String? = nil) throws -> DraftID {
        let id = try newDraft(origin: origin, review: review, replyTo: replyTo)
        _ = try store.saveDraftRemotely(id)
        try drain()
        return id
    }
}

let snooze9 = "OpenHuman/Snoozed/20261012T0900Z"
let snooze10 = "OpenHuman/Snoozed/20261012T1000Z"
let nine = Date(timeIntervalSince1970: 1_791_795_600)
let ten = nine.addingTimeInterval(3600)

func epochMillis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
