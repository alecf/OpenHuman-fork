import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

public struct BodyFetcher: Sendable {
    public let account: AccountID
    let store: any SyncStore
    let api: any GmailAPI
    let log = Log(.sync)

    public init(account: AccountID, store: any SyncStore, api: any GmailAPI) {
        self.account = account
        self.store = store
        self.api = api
    }

    @discardableResult
    public func ensureBodies(thread: ThreadRowID, priority: RequestPriority = .interactive) async throws -> Int {
        guard let detail = try store.threadDetail(thread) else { return 0 }
        let needed = detail.messages.filter { $0.bodyState == .none || $0.bodyState == .metadataOnly }
        guard !needed.isEmpty else { return 0 }
        if needed.count == 1 {
            return try await ensureBody(needed[0].gmailMessageID, priority: priority) ? 1 : 0
        }
        let wanted = Set(needed.map(\.gmailMessageID.rawValue))
        do {
            let full = try await api.getThread(id: detail.thread.ref.gmailThreadID.rawValue, format: .full,
                                               metadataHeaders: [], priority: priority)
            let messages = (full.messages ?? []).filter { wanted.contains($0.id) }
            let results = messages.map { BatchItemResult(id: $0.id, result: Result<GmailMessage, GmailError>.success($0)) }
            let stored = try Self.store(results, account: account, store: store, log: log)
            let returned = Set(messages.map(\.id))
            let gone = wanted.subtracting(returned).map { GmailMessageID($0) }
            if !gone.isEmpty { try markGone(gone) }
            return stored
        } catch GmailError.notFound {
            try markGone(Array(wanted).map { GmailMessageID($0) })
            return 0
        }
    }

    @discardableResult
    public func ensureBody(_ id: GmailMessageID, priority: RequestPriority = .interactive) async throws -> Bool {
        do {
            let message = try await api.getMessage(id: id.rawValue, format: .full, metadataHeaders: [], priority: priority)
            return try Self.store([BatchItemResult(id: id.rawValue, result: .success(message))], account: account,
                                  store: store, log: log) == 1
        } catch GmailError.notFound {
            try markGone([id])
            return false
        }
    }

    private func markGone(_ ids: [GmailMessageID]) throws {
        let tombstone = try store.syncStatus(account: account).historyID ?? HistoryID(0)
        _ = try store.deleteMessages(ids, account: account, historyID: tombstone)
    }

    @discardableResult
    static func store(_ results: [BatchItemResult<GmailMessage>], account: AccountID, store: any SyncStore,
                      log: Log) throws -> Int {
        var bodies: [(GmailMessageID, MessageBodyUpsert, [AttachmentUpsert])] = []
        for item in results {
            guard case .success(let message) = item.result else { continue }
            do {
                let upsert = try GmailMapper.messageUpsert(message, includeBody: true)
                if let body = upsert.body { bodies.append((upsert.gmailMessageID, body, upsert.attachments ?? [])) }
            } catch {
                log.notice("account \(account.rawValue): body of \(message.id) failed to parse")
                try store.markBodyFailed(GmailMessageID(message.id), account: account, reason: "parse")
            }
        }
        if !bodies.isEmpty { try store.storeBodies(bodies, account: account) }
        return bodies.count
    }
}
