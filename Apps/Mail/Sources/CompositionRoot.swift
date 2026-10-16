import Foundation
import MailFakes
import MailFeatures
import MailModel
import MailSystem
import MailUI
import MailUIMac
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailApple
import OpenHumanMailLive
import OpenHumanStore
import OpenHumanAI
import Security

@MainActor
extension CompositionRoot {
    enum DataMode: Equatable { case fake, fixtureStore, fakeGmail, live }

    static func dataMode(arguments: [String], environment: [String: String]) -> DataMode {
        #if DEBUG || OH_DEV_TOOLS
        if arguments.contains("-UseFixtureStore") { return .fixtureStore }
        if arguments.contains("-UseFakeGmail") { return .fakeGmail }
        if arguments.contains("-UseFakeData") { return .fake }
        if environment["XCTestConfigurationFilePath"] != nil { return .fake }
        #endif
        return .live
    }

    static func makeApp(arguments: [String] = ProcessInfo.processInfo.arguments,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> AppModel {
        PlatformServices.current = .mac
        developerHome = BuildFlavor.home
        #if DEBUG || OH_DEV_TOOLS
        if let app = fakeApp(arguments: arguments, environment: environment) { return app }
        #endif
        return live(environment: environment, arguments: arguments)
    }

    static func liveCalendarTokenStore(arguments: [String]) -> (any TokenStore)? {
        #if DEBUG || OH_DEV_TOOLS
        guard !arguments.contains("-UseFakeCalendar") else { return nil }
        #endif
        return KeychainTokenStore(service: GoogleCalendarAuth.keychainService, label: GoogleCalendarAuth.keychainLabel)
    }

    static func systemPlatform(_ environment: [String: String]) -> (@MainActor () -> SystemPlatform)? {
        guard environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return {
            var platform = SystemPlatform.mac(notifier: SystemNotificationCenter(), spotlight: CoreSpotlightIndex(),
                                              showMainWindow: { MainWindowPresenter.show() })
            platform.isAuthorTyping = { AuthorActivity.isTyping() }
            platform.currentFocusFilter = { await MailFocusFilter.currentState() }
            return platform
        }
    }

    static let testHostTitle = "Mail didn't start"
    static let testHostMessage = "Real accounts don't open inside a test run. Nothing was read or changed."

    static func live(environment: [String: String], arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        // Why: a test host must never reach the Keychain, the mail store or Gmail of the person running the tests
        if environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return AppModel(screen: .notice(StartupProblem(title: testHostTitle, message: testHostMessage)))
        }
        do {
            let location = try StoreLocation.resolve(home: BuildFlavor.home(environment))
            if showsStoreRebuildNotice(location) {
                return AppModel(screen: .notice(StartupProblem(title: storeRebuildTitle, message: storeRebuildMessage)))
            }
            AIServices.cacheDirectory = location.directory
            let store = try MailStore.open(StoreOptions(location: location, processKind: .app, observeExternalChanges: true,
                                                        appVersion: appVersion,
                                                        pollOnly: BuildFlavor.storePollOnly(environment)))
            let userAgent = "OpenHumanMail/\(appVersion)"
            let tokenTransport = URLSessionTransport(userAgent: userAgent)
            let signInBroker = SignInBroker(platform: .system, memory: UserDefaultsSignInBrowserMemory(defaults: .standard))
            SignInPanelController.install(signInBroker)
            let keychain = keychainStores(environment: environment, directory: location.directory,
                                          accessGroup: keychainAccessGroup())
            let backend = LiveBackend(
                store: store,
                accountDependencies: LiveAccountManager.Dependencies(
                    environment: environment, storeDirectory: location.directory,
                    clientStore: keychain.client, tokenStore: keychain.tokens,
                    transport: tokenTransport, makeReceiver: { signInBroker.wrap(NWLoopbackReceiver()) },
                    browser: signInBroker,
                    clock: SystemClock(), calendarTokenStore: liveCalendarTokenStore(arguments: arguments),
                    developerClientFile: BuildFlavor.oauthClientFile),
                transports: LiveBackend.Transports(api: URLSessionTransport(userAgent: userAgent), token: tokenTransport,
                                                   unsubscribe: OneClickTransport(userAgent: userAgent)),
                userAgent: userAgent, makeSystemEvents: { AppSystemEvents() })
            return AppModel(live: backend, platform: systemPlatform(environment))
        } catch {
            return AppModel(screen: .notice(storeProblem(error)))
        }
    }

