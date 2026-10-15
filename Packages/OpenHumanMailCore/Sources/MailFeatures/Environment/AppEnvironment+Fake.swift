import Foundation
import MailFakes
import MailModel

extension AppEnvironment {
    public static func fake(corpus: FakeCorpus = .make(), options: FakeMailStore.Options = .init(),
                            navigationStore: (any NavigationStateStoring)? = nil,
                            featureFlags: FeatureFlags = .atLaunch, ai: AICenter? = nil,
                            calendar: (any CalendarProviding)? = nil,
                            calendarConnection: (any CalendarConnecting)? = nil,
                            keymapStore: (any KeymapStoring)? = nil,
                            calendarConnections: (any CalendarConnectionsProviding)? = nil,
                            calendarCache: (any CalendarCachePersisting)? = nil,
                            waiting: (any WaitingPort)? = nil,
                            notices: NoticeCenter? = nil) -> AppEnvironment {
        let store = FakeMailStore(corpus: corpus, options: options)
        let rules = FakeImportanceRules(corpus: corpus, safeMode: options.safeMode, now: options.now)
        let environment = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: true,
                                         navigationStore: navigationStore, notices: notices,
                                         importance: rules,
                                         featureFlags: featureFlags, aiOnboarding: FakeAIOnboarding(),
                                         aiConnections: FakeAIConnections(), secrets: InMemorySecretStore(), ai: ai,
                                         calendar: calendar, calendarConnection: calendarConnection,
                                         keymapStore: keymapStore, calendarConnections: calendarConnections,
                                         calendarCache: calendarCache,
                                         waiting: waiting ?? FakeWaitingRules(safeMode: options.safeMode))
        if options.relatedSearchMatches, !environment.smartSearchEnabled { store.setRelatedSearchMatches(false) }
        environment.autoLabels?.onIndexChange = { [weak rules] index in
            rules?.setAutoLabelLookup { key in index.category(account: key.account, thread: key.gmailThreadID, labelIDs: []) }
        }
        return environment
    }
}
