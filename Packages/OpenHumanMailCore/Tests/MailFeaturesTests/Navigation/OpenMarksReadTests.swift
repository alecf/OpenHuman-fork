import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct OpenMarksReadTests {
    private static let dana = EmailAddress(name: "Dana Ruiz", email: "dana@example.com")

    private func firstDetail(_ store: FakeMailStore, _ key: ThreadKey) async throws -> ConversationDetail? {
        for try await detail in store.threadDetail(key) { return detail }
        return nil
    }

    @Test func openingReadsTheWholeConversationAtOnceAndQueuesOneChange() async throws {
        let f = ActionFixture(options: .init(remoteAck: .manual))
        await f.loaded(10)
        let key = try #require(f.rows.first { $0.isUnread }?.id)
        f.store.deliverMessage(account: key.account, to: key, from: Self.dana)
        let unread = try #require(try await firstDetail(f.store, key)).messages.filter(\.isUnread).map(\.id)
        #expect(unread.count >= 2)
        f.router.open(key)
        await eventually { f.router.list?.row(for: key)?.isUnread == false }
        let reader = try #require(f.router.reader)
        await eventually { reader.state == .loaded && !reader.messages.isEmpty
            && reader.messages.allSatisfy { !$0.summary.isUnread } }
        #expect(unread.allSatisfy { reader.message($0)?.isExpanded == true }, "the read folds none of them")
        #expect(f.store.pendingOperationCount == 1, "one change for the whole conversation, queued for Gmail")
        #expect(f.env.notices.toasts.isEmpty && f.env.undo?.stack.isEmpty == true, "silent: the user pressed no key")
        #expect(f.router.active?.localReads.isEmpty == true, "written, not kept on this Mac only")
    }

    @Test func markUnreadKeepsItUnreadUntilItIsOpenedAgain() async throws {
        let f = ActionFixture(options: .init(remoteAck: .manual))
        await f.loaded(10)
        let key = try #require(f.rows.first { $0.isUnread }?.id)
        f.router.open(key)
        await eventually { f.router.list?.row(for: key)?.isUnread == false }
        let reader = try #require(f.router.reader)
        await eventually { !reader.messages.isEmpty && reader.messages.allSatisfy { !$0.summary.isUnread } }

        #expect(await f.run(.toggleRead))
        await f.toast("Marked unread")
        await eventually { f.router.list?.row(for: key)?.isUnread == true }
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.router.list?.row(for: key)?.isUnread == true, "nothing reads it again while it stays open")
        #expect(f.env.undo?.stack.map { String(localized: $0.title) } == ["Marked unread"], "⌘Z is the `u`, not the open")

        #expect(await f.run(.undo))
        await eventually { f.router.list?.row(for: key)?.isUnread == false }
        #expect(await f.run(.toggleRead))
        await eventually { f.router.list?.row(for: key)?.isUnread == true }
        f.router.closeReader()
        f.router.open(key)
        await eventually { f.router.list?.row(for: key)?.isUnread == false }
    }

    @Test func readOnlyReadsItOnThisMacOnly() async throws {
        let f = ActionFixture(options: .init(remoteAck: .manual, safeMode: .readOnly))
        await f.loaded(10)
        let row = try #require(f.rows.first { $0.isUnread })
        let key = row.id
        f.router.open(key)
        await eventually { f.router.list?.row(for: key)?.isUnread == false }
        let reader = try #require(f.router.reader)
        await eventually { reader.state == .loaded && !reader.messages.isEmpty
            && reader.messages.allSatisfy { !$0.summary.isUnread } }
        #expect(f.store.pendingOperationCount == 0, "nothing queued")
        #expect(try await firstDetail(f.store, key)?.messages.contains(where: \.isUnread) == true, "the source unchanged")
        #expect(f.env.notices.toasts.isEmpty, "no refusal toast for a key the user did not press")
        #expect(f.env.undo?.stack.isEmpty == true)

        f.router.closeReader()
        f.router.go(to: .system(.starred))
        await eventually { f.router.list?.location == .system(.starred) && f.router.list?.state == .loaded }
        f.router.go(to: .system(.inbox))
        await eventually { f.router.list?.location == .system(.inbox) && f.router.list?.row(for: key) != nil }
        #expect(f.router.list?.row(for: key)?.isUnread == false)

        f.store.deliverMessage(account: key.account, to: key, from: Self.dana, at: row.lastMessageAt + 3_600)
        await eventually { f.router.list?.row(for: key)?.isUnread == true }
        f.router.open(key)
        await eventually { f.router.list?.row(for: key)?.isUnread == false }
        #expect(f.store.pendingOperationCount == 0)
    }

    @Test func aPortRefusingForSafeModeReadsItOnThisMacOnly() async throws {
        let f = ActionFixture(options: .init(remoteAck: .manual))
        await f.loaded(10)
        let key = try #require(f.rows.first { $0.isUnread }?.id)
        f.store.failNextCommand(.blockedBySafeMode)
        f.router.open(key)
        await eventually { f.router.active?.localReads[key] != nil }
        await eventually { f.router.list?.row(for: key)?.isUnread == false }
        #expect(f.store.pendingOperationCount == 0)
        #expect(f.env.notices.toasts.isEmpty)
    }

    @Test func localReadsShowARowReadUntilNewerMailArrives() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        let key = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t7"))
        func row(lastMessageAt: Date) -> ThreadRow {
            ThreadRow(id: key, subject: "Subject", snippet: "s", participantsDisplay: "P", participants: [],
                      messageCount: 2, unreadCount: 2, draftCount: 0, attachmentCount: 0, isUnread: true,
                      isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: lastMessageAt,
                      sortAt: lastMessageAt)
        }
        var overlay = ThreadListOverlay()
        let before = overlay.version
        let marked = overlay.markReadLocally(key, through: at)
        let markedAgain = overlay.markReadLocally(key, through: at - 60)
        #expect(marked && !markedAgain, "an older date changes nothing")
        #expect(overlay.version == before + 1)
        #expect(overlay.isEmpty && overlay.touchedKeys.isEmpty, "not an entry: never confirmed, never expires")
        let shown = overlay.apply(to: [row(lastMessageAt: at)]).rows[0]
        #expect(!shown.isUnread && shown.unreadCount == 0)
        #expect(overlay.apply(to: [row(lastMessageAt: at + 60)]).rows[0].isUnread, "newer mail is unread")
        let expired = overlay.expire(now: at + 3_600)
        #expect(!expired && overlay.localReads[key] == at, "local reads never expire")
    }

    @Test func aMessageReadWhileShownStaysOpen() async throws {
        let detail = ReaderFixtures.conversation(61, count: 4, from: ReaderFixtures.dana, unread: [1, 2])
        let model = ReaderModel(thread: detail.id, data: ReaderTestSource(details: [detail], bodies: [:]),
                                renderQueue: RenderQueue())
        model.start()
        await eventually { model.state == .loaded }
        #expect(model.messages.map(\.isExpanded) == [false, true, true, true])
        let read = ConversationDetail(id: detail.id, subject: detail.subject, messages: detail.messages.map { s in
            MessageSummary(id: s.id, from: s.from, to: s.to, cc: s.cc, bcc: s.bcc, date: s.date, snippet: s.snippet,
                           isUnread: false, attachments: s.attachments)
        })
        model.apply(read)
        #expect(model.messages.map(\.isExpanded) == [false, true, true, true], "the read folds nothing")
        model.apply(read)
        #expect(model.messages.map(\.isExpanded) == [false, true, true, true])
    }

    @Test func aReaderReadHereOnlyKeepsLaterMailUnread() async throws {
        let detail = ReaderFixtures.conversation(62, count: 3, from: ReaderFixtures.dana, unread: [1, 2])
        let model = ReaderModel(thread: detail.id, data: ReaderTestSource(details: [detail], bodies: [:]),
                                renderQueue: RenderQueue())
        model.start()
        await eventually { model.state == .loaded }
        model.markReadLocally(through: detail.messages[2].date)
        #expect(model.messages.allSatisfy { !$0.summary.isUnread })
        #expect(model.messages.map(\.isExpanded) == [false, true, true])
        let arrived = ReaderFixtures.summary(6_299, from: ReaderFixtures.dana, unread: true, minutesAgo: 0)
        model.apply(ConversationDetail(id: detail.id, subject: detail.subject, messages: detail.messages + [arrived]))
        #expect(model.message(arrived.id)?.summary.isUnread == true, "newer than the read")
        #expect(model.messages.prefix(3).allSatisfy { !$0.summary.isUnread }, "the source still says unread; read here")
    }
}
