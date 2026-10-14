import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct ThreadListBlankRowsTests {
    private let account = AccountID(1)

    private func scrollToTheEnd(_ model: ThreadListModel) {
        let count = model.displayCount
        model.visibleDisplayRangeDidChange(max(0, count - 20)..<count)
    }

    @Test func theOtherTabListsEveryNewsletterAsItsOwnRowAndPagesPastTheLiveWindow() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 4_000, now: fixedNow))
        let model = ThreadListModel(data: store, location: .splitOther, account: account, now: { fixedNow })
        model.start()
        await eventually { !model.rows.isEmpty }
        let total = model.totalCount
        try #require(total > ThreadListModel.maximumLiveWindow + ThreadListModel.pageSize,
                     "more rows than the live window holds")
        try #require(model.placeholderCount > 0, "the rows not loaded yet are placeholders")
        await eventually(timeout: .seconds(30)) {
            scrollToTheEnd(model)
            return model.rows.count == total
        }
        #expect(model.limit == ThreadListModel.maximumLiveWindow, "the rows past 2,000 came from static pages")
        #expect(model.placeholderCount == 0 && !model.hasMore && !model.pagingFailed)
        let ids = model.rows.map(\.id)
        #expect(Set(ids).count == ids.count, "every conversation once")
        #expect(ids.allSatisfy { $0.rowID > 0 }, "store rows only: no folded or made-up row")
        let newsletters = ids.indices.filter { model.rows[$0].subject.hasSuffix(" weekly") }
        #expect(newsletters.count > 200, "hundreds of newsletters, each its own row")
        #expect(newsletters.contains { $0 >= ThreadListModel.maximumLiveWindow }, "also in the static pages")
    }

    @Test func aFailedPageReadKeepsThePlaceholdersAndRetryLoadsThem() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 3_000, now: fixedNow))
        let flaky = FlakySource(base: store, pageFailures: 1, windowFailureAtLimit: nil)
        let model = ThreadListModel(data: flaky, location: .system(.inbox), account: account, now: { fixedNow })
        model.start()
        await eventually { model.rows.count == ThreadListModel.initialLimit }
        model.visibleRangeDidChange(2_400..<2_430)
        await eventually(timeout: .seconds(20)) { model.pagingFailed }
        #expect(!model.isPagingUnavailable, "a failing read is not a source that cannot page")
        #expect(model.placeholderCount > 0, "the rows are still coming: placeholders stay (as a loading skeleton)")
        model.retryPaging()
        await eventually(timeout: .seconds(20)) { model.rows.count == 3_000 }
        #expect(!model.pagingFailed && model.placeholderCount == 0)
    }

    @Test func aFailedLiveWindowGrowthIsRetried() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 1_000, now: fixedNow))
        let flaky = FlakySource(base: store, pageFailures: 0, windowFailureAtLimit: 300)
        let model = ThreadListModel(data: flaky, location: .system(.inbox), account: account, now: { fixedNow })
        model.start()
        await eventually { model.rows.count == ThreadListModel.initialLimit }
        model.visibleRangeDidChange(80..<100)
        await eventually { model.pagingFailed }
        #expect(model.rows.count == ThreadListModel.initialLimit, "the loaded rows stay on screen")
        model.retryPaging()
        await eventually { model.rows.count >= 300 }
        #expect(!model.pagingFailed)
    }

    @Test func rapidJumpsEndWithTheLastVisibleWindowLoaded() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 5_000, now: fixedNow))
        let model = ThreadListModel(data: store, location: .system(.inbox), account: account, now: { fixedNow })
        model.start()
        await eventually { model.rows.count == ThreadListModel.initialLimit }
        for jump in [2_400, 150, 4_900, 40, 3_300] {
            model.visibleRangeDidChange(jump..<(jump + 25))
        }
        await eventually(timeout: .seconds(30)) {
            model.visibleRangeDidChange(3_300..<3_325)
            return model.rows.count > 3_325
        }
        #expect(model.rows[3_300...3_324].allSatisfy { !$0.subject.isEmpty })
        model.visibleRangeDidChange(0..<25)
        #expect(model.rows.count > 3_325)
    }
}

private final class FlakySource: MailDataSource, @unchecked Sendable {
    private let base: FakeMailStore
    private let lock = NSLock()
    private var pageFailures: Int
    private var windowFailureAtLimit: Int?

    init(base: FakeMailStore, pageFailures: Int, windowFailureAtLimit: Int?) {
        self.base = base
        self.pageFailures = pageFailures
        self.windowFailureAtLimit = windowFailureAtLimit
    }

    func accounts() -> AsyncThrowingStream<[Account], Error> { base.accounts() }
    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        let fails = lock.withLock { () -> Bool in
            guard windowFailureAtLimit == limit else { return false }
            windowFailureAtLimit = nil
            return true
        }
        if fails { return AsyncThrowingStream { $0.finish(throwing: MailPortError.unavailable("busy")) } }
        return base.threadWindow(location, account: account, limit: limit)
    }
    func threadPage(_ location: MailLocation, account: AccountID, after: PageCursor?,
                    limit: Int) async throws -> (rows: [ThreadRow], next: PageCursor?) {
        let fails = lock.withLock { () -> Bool in
            guard pageFailures > 0 else { return false }
            pageFailures -= 1
            return true
        }
        if fails { throw MailPortError.unavailable("busy") }
        return try await base.threadPage(location, account: account, after: after, limit: limit)
    }
    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> { base.threadDetail(key) }
    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> { base.body(key) }
}
