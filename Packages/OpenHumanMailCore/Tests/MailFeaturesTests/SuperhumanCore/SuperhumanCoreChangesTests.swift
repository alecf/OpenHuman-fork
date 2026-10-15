import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct SuperhumanCoreChangesTests {
    private static let thread = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1"))

    @Test func theRemindPickerStartsOnOnlyIfNoReply() {
        let remind = TimePickerModel(kind: .remind, targets: [Self.thread]) { _ in }
        #expect(remind.onlyIfNoReply)
        let snooze = TimePickerModel(kind: .snooze, targets: [Self.thread]) { _ in }
        #expect(!snooze.onlyIfNoReply)
        let item = ReminderItem(id: "r1", thread: Self.thread, subject: "s", dueAt: fixedNow, kind: .always)
        remind.apply(snooze: nil, reminder: item)
        #expect(!remind.onlyIfNoReply, "an existing reminder keeps its own kind")
    }

    @Test func tabCountsAreConversationsByDefaultAndUnreadOnRequest() async throws {
        let tab = MailTab(location: .splitOther, title: "Other", unread: 3, total: 1_204)
        #expect(tab.count(.all) == 1_204 && tab.count(.unread) == 3)
        #expect(MailTab(location: .splitOther, title: "Other", unread: 3).count(.all) == 0, "an unknown total shows nothing")

        let f = OverlayFixture(corpus: .rich(threadCount: 40, now: fixedNow))
        await f.loaded()
        let state = try #require(f.router.active)
        #expect(state.tabCountMode == .all)
        await eventually { state.tabs.first?.total != nil }
        let first = try #require(state.tabs.first)
        #expect(state.tabCount(first) == first.total)
        try await f.env.settings?.set(AppSettings.tabCounts, .unread)
        await eventually { state.tabCountMode == .unread }
        #expect(state.tabCount(first) == first.unread)
    }

    @Test func goDoneOpensTheConversationsMarkedDone() async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 40, now: fixedNow))
        await f.loaded()
        let key = try #require(f.router.list?.cursor)
        #expect(await f.run(.markDone))
        await eventually { f.router.list?.row(for: key) == nil }
        #expect(f.registry.availability(.goDone, host: f.router).isEnabled)
        #expect(await f.run(.goDone))
        #expect(f.router.location == .system(.done))
        await eventually { f.router.list?.row(for: key) != nil }
        #expect(f.router.active?.title(for: .system(.done)) == "Done")
        var context = f.router.actionContext()
        context.selection = [key]
        context.focusedThread = key
        #expect(await f.run(.moveToInbox, context: context))
        await eventually { f.router.list?.row(for: key) == nil }
    }

    @Test func goToListsASplitTabHiddenWhileEmpty() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 40, now: fixedNow))
        await f.loaded()
        let state = try #require(f.router.active)
        await eventually { state.tabs.count >= 3 }
        let hidden = state.tabs[1]
        guard case .split(let key) = hidden.location else { throw TestFailure("no split tab") }
        f.router.go(to: hidden.location)
        await f.loaded()
        #expect(await f.run(.checkAll))
        #expect(await f.run(.markDone))
        await eventually { state.allTabs.first { $0.location == hidden.location }?.total == 0 }
        try await f.env.settings?.set(AppSettings.hideSplitWhenEmpty(state.id), [key.rawValue])
        f.router.go(to: state.allTabs[0].location)
        await eventually { !state.tabs.contains { $0.location == hidden.location } }
        #expect(await f.run(.commandPalette))
        let palette = try #require(f.palette)
        palette.query = hidden.title
        #expect(palette.entries.contains { entry in
            if case .goTo(let location) = entry.kind { location == hidden.location } else { false }
        })
    }

    @Test func getMeToZeroCountsOnlyOlderReadUnstarredConversations() {
        let model = GetMeToZeroModel(account: AccountID(1), now: { fixedNow }) { _ in }
        func c(_ n: Int64, days: Double, unread: Bool = false, starred: Bool = false) -> GetMeToZeroModel.Candidate {
            GetMeToZeroModel.Candidate(key: ThreadKey(account: AccountID(1), rowID: n, gmailThreadID: GmailThreadID("t\(n)")),
                                       lastMessageAt: fixedNow.addingTimeInterval(-days * 86_400), isUnread: unread,
                                       isStarred: starred)
        }
        model.setCandidates([c(1, days: 0.5), c(2, days: 3), c(3, days: 10), c(4, days: 40),
                             c(5, days: 40, unread: true), c(6, days: 40, starred: true)])
        #expect(model.age == .week && model.matchCount == 2, "older than a week, read, unstarred: 3 and 4")
        #expect(model.chooseNumber(1) && model.matchCount == 3, "older than a day: 2, 3, 4")
        #expect(model.chooseNumber(3) && model.matchCount == 1, "older than a month: 4")
        model.keepUnread = false
        model.keepStarred = false
        #expect(model.matchCount == 3, "4, 5, 6")
        #expect(model.chooseNumber(4) && model.matchCount == 6, "everything")
        #expect(!model.chooseNumber(5))
        #expect(model.confirmTitle == "Archive 6 conversations")
    }

    @Test func getMeToZeroArchivesAsOneBatchAndBulkActionsPutsItBack() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 40, now: fixedNow))
        await f.loaded()
        let before = f.rows.count
        #expect(f.registry.availability(.getMeToZero, host: f.router).isEnabled)
        #expect(await f.run(.getMeToZero))
        guard case .zero(let model) = f.center.overlay else { throw TestFailure("no Get me to zero card") }
        await eventually { !model.isLoading }
        model.chooseNumber(4)
        model.keepUnread = false
        model.keepStarred = false
        let count = model.matchCount
        #expect(count > 0)
        model.confirm()
        #expect(model.isClosed)
        await eventually { f.env.notices.toasts.contains { $0.message.hasPrefix("Marked") && $0.style == .undo } }
        await eventually { f.rows.count < before }
        await eventuallyAsync { ((try? await f.env.settings?.get(AppSettings.lastBulkArchive)) ?? nil) != nil }
        let receipt = try #require(try await f.env.settings?.get(AppSettings.lastBulkArchive) ?? nil)
        #expect(receipt.threads.count == count && receipt.isReversible(at: Date()))
        #expect(!receipt.isReversible(at: receipt.archivedAt.addingTimeInterval(BulkArchiveReceipt.lifetime)))
        #expect(await f.run(.undoBulkArchive))
        await eventually { f.rows.count == before }
        #expect(try await f.env.settings?.get(AppSettings.lastBulkArchive) ?? nil == nil)
    }
}
