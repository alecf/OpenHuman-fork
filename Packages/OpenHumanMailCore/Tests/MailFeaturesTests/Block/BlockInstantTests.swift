import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

final class HeldRuleSettings: SettingsPort {
    let store: FakeMailStore
    let hold: Checkpoint?
    private let failing = Mutex(false)

    init(_ store: FakeMailStore, hold: Checkpoint?) {
        self.store = store
        self.hold = hold
    }

    func failRuleWrites() { failing.withLock { $0 = true } }

    func observe<V>(_ key: AppSettingKey<V>) -> AsyncStream<V> { store.observe(key) }
    func get<V>(_ key: AppSettingKey<V>) async throws -> V { try await store.get(key) }
    func set<V>(_ key: AppSettingKey<V>, _ value: V) async throws {
        if key.name == BlockSettingNames.rules {
            await hold?.pass()
            if failing.withLock({ $0 }) { throw MailPortError.unavailable("injected failure") }
        }
        try await store.set(key, value)
    }
}

@MainActor
final class BlockFixture {
    let store: FakeMailStore
    let settings: HeldRuleSettings
    let env: AppEnvironment
    let router: AppRouter
    let account = AccountID(1)
    private(set) var posted: [String] = []

    init(corpus: FakeCorpus = .make(threadCount: 6, now: fixedNow), hold: Checkpoint? = nil) {
        store = FakeMailStore(corpus: corpus, options: .init(remoteAck: .immediate, now: { fixedNow }))
        settings = HeldRuleSettings(store, hold: hold)
        env = AppEnvironment(data: store, commands: store, accounts: store, settings: settings, isFake: true,
                             featureFlags: FeatureFlags())
        router = AppRouter(environment: env, location: .system(.inbox))
        env.notices.onPost = { [weak self] toast in self?.posted.append(toast.message) }
    }

    func deliver(from sender: String, subject: String = "Synthetic news") async throws -> ThreadKey {
        _ = store.deliverMessage(account: account, from: EmailAddress(name: nil, email: sender), subject: subject,
                                 unread: false, at: fixedNow)
        let rows = try await store.threadPage(.system(.inbox), account: account, after: nil, limit: 100).rows
        return try #require(rows.first { $0.subject == subject }).id
    }

    func startShowing(_ key: ThreadKey) async throws -> AccountState {
        router.start()
        await untilObserved { self.listed(key) }
        let state = try #require(router.active)
        state.open(key)
        return state
    }

    func listed(_ key: ThreadKey) -> Bool { router.list?.rows.contains { $0.id == key } == true }

    func context(_ thread: ThreadKey, sender: String) -> ActionContext {
        var c = router.actionContext()
        c.account = account
        c.focusedThread = thread
        c.selection = [thread]
        c.sender = sender
        return c
    }

    @discardableResult
    func block(_ thread: ThreadKey, sender: String) async -> Bool {
        await env.actions.run(.blockSender, source: .keyboard, host: router, context: context(thread, sender: sender))
    }

    func rules() async -> [BlockRule] { (try? await store.get(BlockKeys.rules(account))) ?? [] }