    // Why: a test home gets its own service so its sign-in can never replace or sign out the real install's token
    static func keychainService(environment: [String: String], directory: URL) -> String {
        guard BuildFlavor.home(environment) != nil else { return OHIdentifiers.keychainService }
        return OHIdentifiers.keychainService + ".home." + stableID(directory.standardizedFileURL.path)
    }

    static func syncedTokenStore(service: String, accessGroup: String?) -> SyncedTokenStore {
        SyncedTokenStore(local: KeychainTokenStore(service: service),
                         shared: KeychainSharedGrantStore(service: service, accessGroup: accessGroup),
                         device: KeychainTokenDeviceStore(tokenService: service))
    }

    static func keychainStores(environment: [String: String], directory: URL,
                               accessGroup: String?) -> (client: KeychainClientStore, tokens: SyncedTokenStore) {
        (KeychainClientStore(service: clientKeychainService(environment: environment, directory: directory),
                             accessGroup: accessGroup),
         syncedTokenStore(service: keychainService(environment: environment, directory: directory), accessGroup: accessGroup))
    }

    // Why: a group the signature doesn't grant refuses every shared write, so it waits for the entitlement
    static func keychainAccessGroup(info: [String: Any]? = Bundle.main.infoDictionary,
                                    entitled: [String] = entitledKeychainGroups()) -> String? {
        guard let group = KeychainSharing.configuredAccessGroup(info), entitled.contains(group) else { return nil }
        return group
    }

    static func entitledKeychainGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) else { return [] }
        return value as? [String] ?? []
    }

    static func clientKeychainService(environment: [String: String], directory: URL) -> String {
        guard BuildFlavor.home(environment) != nil else { return KeychainClientStore.service }
        return KeychainClientStore.service + ".home." + stableID(directory.standardizedFileURL.path)
    }
}

#if DEBUG || OH_DEV_TOOLS
@MainActor
extension CompositionRoot {
    static func fakeApp(arguments: [String], environment: [String: String]) -> AppModel? {
        switch dataMode(arguments: arguments, environment: environment) {
        case .fake:
            return AppModel(screen: .mail(.fake(corpus: .small,
                                                options: FakeMailStore.Options(
                                                    relatedSearchMatches: arguments.contains("-UseFakeData")),
                                                navigationStore: navigationStore("fake", environment),
                                                ai: AIServices.aiCenter(model: .fake, persistent: false, environment: environment),
                                                calendar: fakeCalendar(arguments: arguments))))
        case .fixtureStore:
            do {
                let (store, _) = try FixtureStoreSeeder.makeStore(corpus: .make())
                return AppModel(screen: .mail(AppEnvironment(data: MailStoreAdapter(store: store),
                                                             settings: MailStoreSettings(store: store), isFake: true,
                                                             navigationStore: navigationStore("fixtureStore", environment),
                                                             importance: MailStoreImportance(store: store),
                                                             ai: AIServices.aiCenter(model: .fake, persistent: false,
                                                                                     environment: environment))))
            } catch {
                return AppModel(screen: .notice(StartupProblem(title: "Couldn't build the fixture store",
                                                               message: "The test data couldn't be written. Quit Mail and open it again.",
                                                               details: String(describing: error))))
            }
        case .fakeGmail:
            do {
                let running = try FakeGmailLaunch.launch()
                return AppModel(screen: .mail(running.session.environment), session: running.session,
                                platform: fakeGmailPlatform(arguments: arguments, environment: environment))
            } catch {
                return AppModel(screen: .notice(StartupProblem(title: "Couldn't start FakeGmail",
                                                               message: "The test server didn't start. Quit Mail and open it again.",
                                                               details: String(describing: error))))
            }
        case .live:
            return nil
        }
    }

    static func fakeCalendar(arguments: [String]) -> FakeCalendar? {
        arguments.contains("-UseFakeCalendar") ? FakeCalendar.sample() : nil
    }

    static let fakeGmailNotificationsArgument = "-FakeGmailNotifications"

    static func fakeGmailPlatform(arguments: [String], environment: [String: String]) -> (@MainActor () -> SystemPlatform)? {
        guard let real = systemPlatform(environment) else { return nil }
        let notifies = arguments.contains(fakeGmailNotificationsArgument)
        return { syntheticMailOnly(real(), notifications: notifies) }
    }

    static func syntheticMailOnly(_ platform: SystemPlatform, notifications: Bool) -> SystemPlatform {
        var platform = platform
        if !notifications { platform.notifier = FakeSystemNotifier(authorization: .authorized) }
        platform.dock = FakeDockBadge()
        platform.spotlight = FakeSpotlightIndex()
        return platform
    }
}
#endif
