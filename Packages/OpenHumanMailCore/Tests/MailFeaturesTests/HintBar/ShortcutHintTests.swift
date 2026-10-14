import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct ShortcutHintPolicyTests {
    let done = ActionCatalog.descriptor(.markDone)!

    func decide(_ descriptor: ActionDescriptor?, _ source: ActionSource = .toolbar, keyboard: Int = 0, mouse: Int = 1,
                availability: ActionAvailability = .enabled, scope: ActionScope = .list, title: String? = nil,
                settings: ShortcutHintPolicy.Settings = .init()) -> ShortcutHintPolicy.Hint? {
        ShortcutHintPolicy.decision(descriptor, source: source, counts: ShortcutUseCount(keyboard: keyboard, mouse: mouse),
                                    availability: availability, scope: scope, title: title, settings: settings)
    }

    @Test func shownOnTheFirstClickNotOnTheNextFourAndAgainOnTheSixth() {
        let shown = (1...11).filter { decide(done, mouse: $0) != nil }
        #expect(shown == [1, 6, 11])
        #expect(decide(done, mouse: 0) == nil, "a count without this use never shows")
    }

    @Test func theTextIsTheCatalogTitleAndItsKey() throws {
        let hint = try #require(decide(done))
        #expect(hint.message == "Mark done: E")
        #expect(hint.action == .markDone && hint.keycaps == ["E"])
        #expect(hint.duration == .seconds(2) && hint.duration == ShortcutHintPolicy.duration)
        let open = try #require(ActionCatalog.descriptor(.openThread))
        #expect(decide(open)?.title == "Open")
        let inbox = try #require(ActionCatalog.descriptor(.goInbox))
        #expect(decide(inbox)?.message == "Go to Inbox: G I")
        let star = try #require(ActionCatalog.descriptor(.toggleStar))
        #expect(decide(star, title: "Star")?.message == "Star: S")
    }

    @Test func neverAfterThreeKeyUses() {
        #expect(decide(done, keyboard: 2) != nil)
        #expect(decide(done, keyboard: 3) == nil)
        #expect(decide(done, keyboard: 7, mouse: 6) == nil)
    }

    @Test func onlyToolbarAndMenuClicksTeach() {
        for source in [ActionSource.toolbar, .menu] { #expect(decide(done, source) != nil, "\(source)") }
        for source in [ActionSource.keyboard, .palette, .swipe, .deepLink, .intent, .toast] {
            #expect(decide(done, source) == nil, "\(source)")
        }
        #expect(ShortcutHintPolicy.use(of: .keyboard) == .keyboard)
        #expect(ShortcutHintPolicy.use(of: .menu) == .mouse && ShortcutHintPolicy.use(of: .palette) == nil)
        #expect(decide(done, .menu, settings: .init(sources: [.toolbar])) == nil)
    }

    @Test func hiddenWhenTheActionIsDisabledHiddenUnknownOrHasNoKey() throws {
        #expect(decide(done, availability: .disabled(.safeMode)) == nil)
        #expect(decide(done, availability: .disabled(.noSelection)) == nil)
        #expect(decide(done, availability: .hidden) == nil)
        #expect(decide(nil) == nil)
        let reset = try #require(ActionCatalog.descriptor(.resetShortcutHints))
        #expect(reset.defaultBindings.isEmpty)
        #expect(decide(reset) == nil, "no key, nothing to teach")
    }

    @Test func theSwitchOffShowsNothing() {
        #expect(decide(done, settings: .init(hintOnClick: false)) == nil)
    }

    @Test func reduceMotionIsPassedToTheHint() {
        #expect(decide(done, settings: .init(reduceMotion: false))?.animates == true)
        #expect(decide(done, settings: .init(reduceMotion: true))?.animates == false)
    }

    @Test func aRemappedKeyIsTheOneShown() throws {
        let registry = ActionRegistry()
        registry.applyKeymap(KeymapOverrides(bindings: ["thread.done": ["y"]]))
        #expect(decide(registry.descriptor(.markDone))?.message == "Mark done: Y")
    }

    @Test func theSettingKeysAndCatalogEntry() throws {
        #expect(AppSettings.hintOnClick.name == "ui.hint_on_click" && AppSettings.hintOnClick.defaultValue)
        #expect(AppSettings.shortcutLearning.name == "ui.shortcut_learning" && AppSettings.shortcutLearning.defaultValue.isEmpty)
        let reset = try #require(ActionCatalog.descriptor(.resetShortcutHints))
        #expect(reset.effect == .view, "local only: works in read-only")
        #expect(reset.appearsInPalette && !reset.appearsInMenu)
        #expect(PaletteController.symbol(for: .resetShortcutHints) != "")
    }
}

let shortcutHintNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

@MainActor
final class ShortcutHintHost: ActionHost {
    var context: ActionContext
    init(_ context: ActionContext) { self.context = context }
    func actionContext() -> ActionContext { context }
}

@MainActor
final class ShortcutCountingHandler: ActionHandler {
    var performed: [ActionSource] = []
    var refused: [ActionID] = []
    func perform(_ request: ActionRequest) -> ActionPerformance {
        performed.append(request.source)
        return .done
    }
}

@MainActor
@Suite struct ShortcutLearningTests {
    static let key = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1"))
    static let listContext = ActionContext(scope: .list, account: AccountID(1), selection: [key], focusedThread: key,
                                           hasRows: true)
    static let now = shortcutHintNow

    @MainActor
    struct Window {
        let registry: ActionRegistry
        let handler: ShortcutCountingHandler
        let notices: NoticeCenter
        let host: ShortcutHintHost
        let learning: ShortcutLearning

        init(settings: (any SettingsPort)? = nil) {
            registry = ActionRegistry()
            handler = ShortcutCountingHandler()
            notices = NoticeCenter(now: { shortcutHintNow }, autoExpire: false)
            host = ShortcutHintHost(ShortcutLearningTests.listContext)
            learning = ShortcutLearning(settings: settings, notices: notices)
            registry.register(handler, for: [.markDone])
            registry.register(ShortcutHintActionHandler(learning: learning, notices: notices),
                              for: ShortcutHintActionHandler.ids)
            registry.shortcutHints = learning
        }

        @discardableResult
        func perform(_ source: ActionSource, _ id: ActionID = .markDone) -> Bool {
            registry.perform(id, source: source, host: host)
        }
    }

    @Test func aToolbarClickPostsOneHintAndAKeyPressRecordsButPostsNone() async throws {
        let w = Window()
        await w.learning.start()
        #expect(w.perform(.toolbar))
        #expect(w.notices.toasts.count == 1)
        let toast = try #require(w.notices.toasts.first)
        #expect(toast.message == "Mark done: E")
        #expect(toast.style == .info && toast.actionTitle == nil, "no button")
        #expect(toast.expiresAt == Self.now.addingTimeInterval(2), "about 2 s, the theme's brief lifetime")
        #expect(toast.animates)

        #expect(w.perform(.keyboard))
        #expect(w.notices.toasts.count == 1, "a key press never shows a hint")
        #expect(w.learning.counts[.markDone] == ShortcutUseCount(keyboard: 1, mouse: 1))
        #expect(w.handler.performed == [.toolbar, .keyboard])
    }

    @Test func nothingIsCountedOrShownBeforeTheCountersAreReadBack() {
        let w = Window()
        #expect(w.perform(.toolbar))
        #expect(w.notices.toasts.isEmpty)
        #expect(w.learning.counts.isEmpty && !w.learning.isStarted)
    }

    @Test func aRefusedActionTeachesNothing() async {
        let w = Window()
        await w.learning.start()
        let refused = w.handler
        w.registry.onRefused = { id, _ in refused.refused.append(id) }
        w.host.context.safeMode = .readOnly
        #expect(w.perform(.toolbar), "an announced refusal is handled")
        #expect(refused.refused == [.markDone] && w.handler.performed.isEmpty)
        #expect(w.notices.toasts.isEmpty && w.learning.counts.isEmpty)
    }

    @Test func threeKeyPressesAndTheClickNoLongerTeaches() async {
        let w = Window()
        await w.learning.start()
        for _ in 0..<3 { w.perform(.keyboard) }
        w.perform(.toolbar)
        #expect(w.notices.toasts.isEmpty)
        w.perform(.keyboard)
        #expect(w.learning.counts[.markDone] == ShortcutUseCount(keyboard: 3, mouse: 0), "a learned key stops counting")
    }

    @Test func aMouseOnlyUserSeesItEveryFifthClick() async {
        let w = Window()
        await w.learning.start()
        var shownAt: [Int] = []
        for click in 1...6 {
            w.perform(.menu)
            if !w.notices.toasts.isEmpty { shownAt.append(click) }
            for toast in w.notices.toasts { w.notices.dismiss(toast.id) }
        }
        #expect(shownAt == [1, 6])
    }

    @Test func reduceMotionPostsAStillToast() async throws {
        let w = Window()
        w.notices.reduceMotion = true
        await w.learning.start()
        w.perform(.toolbar)
        let toast = try #require(w.notices.toasts.first)
        #expect(toast.animates == false)
    }

    @Test func theSwitchStoredOffShowsNothingButStillCounts() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: Self.now))
        try await store.set(AppSettings.hintOnClick, false)
        let w = Window(settings: store)
        await w.learning.start()
        #expect(!w.learning.hintOnClick)
        w.perform(.toolbar)
        #expect(w.notices.toasts.isEmpty)
        #expect(w.learning.counts[.markDone] == ShortcutUseCount(keyboard: 0, mouse: 1))
    }

    @Test func countersAreWrittenEveryFifthChangeAndOnFlushAndReadBackAtTheNextLaunch() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: Self.now))
        let w = Window(settings: store)
        await w.learning.start()
        for _ in 0..<2 { w.perform(.keyboard) }
        for _ in 0..<2 { w.perform(.toolbar) }
        #expect(w.learning.lastSave == nil, "four changes: nothing written yet")
        #expect(try await store.get(AppSettings.shortcutLearning).isEmpty)
        w.perform(.keyboard)
        await w.learning.lastSave?.value
        #expect(try await store.get(AppSettings.shortcutLearning) == [ActionID.markDone.rawValue: ShortcutUseCount(keyboard: 3, mouse: 2)])

        w.registry.register(w.handler, for: [.toggleStar])
        w.perform(.toolbar, .toggleStar)
        await w.learning.flush()?.value
        #expect(try await store.get(AppSettings.shortcutLearning)[ActionID.toggleStar.rawValue] == ShortcutUseCount(keyboard: 0, mouse: 1))

        let next = Window(settings: store)
        await next.learning.start()
        next.perform(.toolbar)
        #expect(next.notices.toasts.isEmpty)
        next.registry.register(next.handler, for: [.toggleStar])
        next.perform(.toolbar, .toggleStar)
        #expect(next.notices.toasts.isEmpty, "click 2 of Star")
        #expect(next.learning.counts[.toggleStar] == ShortcutUseCount(keyboard: 0, mouse: 2))
    }

    @Test func resetForgetsEverythingOnDiskTooAndTheHintShowsAgain() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: Self.now))
        let w = Window(settings: store)
        await w.learning.start()
        for _ in 0..<3 { w.perform(.keyboard) }
        await w.learning.flush()?.value
        #expect(try await store.get(AppSettings.shortcutLearning) == [ActionID.markDone.rawValue: ShortcutUseCount(keyboard: 3)])
        #expect(w.learning.canReset)
        let availability = SettingsAvailability(safeMode: .normal, hasCommands: true, hasSettings: true, hasAccounts: true)
        let general = GeneralSettingsModel(settings: store, availability: availability, shortcutLearning: w.learning)
        #expect(general.canResetShortcutHints)
        await general.resetShortcutHints()
        #expect(!general.canResetShortcutHints && w.learning.counts.isEmpty)
        #expect(try await store.get(AppSettings.shortcutLearning).isEmpty)
        w.perform(.toolbar)
        #expect(w.notices.toasts.map(\.message) == ["Mark done: E"])
    }

    @Test func thePalettesResetSaysSo() async {
        let w = Window()
        await w.learning.start()
        w.perform(.toolbar)
        #expect(!w.learning.counts.isEmpty)
        #expect(await w.registry.run(.resetShortcutHints, source: .palette, host: w.host))
        #expect(w.learning.counts.isEmpty)
        #expect(w.notices.toasts.last?.message == ShortcutLearning.resetMessage)
    }

    @Test func everyEnvironmentHasTheHintsAndTheResetWorksInReadOnly() async throws {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 2, now: Self.now),
                                      options: .init(remoteAck: .immediate, safeMode: .readOnly))
        let learning = try #require(env.actions.shortcutHints)
        #expect(!learning.isStarted, "silent until the launch tasks start it")
        let context = ActionContext(scope: .list, safeMode: .readOnly)
        #expect(env.actions.availability(.resetShortcutHints, host: nil, context: context) == .enabled)
        #expect(GeneralSettingsModel(environment: env).shortcutLearning === learning)
    }
}
