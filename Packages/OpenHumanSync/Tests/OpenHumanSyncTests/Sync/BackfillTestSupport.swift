import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import SQLite3
import Synchronization
import Testing
@testable import OpenHumanSync

struct SeededMailbox: Sendable {
    var threads: [String] = []
    var inbox: Set<String> = []
    var archived: Set<String> = []
    var repliedByMe: Set<String> = []
    var starred: Set<String> = []
    var messages = 0
}

extension FakeGmail {
    func seedMailbox(count: Int, end: Date, spacing: Duration = .seconds(600)) -> SeededMailbox {
        var out = SeededMailbox()
        for n in 0..<count {
            let date = end.addingTimeInterval(-Double(count - 1 - n) * spacing.timeInterval)
            var labels = n % 5 == 0 ? ["CATEGORY_UPDATES"] : ["INBOX", "UNREAD"]
            if n % 13 == 0 { labels.append("STARRED") }
            let first = deliver(subject: "Seeded \(n)", body: "Seeded body \(n).", labels: labels, date: date)
            out.messages += 1
            out.threads.append(first.threadID)
            if n % 5 == 0 { out.archived.insert(first.threadID) } else { out.inbox.insert(first.threadID) }
            if n % 13 == 0 { out.starred.insert(first.threadID) }
            if n % 7 == 0 {
                deliver(from: "Bo Example <bo@example.com>", subject: "Re: Seeded \(n)", body: "Reply \(n).",
                        labels: n % 5 == 0 ? ["CATEGORY_UPDATES"] : ["INBOX"], threadID: first.threadID,
                        date: date.addingTimeInterval(60))
                out.messages += 1
            }
            if n % 11 == 0 {
                deliver(from: "Me <me@example.com>", to: "alice@example.com", subject: "Re: Seeded \(n)",
                        body: "My answer \(n).", labels: ["SENT"], threadID: first.threadID,
                        date: date.addingTimeInterval(120))
                out.repliedByMe.insert(first.threadID)
                out.messages += 1
            }
        }
        return out
    }
}

func serverMessageIDs(_ gmail: FakeGmail, q: String? = nil) async throws -> Set<String> {
    var ids = Set<String>()
    var token: String?
    repeat {
        let page = try await gmail.listMessages(ListQuery(q: q, pageToken: token, maxResults: 500), priority: .sync)
        ids.formUnion(page.messages?.map(\.id) ?? [])
        token = page.nextPageToken
    } while token != nil
    return ids
}

func serverThreads(_ gmail: FakeGmail, label: String? = nil) async throws -> [String] {
    var ids: [String] = []
    var token: String?
    repeat {
        let page = try await gmail.listThreads(ListQuery(labelIDs: label.map { [$0] } ?? [], pageToken: token,
                                                         maxResults: 500), priority: .sync)
        ids += page.threads?.map(\.id) ?? []
        token = page.nextPageToken
    } while token != nil
    return ids
}

final class RecordingGmail: GmailAPI {
    struct Call: Sendable, Hashable {
        var method: GmailMethod
        var priority: RequestPriority?
        var items = 1
        var query: String?
    }
    typealias Hook = @Sendable (Call, _ nth: Int) async -> Void

    let inner: FakeGmail
    private let log = Mutex<[Call]>([])
    private let hookBox = Mutex<Hook?>(nil)
    private let afterBox = Mutex<Hook?>(nil)

    init(_ inner: FakeGmail) { self.inner = inner }

    var accountEmail: String { inner.accountEmail }
    var calls: [Call] { log.withLock { $0 } }
    func calls(_ method: GmailMethod) -> [Call] { calls.filter { $0.method == method } }
    func setHook(_ hook: Hook?) { hookBox.withLock { $0 = hook } }
    func setAfterThreadsHook(_ hook: Hook?) { afterBox.withLock { $0 = hook } }
    func reset() { log.withLock { $0 = [] } }

    private func record(_ method: GmailMethod, _ priority: RequestPriority?, items: Int = 1, query: String? = nil) async {
        let call = Call(method: method, priority: priority, items: items, query: query)
        let n = log.withLock { l -> Int in
            l.append(call)
            return l.filter { $0.method == method }.count
        }
        if let hook = hookBox.withLock({ $0 }) { await hook(call, n) }
    }

