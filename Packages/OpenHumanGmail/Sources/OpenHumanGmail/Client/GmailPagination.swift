import Foundation
import OpenHumanCore

extension GmailAPI {
    public func allThreadStubs(_ query: ListQuery, priority: RequestPriority, maxPages: Int = .max) async throws -> [GmailThread] {
        var out: [GmailThread] = []
        var query = query
        var seen = Set<String>()
        for _ in 0..<max(maxPages, 0) {
            try Task.checkCancellation()
            let page = try await listThreads(query, priority: priority)
            out += page.threads ?? []
            guard let token = page.nextPageToken, seen.insert(token).inserted else { break }
            query.pageToken = token
        }
        return out
    }

    public func allMessageStubs(_ query: ListQuery, priority: RequestPriority, maxPages: Int = .max) async throws -> [GmailMessage] {
        var out: [GmailMessage] = []
        var query = query
        var seen = Set<String>()
        for _ in 0..<max(maxPages, 0) {
            try Task.checkCancellation()
            let page = try await listMessages(query, priority: priority)
            out += page.messages ?? []
            guard let token = page.nextPageToken, seen.insert(token).inserted else { break }
            query.pageToken = token
        }
        return out
    }

    public func allDrafts(q: String? = nil, maxPages: Int = .max) async throws -> [GmailDraft] {
        var out: [GmailDraft] = []
        var token: String?
        var seen = Set<String>()
        for _ in 0..<max(maxPages, 0) {
            try Task.checkCancellation()
            let page = try await listDrafts(pageToken: token, q: q, maxResults: 100)
            out += page.drafts ?? []
            guard let next = page.nextPageToken, seen.insert(next).inserted else { break }
            token = next
        }
        return out
    }

    public func allHistory(startHistoryID: HistoryID, types: [HistoryType] = [], labelID: String? = nil,
                           priority: RequestPriority) async throws -> (records: [GmailHistoryRecord], historyId: String) {
        var records: [GmailHistoryRecord] = []
        var token: String?
        var latest = String(startHistoryID.rawValue)
        var seen = Set<String>()
        while true {
            try Task.checkCancellation()
            let page = try await listHistory(startHistoryID: startHistoryID, pageToken: token, types: types,
                                             labelID: labelID, maxResults: 500, priority: priority)
            records += page.history ?? []
            latest = page.historyId
            guard let next = page.nextPageToken, seen.insert(next).inserted else { break }
            token = next
        }
        return (records, latest)
    }
}
