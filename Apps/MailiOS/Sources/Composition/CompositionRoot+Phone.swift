import Foundation
import MailFakes
import MailFeatures
import MailModel
import MailUI
import OpenHumanCore
import OpenHumanMailLive
import OpenHumanStore
import UIKit

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
        PlatformServices.current = .phone
        developerHome = BuildFlavor.home
        #if DEBUG || OH_DEV_TOOLS
        if let app = fakeApp(arguments: arguments, environment: environment) { return app }
        #endif
        return live()
    }

    static let signInLaterTitle = "Gmail isn't on this iPhone yet"
    static let signInLaterMessage = "Signing in on iPhone comes with a later update. Nothing was read or changed."

    static func live() -> AppModel {
        AppModel(screen: .notice(StartupProblem(title: signInLaterTitle, message: signInLaterMessage)))
    }
}

extension PlatformServices {
    @MainActor static let phone = PlatformServices(isAppActive: { UIApplication.shared.applicationState == .active },
                                                   activateApp: {})
}

#if DEBUG || OH_DEV_TOOLS
@MainActor
extension CompositionRoot {
    static func fakeApp(arguments: [String], environment: [String: String]) -> AppModel? {
        switch dataMode(arguments: arguments, environment: environment) {
        case .fake:
            return AppModel(screen: .mail(.fake(corpus: .small,
                                                options: FakeMailStore.Options(relatedSearchMatches: true),
                                                navigationStore: PhoneLaunchScreen.current(arguments) == nil
                                                    ? navigationStore("fake", environment) : InMemoryNavigationStore(),
                                                ai: AIServices.aiCenter(model: .fake, persistent: false,
                                                                        environment: environment))))
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
                                                               message: "The test data couldn't be written. Close Mail and open it again.",
                                                               details: String(describing: error))))
            }
        case .fakeGmail:
            do {
                let running = try FakeGmailLaunch.launch()
                return AppModel(screen: .mail(running.session.environment), session: running.session)
            } catch {
                return AppModel(screen: .notice(StartupProblem(title: "Couldn't start FakeGmail",
                                                               message: "The test server didn't start. Close Mail and open it again.",
                                                               details: String(describing: error))))
            }
        case .live:
            return nil
        }
    }
}
#endif
