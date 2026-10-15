import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct NewMessagesPillTests {
    typealias F = ReaderFixtures

    private func open(_ detail: ConversationDetail, myAddresses: Set<String> = []) async -> ReaderModel {
        let bodies = Dictionary(uniqueKeysWithValues: detail.messages.map { ($0.id, MessageContent(html: nil, text: "Body")) })
        let model = ReaderModel(thread: detail.id, data: ReaderTestSource(details: [detail], bodies: bodies),
                                renderQueue: RenderQueue(), myAddresses: myAddresses)
        model.start()
        await eventually { model.state == .loaded }
        return model
    }

    private func adding(_ extra: [MessageSummary], to detail: ConversationDetail) -> ConversationDetail {
        ConversationDetail(id: detail.id, subject: detail.subject, messages: detail.messages + extra)
    }

    private static let priya = EmailAddress(name: "Priya Natarajan", email: "priya@example.net")

    @Test func aConversationJustOpenedShowsArrivingMailAtOnce() async throws {
        let detail = F.conversation(40, count: 3, from: F.dana)
        let model = await open(detail)
        #expect(!model.hasInteracted && model.pendingMessages.isEmpty)
        let arrived = F.summary(4003, from: Self.priya, unread: true, minutesAgo: 1)
        model.apply(adding([arrived], to: detail))
        #expect(model.pendingMessages.isEmpty, "no pill: the user has not started reading")
        #expect(model.messages.last?.id == arrived.id && model.message(arrived.id)?.isExpanded == true)
        #expect(model.focusedMessage == arrived.id && model.replyTarget == arrived.id)
    }

    @Test func onceTheUserReadsArrivalsWaitBehindThePillUntilShown() async throws {
        let detail = F.conversation(41, count: 3, from: F.dana)
        let model = await open(detail)
        let keys = detail.messages.map(\.id)
        let items = model.items
        model.noteInteraction()
        let first = F.summary(4103, from: Self.priya, unread: true, minutesAgo: 3)
        model.apply(adding([first], to: detail))
        #expect(model.pendingMessages == [first.id])
        #expect(model.messages.map(\.id) == keys && model.items == items, "nothing joins the column")
        #expect(model.focusedMessage == keys[2] && model.replyTarget == keys[2] && model.focusScrollRequest == 0,
                "the focus (and so `r`) stays where it was")
        #expect(!model.messages.contains { $0.summary.isUnread }, "the waiting message counts as nothing the user saw")

        let second = F.summary(4104, from: F.dana, unread: true, minutesAgo: 2)
        let third = F.summary(4105, from: Self.priya, unread: true, minutesAgo: 1)
        model.apply(adding([first, second, third], to: detail))
        #expect(model.pendingMessages == [first.id, second.id, third.id])
        #expect(ReaderFormatting.newMessagesTitle(3) == "Show 3 new messages")
        #expect(ReaderFormatting.newMessagesTitle(1) == "Show new message")
        model.apply(adding([first, third], to: detail))
        #expect(model.pendingMessages == [first.id, third.id] && model.messages.map(\.id) == keys)

        model.showNewMessages()
        #expect(model.pendingMessages.isEmpty)
        #expect(model.messages.map(\.id) == keys + [first.id, third.id])
        #expect(model.message(first.id)?.isExpanded == true && model.message(third.id)?.isExpanded == true)
        #expect(model.message(keys[2])?.isExpanded == true, "no longer the newest, still open")
        #expect(model.focusedMessage == third.id && model.focusChosen && model.replyTarget == third.id)
        #expect(model.focusScrollRequest == 1, "the view scrolls the newest into view")

        let fourth = F.summary(4106, from: F.dana, unread: true, minutesAgo: 0)
        model.apply(adding([first, third, fourth], to: detail))
        #expect(model.pendingMessages == [fourth.id] && model.focusedMessage == third.id)
        model.showNewMessages()
        model.showNewMessages()
        #expect(model.focusedMessage == fourth.id && model.focusScrollRequest == 2)
    }

    @Test func movingClickingOrFoldingStartsReadingAKeyThatMovesNothingDoesNot() async throws {
        let detail = F.conversation(42, count: 3, from: F.dana)
        let actions: [(String, (ReaderModel, [MessageKey]) -> Void)] = [
            ("p / ↑", { model, _ in model.focusPrevious() }),
            ("a click", { model, keys in model.focus(keys[0]) }),
            ("⇧O", { model, _ in model.expandAll() }),
            (".", { model, _ in model.toggleQuotedText() }),
            ("o", { model, _ in model.toggleFocused() }),
        ]
        for (name, act) in actions {
            let model = await open(detail)
            let keys = detail.messages.map(\.id)
            #expect(!model.focusNext(), "↓ at the newest moves nothing (the view's scroll counts instead)")
            #expect(!model.hasInteracted, "\(name): a key that moved nothing")
            act(model, keys)
            #expect(model.hasInteracted, "\(name)")
            let focused = model.focusedMessage
            let arrived = F.summary(4203, from: Self.priya, unread: true, minutesAgo: 1)
            model.apply(adding([arrived], to: detail))
            #expect(model.pendingMessages == [arrived.id] && model.focusedMessage == focused, "\(name): it waits")
        }
    }

    @Test func theUsersOwnMessagesNeverWait() async throws {
        let detail = F.conversation(43, count: 3, from: F.dana)
        let model = await open(detail, myAddresses: ["Sam.Lee@Gmail.com"])
        let keys = detail.messages.map(\.id)
        model.noteInteraction()
        let theirs = F.summary(4303, from: Self.priya, unread: true, minutesAgo: 5)
        let mine = F.summary(4304, from: F.gmailUser, minutesAgo: 1)
        model.apply(adding([theirs, mine], to: detail))
        #expect(model.pendingMessages == [theirs.id])
        #expect(model.messages.map(\.id) == keys + [mine.id], "the user's own message is shown at once")
        #expect(model.message(keys[2])?.isExpanded == true, "and collapses nothing")
        model.showNewMessages()
        #expect(model.messages.map(\.id) == keys + [theirs.id, mine.id], "date order")
        #expect(model.focusedMessage == theirs.id, "the newest of the pill's messages")
    }

    @Test func theKeyAndMarkReadShowWaitingMessagesFirst() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (thread, _) = try await ComposeReplyTargetTests.conversation(f)
        f.router.open(thread)
        await soon { f.router.reader?.state == .loaded }
        let reader = try #require(f.router.reader)
        let registry = f.env.actions
        #expect(registry.descriptor(.showNewMessages)?.shortcutHint == "⇧N")
        #expect(registry.availability(.showNewMessages, host: f.router) == .disabled(.other("No new messages")))
        await untilObserved { reader.messages.allSatisfy { !$0.summary.isUnread } }
        reader.noteInteraction()
        let dana = EmailAddress(name: "Dana Ruiz", email: "dana@example.com")
        let first = f.store.deliverMessage(account: ComposeFixture.work, to: thread, from: dana, at: fixedNow + 60)
        await soon { reader.pendingMessages == [first] }
        let toggle = try #require(registry.descriptor(.toggleRead))
        #expect(!f.router.actionContext().targets.anyUnread, "the list row is unread; the conversation shows none")
        #expect(ActionRules.title(for: toggle, in: f.router.actionContext()) == "Mark unread")
        #expect(await f.compose.knownMessages(in: thread).contains(first), "a reply sent now: not Gmail's copy")
        #expect(try await isUnread(first, in: thread, f), "nothing marked it read")

        #expect(registry.availability(.showNewMessages, host: f.router) == .enabled)
        #expect(await f.run(.showNewMessages))
        #expect(reader.pendingMessages.isEmpty && reader.focusedMessage == first && reader.messages.last?.id == first)
        #expect(reader.focusScrollRequest == 1)
        await untilObserved { reader.message(first)?.summary.isUnread == false }
        try #require(try await isUnread(first, in: thread, f) == false, "shown from the pill, so read")

        #expect(await f.run(.toggleRead))
        await untilObserved { f.router.actionContext().targets.anyUnread }
        let second = f.store.deliverMessage(account: ComposeFixture.work, to: thread, from: dana, at: fixedNow + 120)
        await soon { reader.pendingMessages == [second] }
        #expect(f.router.actionContext().targets.anyUnread)
        #expect(await f.run(.toggleRead))
        #expect(reader.pendingMessages.isEmpty && reader.messages.last?.id == second && reader.focusedMessage == second)
        await soon { reader.messages.allSatisfy { !$0.summary.isUnread } }
        #expect(f.recorder.calls.contains("apply"))
    }

    private func isUnread(_ key: MessageKey, in thread: ThreadKey, _ f: ComposeFixture) async throws -> Bool {
        for try await detail in f.store.threadDetail(thread) {
            return detail?.messages.first { $0.id == key }?.isUnread == true
        }
        return false
    }
}