    func inStoreInbox(_ key: ThreadKey) async throws -> Bool {
        try await store.threadPage(.system(.inbox), account: account, after: nil, limit: 100).rows.contains { $0.id == key }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BlockInstantTests {
    @Test func theThreadLeavesAndTheReaderMovesOnBeforeTheRuleIsSaved() async throws {
        let hold = Checkpoint()
        let f = BlockFixture(hold: hold)
        let news = try await f.deliver(from: "news@acme.example")
        let state = try await f.startShowing(news)
        let next = try #require(state.neighbor(of: news))

        let blocking = Task { await f.block(news, sender: "news@acme.example") }
        await hold.arrived()
        #expect(!f.listed(news), "the row goes at once")
        #expect(state.reader?.thread == next, "the reader moves to the next conversation at once")
        #expect(await f.rules().isEmpty, "the rule is still being written")
        #expect(f.env.undo?.stack.map { String(localized: $0.title) } == ["Blocked news@acme.example"], "the pending Undo entry shows while the rule is saved")
        #expect(f.env.notices.toasts.contains { $0.message.hasPrefix("Blocked") })

        hold.release()
        _ = await blocking.value
        #expect(await f.rules().map(\.id) == ["sender:news@acme.example"])
        #expect(try await f.inStoreInbox(news) == false, "archived, the default for blocked mail")
        #expect(f.env.undo?.stack.map { String(localized: $0.title) } == ["Blocked news@acme.example"])
    }

    @Test func aRuleThatCannotBeSavedBringsTheThreadBackWithANotice() async throws {
        let hold = Checkpoint()
        let f = BlockFixture(hold: hold)
        let news = try await f.deliver(from: "news@acme.example")
        let state = try await f.startShowing(news)
        f.settings.failRuleWrites()

        let blocking = Task { await f.block(news, sender: "news@acme.example") }
        await hold.arrived()
        #expect(!f.listed(news))

        hold.release()
        _ = await blocking.value
        #expect(state.reader?.thread == news, "the reader is back on it")
        await untilObserved { f.listed(news) }
        #expect(f.posted.contains("Couldn't block news@acme.example"))
        #expect(await f.rules().isEmpty)
        #expect(try await f.inStoreInbox(news), "nothing moved")
        #expect(f.env.undo?.stack.isEmpty == true)
        #expect(!f.env.notices.toasts.contains { $0.message.hasPrefix("Blocked") }, "the Undo toast is gone")
    }

    @Test func undoBringsTheThreadBackAndRemovesTheRule() async throws {
        let f = BlockFixture()
        let news = try await f.deliver(from: "news@acme.example")
        let state = try await f.startShowing(news)
        #expect(await f.block(news, sender: "news@acme.example"))
        #expect(try await f.inStoreInbox(news) == false)
        #expect(state.reader?.thread != news)

        #expect(await f.env.actions.run(.undo, source: .keyboard, host: f.router))
        #expect(await f.rules().isEmpty, "one undo takes back the rule")
        #expect(try await f.inStoreInbox(news), "and the move")
        #expect(state.reader?.thread == news, "and reopens the conversation")
        await untilObserved { f.listed(news) }
    }

    @Test func theOtherConversationsFromThemAreOfferedWithoutTheOneAlreadyMoved() async throws {
        let f = BlockFixture()
        let older = try await f.deliver(from: "news@acme.example", subject: "Last week's news")
        let news = try await f.deliver(from: "news@acme.example")
        _ = try await f.startShowing(news)
        #expect(await f.block(news, sender: "news@acme.example"))
        #expect(f.posted.contains("Blocked news@acme.example. Clean up 1 conversation from them?"))
        #expect(try await f.inStoreInbox(older), "the rest waits for the answer")
    }

    @Test func aSenderYouWroteToStaysPutUntilYouSayBlockAnyway() async throws {
        let corpus = FakeCorpus.make(threadCount: 10, now: fixedNow)
        let thread = try #require(corpus.threads.first { t in
            t.detail.messages.contains { $0.from?.email == FakeCorpus.me.email && !$0.to.isEmpty }
        })
        let counterpart = try #require(thread.detail.messages.first { $0.from?.email != FakeCorpus.me.email }?.from?.email)
        let f = BlockFixture(corpus: corpus)
        let key = thread.row.id
        let state = try await f.startShowing(key)
        let question = "You've written to \(counterpart). Block it anyway?"

        #expect(await f.block(key, sender: counterpart))
        #expect(f.listed(key) && state.reader?.thread == key, "nothing moves before the answer")
        #expect(await f.rules().isEmpty)

        let ask = try #require(f.env.notices.toasts.first { $0.message == question })
        await f.env.notices.activate(ask.id)
        #expect(!f.listed(key), "Block anyway hides it")
        #expect(state.reader?.thread != key, "and moves on")
        #expect(await f.rules().map(\.id) == ["sender:\(counterpart)"])
    }

    @Test func aMoveTheWritePortRefusesSavesNoRuleAndBringsTheThreadBack() async throws {
        let f = BlockFixture()
        let news = try await f.deliver(from: "news@acme.example")
        f.router.start()
        await untilObserved { f.listed(news) }
        f.store.failNextCommand(.unavailable("Gmail can't be reached"))
        #expect(await f.block(news, sender: "news@acme.example"))
        #expect(await f.rules().isEmpty, "the rule is taken back with the failed move")
        await untilObserved { f.listed(news) }
        #expect(f.posted.contains("Couldn't block news@acme.example"))
        #expect(try await f.inStoreInbox(news), "nothing moved")
        #expect(f.env.undo?.stack.isEmpty == true)
    }
}
