import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanMIME
import OpenHumanStore
import Synchronization
import Testing
@testable import OpenHumanSync

func sendClock() -> InstantClock { InstantClock(now: Date()) }

extension WriteHarness {
    var instant: InstantClock { clock as! InstantClock }

    func advancePast(_ receipt: SendReceipt) {
        instant.advance(by: .seconds(max(0, receipt.sendAfter.timeIntervalSince(clock.now)) + 1))
    }

    func newDraft(to: [String] = ["bob@example.com"], cc: [String] = [], bcc: [String] = [],
                  subject: String = "Synthetic draft", html: String = "<p>Synthetic body</p>",
                  origin: DraftOrigin = .user, review: DraftReviewState = .none, headers: [String: String] = [:],
                  mode: ComposeMode = .new, replyTo: GmailMessageID? = nil,
                  attachments: [DraftAttachment] = []) throws -> DraftID {
        let content = DraftContent(to: to.map { EmailAddress(email: $0) }, cc: cc.map { EmailAddress(email: $0) },
                                   bcc: bcc.map { EmailAddress(email: $0) }, subject: subject, bodyHTML: html,
                                   attachments: attachments)
        return try store.createDraft(account: account, mode: mode, replyTo: replyTo, content: content, origin: origin,
                                     reviewState: review, agentNote: origin == .user ? nil : "synthetic note",
                                     extraHeaders: headers)
    }

    func draft(_ id: DraftID) throws -> DraftListItem { try #require(try store.draft(id)) }

    @discardableResult
    func upload(_ id: DraftID, drainer: OperationDrainer) async throws -> DraftListItem {
        let op = try store.saveDraftRemotely(id)
        await drainer.drainOnce()
        #expect(try store.operation(op)?.status == .succeeded)
        return try draft(id)
    }

    func sentOnGmail() async throws -> [String] { try await OpenHumanSyncTests.sentOnGmail(gmail) }

    func gmailDraftIDs() async throws -> [String] {
        try await gmail.listDrafts(pageToken: nil, q: nil, maxResults: 500).drafts?.map(\.id) ?? []
    }

    func rawOnGmail(_ messageID: String) async throws -> String { try await OpenHumanSyncTests.rawOnGmail(gmail, messageID) }

    func labelNames(ofMessage id: String) async -> Set<String> { await OpenHumanSyncTests.labelNames(gmail, ofMessage: id) }

    func uploads() -> [(method: String, path: String, raw: String)] {
        wire.requests.filter { $0.url.path().hasPrefix("/upload/gmail/v1/users/me/drafts") }.map { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            let raw = body.range(of: "message/rfc822").map { String(body[$0.upperBound...]) } ?? body
            return (request.method, request.url.path(), raw)
        }
    }
}

final class ProbeGmail: GmailAPI {
    struct Write: Sendable { var method: GmailMethod; var raw: Data? }
    typealias Hook = @Sendable (FakeGmail, GmailDraft) async -> Void
    let inner: FakeGmail
    private let state = Mutex<(writes: [Write], hideSentLookups: Bool, afterUpdate: Hook?)>(([], false, nil))
    private let gates = Mutex<[GmailMethod: Gate]>([:])

    init(_ inner: FakeGmail) { self.inner = inner }

    var accountEmail: String { inner.accountEmail }
    var writes: [Write] { state.withLock { $0.writes } }
    func hideSentLookups(_ on: Bool) { state.withLock { $0.hideSentLookups = on } }
    func afterNextUpdate(_ hook: Hook?) { state.withLock { $0.afterUpdate = hook } }
    private func note(_ method: GmailMethod, _ raw: Data? = nil) { state.withLock { $0.writes.append(Write(method: method, raw: raw)) } }

    func pauseNext(_ method: GmailMethod) -> Gate {
        let gate = Gate()
        gates.withLock { $0[method] = gate }
        return gate
    }

    private func pass(_ method: GmailMethod) async {
        guard let gate = gates.withLock({ $0.removeValue(forKey: method) }) else { return }
        await gate.pass()
    }

