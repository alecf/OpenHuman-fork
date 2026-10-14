import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Test func expandsUnreadAndLastAndRendersTheirBodiesOnly() async throws {
    let corpus = FakeCorpus.make(threadCount: 40, now: fixedNow)
    let thread = try #require(corpus.threads.first { $0.detail.messages.count >= 3 })
    let model = ReaderModel(thread: thread.row.id, data: FakeMailStore(corpus: corpus), renderQueue: RenderQueue())
    model.start()
    await eventually { model.state == .loaded }
    #expect(model.subject == thread.detail.subject)
    let expected = thread.detail.messages.map { $0.isUnread || $0.id == thread.detail.messages.last?.id }
    #expect(model.messages.map(\.isExpanded) == expected)
    await eventually { model.messages.filter(\.isExpanded).allSatisfy { if case .rendered = $0.body { return true }; return false } }
    #expect(model.messages.filter { !$0.isExpanded }.allSatisfy { $0.body == .notLoaded })
}

@MainActor
@Test func toggleExpandsAndLoadsACollapsedMessage() async throws {
    let corpus = FakeCorpus.make(threadCount: 40, now: fixedNow)
    let thread = try #require(corpus.threads.first { $0.detail.messages.count >= 2 && !$0.detail.messages[0].isUnread })
    let model = ReaderModel(thread: thread.row.id, data: FakeMailStore(corpus: corpus), renderQueue: RenderQueue())
    model.start()
    await eventually { model.state == .loaded }
    let first = model.messages[0].id
    #expect(!model.messages[0].isExpanded)
    model.toggle(first)
    #expect(model.messages[0].isExpanded)
    await eventually { if case .rendered = model.messages[0].body { return true }; return false }
}

@MainActor
@Test func showsFetchingUntilTheBodyArrives() async throws {
    let corpus = FakeCorpus.make(threadCount: 5, now: fixedNow)
    let waiting = ReaderModel(thread: corpus.threads[0].row.id, data: FakeMailStore(corpus: corpus, bodyDelay: .seconds(3_600)),
                              renderQueue: RenderQueue())
    waiting.start()
    await untilObserved { waiting.messages.last?.body == .fetching }
    let arriving = ReaderModel(thread: corpus.threads[0].row.id, data: FakeMailStore(corpus: corpus, bodyDelay: .zero),
                               renderQueue: RenderQueue())
    arriving.start()
    await untilObserved { if case .rendered = arriving.messages.last?.body { return true }; return false }
    #expect(waiting.messages.last?.body == .fetching, "still waiting for its body")
}

@MainActor
@Test func missingThreadIsReported() async {
    let store = FakeMailStore(corpus: .make(threadCount: 2, now: fixedNow))
    let model = ReaderModel(thread: ThreadKey(account: AccountID(1), rowID: 999, gmailThreadID: GmailThreadID("x")),
                            data: store, renderQueue: RenderQueue())
    model.start()
    await eventually { model.state == .missing }
}

@MainActor
@Test func windowModelOpensClosesAndStepsThroughThreads() async {
    let env = AppEnvironment.fake(corpus: .make(threadCount: 10, now: fixedNow))
    let window = MailWindowModel(environment: env)
    window.start()
    await untilObserved { window.list?.rows.count == 10 }
    #expect(window.perform(.nextThread))
    #expect(window.list?.cursorIndex == 1)
    #expect(window.perform(.openThread))
    #expect(window.mode == .reader)
    #expect(window.reader?.thread == window.list?.rows[1].id)
    #expect(window.perform(.nextThread))
    #expect(window.reader?.thread == window.list?.rows[2].id)
    #expect(window.perform(.backToList))
    #expect(window.mode == .list)
    #expect(window.reader == nil)
    #expect(window.list?.cursorIndex == 2)
    #expect(!window.perform(.backToList), "Esc in the list is not the slice's to handle")
}
