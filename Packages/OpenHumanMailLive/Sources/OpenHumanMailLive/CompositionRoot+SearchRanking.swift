import Foundation
import OpenHumanCore
import OpenHumanStore

extension CompositionRoot {
    static func searchRankingService(store: any MailStoreAdapter.Store, isFake: Bool,
                                     underTest: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        -> SearchRankingService {
        let local = isFake || underTest
        let learning: any SearchLearningStoring = local ? InMemorySearchLearningStore()
            : AIServices.cacheDirectory.flatMap {
                try? SQLiteSearchLearningStore(url: $0.appendingPathComponent(SQLiteSearchLearningStore.fileName))
            } ?? InMemorySearchLearningStore()
        return SearchRankingService(persistence: local ? .memory : .defaults(suite: nil), learning: learning,
                                    resolve: { account, thread in
                                        (try? store.thread(account: account, gmailThreadID: thread))?.rowID
                                    })
    }
}