    func getProfile(priority: RequestPriority) async throws -> GmailProfile {
        await record(.getProfile, priority); return try await inner.getProfile(priority: priority)
    }
    func listSendAs() async throws -> [GmailSendAs] { await record(.listSendAs, nil); return try await inner.listSendAs() }
    func listLabels() async throws -> [GmailLabel] { await record(.listLabels, nil); return try await inner.listLabels() }
    func getLabel(id: String) async throws -> GmailLabel { await record(.getLabel, nil); return try await inner.getLabel(id: id) }
    func createLabel(name: String, labelListVisibility: String?, messageListVisibility: String?) async throws -> GmailLabel {
        await record(.createLabel, nil)
        return try await inner.createLabel(name: name, labelListVisibility: labelListVisibility,
                                           messageListVisibility: messageListVisibility)
    }
    func listThreads(_ query: ListQuery, priority: RequestPriority) async throws -> GmailListThreadsResponse {
        await record(.listThreads, priority, query: query.q ?? query.labelIDs.joined(separator: ","))
        return try await inner.listThreads(query, priority: priority)
    }
    func getThread(id: String, format: MessageFormat, metadataHeaders: [String],
                   priority: RequestPriority) async throws -> GmailThread {
        await record(.getThread, priority)
        return try await inner.getThread(id: id, format: format, metadataHeaders: metadataHeaders, priority: priority)
    }
    func getThreads(ids: [String], format: MessageFormat, metadataHeaders: [String],
                    priority: RequestPriority) async throws -> [BatchItemResult<GmailThread>] {
        await record(.getThread, priority, items: ids.count)
        let answer = try await inner.getThreads(ids: ids, format: format, metadataHeaders: metadataHeaders,
                                                priority: priority)
        if let after = afterBox.withLock({ $0 }) {
            let n = calls(.getThread).count
            await after(Call(method: .getThread, priority: priority, items: ids.count, query: ids.joined(separator: ",")), n)
        }
        return answer
    }
    func trashThread(id: String) async throws -> GmailThread { await record(.trashThread, nil); return try await inner.trashThread(id: id) }
    func untrashThread(id: String) async throws -> GmailThread {
        await record(.untrashThread, nil); return try await inner.untrashThread(id: id)
    }
    func listMessages(_ query: ListQuery, priority: RequestPriority) async throws -> GmailListMessagesResponse {
        await record(.listMessages, priority, query: query.q)
        return try await inner.listMessages(query, priority: priority)
    }
    func getMessage(id: String, format: MessageFormat, metadataHeaders: [String],
                    priority: RequestPriority) async throws -> GmailMessage {
        await record(.getMessage, priority)
        return try await inner.getMessage(id: id, format: format, metadataHeaders: metadataHeaders, priority: priority)
    }
    func getMessages(ids: [String], format: MessageFormat, metadataHeaders: [String],
                     priority: RequestPriority) async throws -> [BatchItemResult<GmailMessage>] {
        await record(.getMessage, priority, items: ids.count)
        return try await inner.getMessages(ids: ids, format: format, metadataHeaders: metadataHeaders, priority: priority)
    }
    func getAttachment(messageID: String, attachmentID: String) async throws -> Data {
        await record(.getAttachment, nil); return try await inner.getAttachment(messageID: messageID, attachmentID: attachmentID)
    }
    func batchModifyMessages(ids: [String], add: [String], remove: [String]) async throws {
        await record(.batchModify, nil); try await inner.batchModifyMessages(ids: ids, add: add, remove: remove)
    }
    func modifyMessage(id: String, add: [String], remove: [String]) async throws -> GmailMessage {
        await record(.modifyMessage, nil); return try await inner.modifyMessage(id: id, add: add, remove: remove)
    }
    func trashMessage(id: String) async throws -> GmailMessage { await record(.trashMessage, nil); return try await inner.trashMessage(id: id) }
    func untrashMessage(id: String) async throws -> GmailMessage {
        await record(.untrashMessage, nil); return try await inner.untrashMessage(id: id)
    }
    func sendMessage(rawRFC822: Data, threadID: String?) async throws -> GmailMessage {
        await record(.sendMessage, nil); return try await inner.sendMessage(rawRFC822: rawRFC822, threadID: threadID)
    }
    func listDrafts(pageToken: String?, q: String?, maxResults: Int) async throws -> GmailListDraftsResponse {
        await record(.listDrafts, nil); return try await inner.listDrafts(pageToken: pageToken, q: q, maxResults: maxResults)
    }
    func getDraft(id: String, format: MessageFormat) async throws -> GmailDraft {
        await record(.getDraft, nil); return try await inner.getDraft(id: id, format: format)
    }
    func createDraft(rawRFC822: Data, threadID: String?) async throws -> GmailDraft {
        await record(.createDraft, nil); return try await inner.createDraft(rawRFC822: rawRFC822, threadID: threadID)
    }
    func updateDraft(id: String, rawRFC822: Data, threadID: String?) async throws -> GmailDraft {
        await record(.updateDraft, nil); return try await inner.updateDraft(id: id, rawRFC822: rawRFC822, threadID: threadID)
    }
    func deleteDraft(id: String) async throws { await record(.deleteDraft, nil); try await inner.deleteDraft(id: id) }
    func sendDraft(id: String) async throws -> GmailMessage { await record(.sendDraft, nil); return try await inner.sendDraft(id: id) }
    func listHistory(startHistoryID: HistoryID, pageToken: String?, types: [HistoryType], labelID: String?,
                     maxResults: Int, priority: RequestPriority) async throws -> GmailListHistoryResponse {
        await record(.listHistory, priority)
        return try await inner.listHistory(startHistoryID: startHistoryID, pageToken: pageToken, types: types,
                                           labelID: labelID, maxResults: maxResults, priority: priority)
    }
    func insertMessage(rawRFC822: Data, labelIDs: [String]) async throws -> GmailMessage {
        await record(.insertMessage, nil); return try await inner.insertMessage(rawRFC822: rawRFC822, labelIDs: labelIDs)
    }
}

