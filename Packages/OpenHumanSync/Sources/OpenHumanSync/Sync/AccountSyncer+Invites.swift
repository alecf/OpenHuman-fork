import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

extension AccountSyncer {
    @discardableResult
    func checkInvites() async throws -> Int {
        let cap = settings.inviteChecksPerRun
        guard cap > 0 else { return 0 }
        do {
            let wanted = try store.messagesNeedingInviteCheck(account: account, limit: cap)
            guard !wanted.isEmpty else { return 0 }
            let results = try await api.getMessages(ids: wanted.map(\.rawValue), format: .full, metadataHeaders: [],
                                                    priority: .sync)
            let stored = try BodyFetcher.store(results, account: account, store: store, log: log)
            var gone: [GmailMessageID] = []
            for item in results {
                if case .failure(.notFound) = item.result { gone.append(GmailMessageID(item.id)) }
            }
            if !gone.isEmpty {
                // Gmail no longer has these: drop the local rows, or they would be requested on every run
                let tombstone = try store.syncStatus(account: account).historyID ?? HistoryID(0)
                _ = try store.deleteMessages(gone, account: account, historyID: tombstone)
            }
            log.info("account \(account.rawValue): invite check stored \(stored) of \(wanted.count) bodies")
            return stored
        } catch GmailError.cancelled {
            throw GmailError.cancelled
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.notice("account \(account.rawValue): invite check failed (\(Self.code(error)))")
            return 0
        }
    }
}