    func holdAnswer(_ method: GmailMethod) -> Gate {
        let gate = Gate()
        answerGates.withLock { $0[method] = gate }
        return gate
    }

    private let answerGates = Mutex<[GmailMethod: Gate]>([:])

    private func answered(_ method: GmailMethod) async {
        guard let gate = answerGates.withLock({ $0.removeValue(forKey: method) }) else { return }
        await gate.pass()
    }

    func getProfile(priority: RequestPriority) async throws -> GmailProfile { try await inner.getProfile(priority: priority) }
    func listSendAs() async throws -> [GmailSendAs] { try await inner.listSendAs() }
    func listLabels() async throws -> [GmailLabel] { try await inner.listLabels() }
    func getLabel(id: String) async throws -> GmailLabel { try await inner.getLabel(id: id) }
    func createLabel(name: String, labelListVisibility: String?, messageListVisibility: String?) async throws -> GmailLabel {
        note(.createLabel)
        return try await inner.createLabel(name: name, labelListVisibility: labelListVisibility,
                                           messageListVisibility: messageListVisibility)
    }
    func listThreads(_ query: ListQuery, priority: RequestPriority) async throws -> GmailListThreadsResponse {
        try await inner.listThreads(query, priority: priority)
    }
    func getThread(id: String, format: MessageFormat, metadataHeaders: [String], priority: RequestPriority) async throws -> GmailThread {
        try await inner.getThread(id: id, format: format, metadataHeaders: metadataHeaders, priority: priority)
    }
    func getThreads(ids: [String], format: MessageFormat, metadataHeaders: [String],
                    priority: RequestPriority) async throws -> [BatchItemResult<GmailThread>] {
        let answer = try await inner.getThreads(ids: ids, format: format, metadataHeaders: metadataHeaders, priority: priority)
        await answered(.getThread)
        return answer
    }
    func trashThread(id: String) async throws -> GmailThread { note(.trashThread); return try await inner.trashThread(id: id) }
    func untrashThread(id: String) async throws -> GmailThread { note(.untrashThread); return try await inner.untrashThread(id: id) }
    func listMessages(_ query: ListQuery, priority: RequestPriority) async throws -> GmailListMessagesResponse {
        if state.withLock({ $0.hideSentLookups }), query.q?.contains("rfc822msgid:") == true {
            return GmailListMessagesResponse(messages: nil, nextPageToken: nil, resultSizeEstimate: 0)
        }
        return try await inner.listMessages(query, priority: priority)
    }
    func getMessage(id: String, format: MessageFormat, metadataHeaders: [String], priority: RequestPriority) async throws -> GmailMessage {
        try await inner.getMessage(id: id, format: format, metadataHeaders: metadataHeaders, priority: priority)
    }
    func getMessages(ids: [String], format: MessageFormat, metadataHeaders: [String],
                     priority: RequestPriority) async throws -> [BatchItemResult<GmailMessage>] {
        try await inner.getMessages(ids: ids, format: format, metadataHeaders: metadataHeaders, priority: priority)
    }
    func getAttachment(messageID: String, attachmentID: String) async throws -> Data {
        try await inner.getAttachment(messageID: messageID, attachmentID: attachmentID)
    }
    func batchModifyMessages(ids: [String], add: [String], remove: [String]) async throws {
        note(.batchModify)
        try await inner.batchModifyMessages(ids: ids, add: add, remove: remove)
    }
    func modifyMessage(id: String, add: [String], remove: [String]) async throws -> GmailMessage {
        note(.modifyMessage)
        return try await inner.modifyMessage(id: id, add: add, remove: remove)
    }
    func trashMessage(id: String) async throws -> GmailMessage { note(.trashMessage); return try await inner.trashMessage(id: id) }
    func untrashMessage(id: String) async throws -> GmailMessage { note(.untrashMessage); return try await inner.untrashMessage(id: id) }
    func sendMessage(rawRFC822: Data, threadID: String?) async throws -> GmailMessage {
        note(.sendMessage, rawRFC822)
        return try await inner.sendMessage(rawRFC822: rawRFC822, threadID: threadID)
    }
    func listDrafts(pageToken: String?, q: String?, maxResults: Int) async throws -> GmailListDraftsResponse {
        try await inner.listDrafts(pageToken: pageToken, q: q, maxResults: maxResults)
    }
    func getDraft(id: String, format: MessageFormat) async throws -> GmailDraft {
        if format == .metadata { await pass(.getDraft) }
        return try await inner.getDraft(id: id, format: format)
    }
    func createDraft(rawRFC822: Data, threadID: String?) async throws -> GmailDraft {
        note(.createDraft, rawRFC822)
        return try await inner.createDraft(rawRFC822: rawRFC822, threadID: threadID)
    }
    func updateDraft(id: String, rawRFC822: Data, threadID: String?) async throws -> GmailDraft {
        await pass(.updateDraft)
        note(.updateDraft, rawRFC822)
        let draft = try await inner.updateDraft(id: id, rawRFC822: rawRFC822, threadID: threadID)
        let hook = state.withLock { s -> Hook? in
            defer { s.afterUpdate = nil }
            return s.afterUpdate
        }
        await hook?(inner, draft)
        return draft
    }
    func deleteDraft(id: String) async throws { note(.deleteDraft); try await inner.deleteDraft(id: id) }
    func sendDraft(id: String) async throws -> GmailMessage {
        await pass(.sendDraft)
        note(.sendDraft)
        return try await inner.sendDraft(id: id)
    }
    func listHistory(startHistoryID: HistoryID, pageToken: String?, types: [HistoryType], labelID: String?,
                     maxResults: Int, priority: RequestPriority) async throws -> GmailListHistoryResponse {
        let answer = try await inner.listHistory(startHistoryID: startHistoryID, pageToken: pageToken, types: types,
                                                 labelID: labelID, maxResults: maxResults, priority: priority)
        await answered(.listHistory)
        return answer
    }
    func insertMessage(rawRFC822: Data, labelIDs: [String]) async throws -> GmailMessage {
        note(.insertMessage, rawRFC822)
        return try await inner.insertMessage(rawRFC822: rawRFC822, labelIDs: labelIDs)
    }

