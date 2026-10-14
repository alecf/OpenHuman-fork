import Foundation
import MailModel
import OpenHumanCore

extension FakeMailStore {
    public func remoteSearch(gmailQuery: String, account: AccountID, maxResults: Int) async throws -> [ThreadKey] {
        let hits = try state.withLock { s in try s.searchEntries(gmailQuery, accounts: [account]) }
        return hits.prefix(max(maxResults, 0)).map(\.row.id)
    }
}
