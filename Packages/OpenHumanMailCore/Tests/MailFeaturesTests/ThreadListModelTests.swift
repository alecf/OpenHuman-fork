import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Test func loadsTheInboxWindowAndPutsTheCursorOnTheFirstRow() async {
    let store = FakeMailStore(corpus: .make(threadCount: 150, now: fixedNow))
    let model = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
    model.start()
    await eventually { model.state == .loaded }
    #expect(model.rows.count == ThreadListModel.initialLimit)
    #expect(model.hasMore)
    #expect(model.totalCount == 150)
    #expect(model.cursor == model.rows.first?.id)
}

@MainActor
@Test func jAndKMoveTheCursorWithoutWrapping() async {
    let store = FakeMailStore(corpus: .make(threadCount: 3, now: fixedNow))
    let model = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
    model.start()
    await eventually { model.rows.count == 3 }
    #expect(model.moveCursor(by: 1))
    #expect(model.cursorIndex == 1)
    #expect(model.moveCursor(by: 1))
    #expect(!model.moveCursor(by: 1))
    #expect(model.cursorIndex == 2)
    model.moveCursor(by: -5)
    #expect(model.cursorIndex == 0)
}

@MainActor
@Test func cursorLandsOnTheNextRowWhenItsRowLeaves() async {
    let store = FakeMailStore(corpus: .make(threadCount: 5, now: fixedNow))
    let model = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
    model.start()
    await eventually { model.rows.count == 5 }
    model.moveCursor(by: 2)
    let below = model.rows[3].id
    store.removeThreads([model.rows[2].id])
    await eventually { model.rows.count == 4 }
    #expect(model.cursor == below)
    model.moveCursor(by: 10)
    let above = model.rows[2].id
    store.removeThreads([model.rows[3].id])
    await eventually { model.rows.count == 3 }
    #expect(model.cursor == above)
    store.removeThreads(Set(model.rows.map(\.id)))
    await eventually { model.rows.isEmpty }
    #expect(model.cursor == nil)
}

@MainActor
@Test func cursorStaysOnItsThreadWhenNewMailArrivesAbove() async {
    let corpus = FakeCorpus.make(threadCount: 6, now: fixedNow)
    let store = FakeMailStore(corpus: FakeCorpus(account: corpus.account, threads: Array(corpus.threads.dropFirst())))
    let model = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
    model.start()
    await eventually { model.rows.count == 5 }
    model.moveCursor(by: 1)
    let key = model.cursor
    store.insertAtTop(corpus.threads[0])
    await eventually { model.rows.count == 6 }
    #expect(model.cursor == key)
    #expect(model.cursorIndex == 2)
}

@MainActor
@Test func windowGrowsNearTheEndUpToTheCap() async {
    let store = FakeMailStore(corpus: .make(threadCount: 350, now: fixedNow))
    let model = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
    model.start()
    await eventually { model.rows.count == 100 }
    model.visibleRowsDidChange(lastVisibleIndex: 50)
    #expect(model.limit == 100)
    model.visibleRowsDidChange(lastVisibleIndex: 75)
    await eventually { model.rows.count == 300 }
    #expect(model.limit == 300)
    model.visibleRowsDidChange(lastVisibleIndex: 290)
    await eventually { model.rows.count == 350 }
    #expect(!model.hasMore)
}
