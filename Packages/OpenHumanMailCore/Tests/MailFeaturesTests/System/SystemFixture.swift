import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
final class ActiveFlag {
    var isActive = false
    var activations = 0
    var windowShows = 0
    var quits = 0
}

@MainActor
struct SystemFixture {
    let env: AppEnvironment
    let store: FakeMailStore
    let notifier: FakeSystemNotifier
    let dock = FakeDockBadge()
    let login = FakeLoginItem()
    let opener = FakeURLOpener()
    let spotlight = FakeSpotlightIndex()
    let menuBar = FakeMenuBarItem()
    let hotkeys = FakeGlobalHotkey()
    let active = ActiveFlag()
    let account: AccountID

    init(corpus: FakeCorpus = .make(threadCount: 10, now: fixedNow),
         options: FakeMailStore.Options = .init(remoteAck: .immediate),
         flags: FeatureFlags = FeatureFlags(), authorization: NotificationAuthorization = .authorized,
         grantOnRequest: Bool = true) {
        env = AppEnvironment.fake(corpus: corpus, options: options, featureFlags: flags)
        store = env.commands as! FakeMailStore
        notifier = FakeSystemNotifier(authorization: authorization, grantOnRequest: grantOnRequest)
        account = corpus.accounts.first!.id
        let flag = active
        env.installPlatform(SystemPlatform(notifier: notifier, dock: dock, loginItem: login, urlOpener: opener,
                                           spotlight: spotlight, menuBarItem: menuBar, hotkeys: hotkeys,
                                           isAppActive: { flag.isActive },
                                           activateApp: { flag.activations += 1 },
                                           showMainWindow: { flag.windowShows += 1 }, quitApp: { flag.quits += 1 }))
        env.system.coalesce = .milliseconds(20)
    }

    func firstThread() async throws -> ThreadRow {
        try #require(await first(store.threadWindow(.system(.inbox), account: account, limit: 5))?.rows.first)
    }

    func delivered(timeout: Duration = .seconds(15), count: Int) async {
        await eventually(timeout: timeout) { notifier.delivered.count >= count }
    }
}

func first<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T? {
    for try await value in stream { return value }
    return nil
}