    var lastUploadBeforeSend: String? {
        let writes = self.writes
        let end = writes.firstIndex { $0.method == .sendDraft } ?? writes.endIndex
        return writes[..<end].last { $0.method == .updateDraft || $0.method == .createDraft }?.raw
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

// Open every gate before a test ends: a held request never resumes on its own
final class Gate: Sendable {
    private let state = Mutex<(reached: Bool, open: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, false, nil))

    var reached: Bool { state.withLock { $0.reached } }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                s.reached = true
                if s.open { return true }
                s.waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.open = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }
}

func sentOnGmail(_ gmail: FakeGmail) async throws -> [String] {
    try await gmail.listMessages(ListQuery(labelIDs: ["SENT"], maxResults: 500), priority: .sync).messages?.map(\.id) ?? []
}

func rawOnGmail(_ gmail: FakeGmail, _ messageID: String) async throws -> String {
    let message = try await gmail.getMessage(id: messageID, format: .raw, metadataHeaders: [], priority: .sync)
    return String(decoding: Base64URL.decode(try #require(message.raw)) ?? Data(), as: UTF8.self)
}

func labelNames(_ gmail: FakeGmail, ofMessage id: String) async -> Set<String> {
    var names = Set<String>()
    for label in await gmail.labelIDs(ofMessage: id) ?? [] {
        if let name = try? await gmail.getLabel(id: label).name { names.insert(name) }
    }
    return names
}

func lines(_ raw: String, startingWith prefix: String) -> [String] {
    raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init)
        .filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
}

extension EventLog {
    var sent: [(DraftID, GmailMessageID?)] {
        all.compactMap { if case let .sent(draft, message) = $0 { return (draft, message) } else { return nil } }
    }
    var sendFailures: [(DraftID, String)] {
        all.compactMap { if case let .sendFailed(draft, reason) = $0 { return (draft, reason) } else { return nil } }
    }
}
