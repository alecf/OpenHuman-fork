import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct DailyFlowTests {
    @Test func openingAnUnreadConversationMarksItReadWithoutAnUndoEntry() async throws {
        let f = ActionFixture(options: .init(remoteAck: .manual))
        await f.loaded(10)
        let key = try #require(f.rows.first { $0.isUnread }?.id)
        f.router.open(key)
        await eventually { f.router.list?.row(for: key)?.isUnread == false }
        await eventually { f.store.pendingOperationCount > 0 }
        #expect(f.env.notices.toasts.isEmpty, "no toast: the user pressed no key")
        #expect(f.env.undo?.stack.isEmpty == true, "no entry of its own, so ⌘Z after `e` stays the `e`")

        await eventually { f.router.active?.reader?.messages.isEmpty == false
            && f.router.active?.reader?.messages.contains { $0.summary.isUnread } == false }
        #expect(await f.run(.toggleRead))
        await f.toast("Marked unread")
        await eventually { f.router.list?.row(for: key)?.isUnread == true }
    }

    @Test func readOnlyOpeningWritesNothingAndSaysNothing() async throws {
        let f = ActionFixture(options: .init(safeMode: .readOnly))
        await f.loaded(10)
        let key = try #require(f.rows.first { $0.isUnread }?.id)
        f.router.open(key)
        await eventually { f.router.active?.reader?.messages.isEmpty == false }
        await eventually { f.router.list?.row(for: key)?.isUnread == false }
        #expect(f.store.pendingOperationCount == 0, "stopped before the port, as `s` is")
        #expect(f.env.notices.toasts.isEmpty, "no refusal toast for a key the user did not press")
    }

    @Test func openingAReadConversationWritesNothing() async throws {
        let f = ActionFixture(options: .init(remoteAck: .manual))
        await f.loaded(10)
        let key = try #require(f.rows.first { !$0.isUnread }?.id)
        f.router.open(key)
        await eventually { f.router.active?.reader?.messages.isEmpty == false }
        #expect(f.store.pendingOperationCount == 0)
    }

    @Test func undoAfterDoneAndNextReopensTheConversationAndLeavesReadStatesAlone() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        let rows = f.rows
        let index = try #require(rows.indices.dropLast(2).first { rows[$0 + 1].isUnread })
        let (a, b) = (rows[index].id, rows[index + 1].id)
        f.router.open(a)
        await eventually { f.router.list?.row(for: a)?.isUnread == false }
        await eventually { f.router.active?.reader?.messages.isEmpty == false }
        #expect(await f.run(.toggleRead))
        await eventually { f.router.list?.row(for: a)?.isUnread == true }
        #expect(await f.run(.markDone))
        #expect(f.router.active?.reader?.thread == b, "done and next")
        await eventually { f.router.list?.row(for: b)?.isUnread == false }
        #expect(f.env.undo?.nextUndo.map { String(localized: $0.title) } == "Marked done")

        #expect(await f.run(.undo))
        await eventually { f.router.active?.reader?.thread == a }
        await eventually { f.router.list?.row(for: a) != nil && f.router.list?.cursor == a }
        #expect(f.router.active?.mode == .reader)
        #expect(f.router.list?.row(for: a)?.isUnread == true, "as before the `e`: the reopen marks nothing read")
        #expect(f.router.list?.row(for: b)?.isUnread == false, "⌘Z undid the `e`, not the next conversation's read")

        #expect(await f.run(.markDone))
        #expect(f.router.active?.reader?.thread == b)
        #expect(await f.run(.nextThread))
        let reading = try #require(f.router.active?.reader?.thread)
        #expect(reading != b && reading != a)
        #expect(await f.run(.undo))
        await eventually { f.router.list?.row(for: a) != nil }
        #expect(f.router.active?.reader?.thread == reading, "moved on: the reader stays")
    }

    private func outside() async throws -> (f: ActionFixture, rows: [ThreadKey], outside: ThreadKey) {
        let f = ActionFixture()
        await f.loaded(10)
        let rows = f.rows.map(\.id)
        _ = try await f.store.apply(.markDone([rows[9]]))
        await f.loaded(9)
        return (f, Array(rows.prefix(9)), rows[9])
    }

    @Test func jAndKFromTheListCarryOnAtTheCursor() async throws {
        let (f, rows, outside) = try await outside()
        f.router.list?.setCursor(rows[3])
        f.router.open(outside)
        #expect(f.router.active?.reader?.thread == outside)
        #expect(f.router.list?.cursor == rows[3], "the list keeps the place the user left it")
        #expect(await f.run(.nextThread))
        #expect(f.router.active?.reader?.thread == rows[3], "j: the row the user was on")

        f.router.closeReader()
        f.router.list?.setCursor(rows[3])
        f.router.open(outside)
        #expect(await f.run(.previousThread))
        #expect(f.router.active?.reader?.thread == rows[2], "k: the row above it")
    }

    @Test func jAndKWhileReadingCarryOnAfterTheConversationRead() async throws {
        let (f, rows, outside) = try await outside()
        f.router.open(rows[3])
        f.router.open(outside)
        #expect(await f.run(.nextThread))
        #expect(f.router.active?.reader?.thread == rows[4], "j: the one after the conversation the user was reading")

        f.router.open(rows[3])
        f.router.open(outside)
        #expect(await f.run(.previousThread))
        #expect(f.router.active?.reader?.thread == rows[3], "k: back to it")
    }

    @Test func doneAndNextFromOutsideTheListOpensTheNextRow() async throws {
        let (f, rows, outside) = try await outside()
        f.router.open(rows[3])
        f.router.open(outside)
        #expect(await f.run(.markDone))
        #expect(f.router.active?.mode == .reader, "done and next, not back to the list")
        #expect(f.router.active?.reader?.thread == rows[4])

        f.router.closeReader()
        f.router.list?.setCursor(rows[5])
        f.router.open(outside)
        #expect(await f.run(.trash))
        #expect(f.router.active?.reader?.thread == rows[5], "from the list: the row the user was on")
    }

    @Test func anUndoWindowKeepsItsToastWhileTriageToastsComeAndGo() async throws {
        let f = ActionFixture()
        await f.loaded(10)
        let undo = try #require(f.env.undo)
        undo.push(UndoCoordinator.Entry(title: "Reply sent.", token: UndoToken(payload: Data()),
                                        expiresAt: Date().addingTimeInterval(10)))
        #expect(await f.run(.markDone))
        #expect(await f.run(.markDone))
        #expect(f.toastMessages == ["Reply sent.", "Marked done"], "the send's Undo stays up for its window")
    }

    @Test func toastsWithWindowsGoOldestFirstOnlyAmongThemselves() {
        let notices = NoticeCenter(now: { fixedNow }, autoExpire: false)
        notices.post("Sent 1", style: .undo, holdsWindow: true)
        notices.post("Done 1", style: .undo)
        notices.post("Done 2", style: .undo)
        #expect(notices.toasts.map(\.message) == ["Sent 1", "Done 2"])
        notices.post("Sent 2", style: .undo, holdsWindow: true)
        #expect(notices.toasts.map(\.message) == ["Sent 1", "Sent 2"])
        notices.post("Sent 3", style: .undo, holdsWindow: true)
        #expect(notices.toasts.map(\.message) == ["Sent 2", "Sent 3"], "all held: the oldest goes")
    }

    @Test func zUndoesInTheListAndAConversationOnly() throws {
        let undo = try #require(ActionCatalog.descriptor(.undo))
        let z = try #require(undo.defaultBindings.first { $0.chords == KeyBinding.key("z").chords })
        #expect(undo.scopes(of: z) == [.list, .reader])
        #expect(undo.shortcutHint == "⌘Z", "menus keep ⌘Z")
        #expect(KeyBindingConflicts.find(in: ActionCatalog.all).isEmpty, "free: `G Z` is a sequence on `g`")
    }

    @Test func theShortcutSheetSaysWhereEachKeyWorks() throws {
        let sheet = ShortcutSheet(descriptors: ActionCatalog.all)
        let lines = Dictionary(uniqueKeysWithValues: sheet.sections.flatMap(\.lines).map { ($0.action, $0) })
        #expect(lines[.reply]?.places == ["List and conversation", "Conversation"], "R both; ↵ replies in a conversation")
        #expect(lines[.openThread]?.place == "List")
        #expect(lines[.backToList]?.place == "Conversation")
        #expect(lines[.clearChecks]?.place == "List")
        #expect(lines[.nextMessage]?.place == "Conversation")
        #expect(lines[.send]?.place == "Composer")
        #expect(lines[.reviewNext]?.place == "Review queue")
        #expect(lines[.commandPalette]?.place == "Everywhere")
        #expect(lines[.undo]?.places == ["Everywhere", "List and conversation"])
        let composer = sheet.filtered("composer").flatMap(\.lines)
        #expect(!composer.isEmpty && composer.allSatisfy { $0.places.contains("Composer") })
        #expect(sheet.filtered("e").flatMap(\.lines).contains { $0.action == .markDone }, "a single key still finds its line")
    }
}