final class AsyncGate: Sendable {
    private struct State { var open = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
    private let state = Mutex(State())

    var waiting: Int { state.withLock { $0.waiters.count } }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resume = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(c)
                return false
            }
            if resume { c.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for w in waiters { w.resume() }
    }
}

final class ProgressLog: Sendable {
    private let values = Mutex<[SyncProgress]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<SyncProgress>) {
        let t = Task { [self] in for await value in stream { append(value) } }
        task.withLock { $0 = t }
    }

    private func append(_ value: SyncProgress) { values.withLock { $0.append(value) } }
    var all: [SyncProgress] { values.withLock { $0 } }
    func stop() { task.withLock { $0?.cancel() } }
}

extension SyncHarness {
    func relaunched(api: (any GmailAPI)? = nil, settings: SyncSettings = SyncSettings()) -> AccountSyncer {
        AccountSyncer(account: account, store: store, api: api ?? gmail, clock: clock, settings: settings,
                      metrics: metrics)
    }

    func allMailCount() throws -> Int { try store.label(account: account, key: "oh:allmail")?.totalThreads ?? -1 }

    func localMessages(among ids: Set<String>) throws -> Set<String> {
        Set(try store.knownMessageIDs(account: account, among: ids.map { GmailMessageID($0) }).map(\.rawValue))
    }
}

func backfillSettings(bodyHorizon: Duration = .seconds(86_400), pageSize: Int = 500) -> SyncSettings {
    SyncSettings(bodyHorizon: bodyHorizon, inboxPageSize: pageSize, mailPageSize: pageSize)
}

struct DraftRow: Equatable, Sendable {
    var gmailDraftID: String?
    var origin: String
    var reviewState: String
    var state: String
}

func draftRows(_ store: StoreLocation) throws -> [DraftRow] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        throw StoreError.notFound("database")
    }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    let sql = "SELECT gmail_draft_id, origin, review_state, state FROM drafts ORDER BY gmail_draft_id"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw StoreError.notFound("drafts") }
    defer { sqlite3_finalize(stmt) }
    func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
    var rows: [DraftRow] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        rows.append(DraftRow(gmailDraftID: text(0), origin: text(1) ?? "", reviewState: text(2) ?? "",
                             state: text(3) ?? ""))
    }
    return rows
}

func rawDraft(subject: String, to: String = "bo@example.com", body: String = "Draft text.",
              headers: [String: String] = [:]) -> Data {
    var text = "From: me@example.com\r\nTo: \(to)\r\nSubject: \(subject)\r\n"
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
    text += "Content-Type: text/plain; charset=UTF-8\r\n\r\n\(body)\r\n"
    return Data(text.utf8)
}
