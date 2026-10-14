import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

public struct RemoteSearch: Sendable {
    public let account: AccountID
    let store: any SyncStore
    let api: any GmailAPI
    let log = Log(.sync)

    public init(account: AccountID, store: any SyncStore, api: any GmailAPI) {
        self.account = account
        self.store = store
        self.api = api
    }

    public func search(_ query: SearchQuery, maxResults: Int = 50) async throws -> [ThreadRef] {
        try await search(gmailQuery: query.gmailQuery, maxResults: maxResults)
    }

    public func search(gmailQuery: String, maxResults: Int = 50) async throws -> [ThreadRef] {
        let q = gmailQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let page = try await api.listMessages(ListQuery(q: q, maxResults: min(max(maxResults, 1), 500)),
                                              priority: .interactive)
        let stubs = page.messages ?? []
        var order: [String] = []
        var seen = Set<String>()
        for stub in stubs {
            guard let thread = stub.threadId, seen.insert(thread).inserted else { continue }
            order.append(thread)
        }
        let known = try store.knownMessageIDs(account: account, among: stubs.map { GmailMessageID($0.id) })
        var unknownThreads: [String] = []
        var queued = Set<String>()
        for stub in stubs where !known.contains(GmailMessageID(stub.id)) {
            guard let thread = stub.threadId, queued.insert(thread).inserted else { continue }
            unknownThreads.append(thread)
        }
        if !unknownThreads.isEmpty {
            try await fetch(unknownThreads)
        }
        let refs = try order.compactMap { try store.thread(account: account, gmailThreadID: GmailThreadID($0)) }
        log.info("account \(account.rawValue): remote search returned \(refs.count) thread(s), fetched \(unknownThreads.count)")
        return refs
    }

    private func fetch(_ threads: [String]) async throws {
        let generation = try store.syncStatus(account: account).generation
        let results = try await api.getThreads(ids: threads, format: .metadata, metadataHeaders: standardMetadataHeaders,
                                               priority: .interactive)
        var upserts: [MessageUpsert] = []
        var firstError: GmailError?
        for item in results {
            switch item.result {
            case .success(let thread):
                for message in thread.messages ?? [] {
                    do { upserts.append(try GmailMapper.messageUpsert(message, includeBody: false)) }
                    catch { log.notice("account \(account.rawValue): message \(message.id) skipped (mapping)") }
                }
            case .failure(.notFound):
                continue
            case .failure(let error):
                firstError = firstError ?? error
            }
        }
        if !upserts.isEmpty {
            let result = try store.upsertMessages(upserts, account: account, generation: generation)
            if !result.unknownLabelIDs.isEmpty {
                let labels = try await api.listLabels()
                try store.upsertLabels(labels.map(GmailMapper.labelUpsert), account: account, removeMissing: true)
            }
        }
        if let firstError, upserts.isEmpty { throw firstError }
    }
}
