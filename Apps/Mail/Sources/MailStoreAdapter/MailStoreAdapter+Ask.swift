import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore

extension MailStoreAdapter {
    public func searchOnce(_ query: String, semanticText: String?, accounts: [AccountID]?,
                           limit: Int) async throws -> SearchResultsInfo {
        let parsed = try Self.parsedSearch(query, store)
        let page: SearchPage
        do {
            page = try parsed.searching.search(parsed.query, accounts: accounts, after: nil, limit: limit)
        } catch let error as MailPortError {
            throw error
        } catch {
            throw MailPortError.unavailable("search")
        }
        var primary: [AccountID: LabelRowID] = [:]
        var looked: Set<AccountID> = []
        let hits = page.hits.map { hit -> SearchHitInfo in
            let account = hit.thread.ref.accountID
            if looked.insert(account).inserted { primary[account] = Self.primaryCategory(store, account: account) }
            return SearchHitInfo(row: Self.row(hit.thread, hiddenCategory: primary[account]),
                                 matchedMessageRowIDs: hit.matchedMessageIDs.map(\.rawValue), highlight: hit.highlight)
        }
        return SearchResultsInfo(hits: hits, hasMore: page.nextCursor != nil, completeness: Self.coverage(page.completeness))
    }

    public func remoteSearch(gmailQuery: String, account: AccountID, maxResults: Int) async throws -> [ThreadKey] {
        guard let askRemoteSearch else { throw MailPortError.unsupported("Gmail search in this store") }
        let query = gmailQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        do {
            return try await askRemoteSearch(query, account, maxResults).map(Self.threadKey)
        } catch let error as MailPortError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MailPortError.unavailable("Gmail search")
        }
    }

    static func coverage(_ completeness: SearchCompleteness) -> SearchCompletenessInfo {
        SearchCompletenessInfo(reasons: completeness.reasons.map { reason -> SearchIncompleteness in
            switch reason {
            case .olderMailNeedsGmailFallback(_, let searchedBack): .olderMailNotLocal(searchedBack: searchedBack)
            case .bodiesPartiallyIndexed(let messages): .bodiesNotDownloaded(messages: messages)
            case .candidateLimitReached(let limit): .tooManyMatches(limit: limit)
            }
        })
    }
}
