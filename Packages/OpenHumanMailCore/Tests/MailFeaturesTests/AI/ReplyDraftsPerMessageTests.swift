import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct ReplyDraftsPerMessageTests {
    static func conversation(_ f: AIFixture) async throws
        -> (thread: ThreadKey, older: MessageKey, newest: MessageKey, afterOlder: [String]) {
        let rows = try await f.store.threadPage(.system(.inbox), account: AIFixture.work, after: nil, limit: 1_000).rows
        let me = try #require(f.router.accounts.first { $0.id == AIFixture.work }?.account)
        func plain(_ message: MessageSummary) async -> Bool {
            guard !me.isMe(message.from?.email ?? ""), !message.hasCalendarInvite else { return false }
            return ((try? await f.store.unsubscribeInfo(message.id)) ?? nil) == nil
        }
        for row in rows {
            guard let detail = await AIThreadLoader.first(f.store.threadDetail(row.id)) ?? nil, detail.messages.count >= 3,
                  let newest = detail.messages.last else { continue }
            guard await plain(newest) else { continue }
            for older in detail.messages.dropLast().reversed() {
                guard await plain(older) else { continue }
                let after = detail.messages.drop(while: { $0.id != older.id }).dropFirst()
                    .map { AIThreadLoader.messageKey($0.id) }
                return (row.id, older.id, newest.id, after)
            }
        }
        Issue.record("no conversation with an older message from someone else in the fake inbox")
        throw CancellationError()
    }

    static func replyRequests(_ provider: ScriptedProvider) -> [AIRequest] {
        provider.requests.filter { $0.task == .replyOptions }
    }

    static func answered(_ request: AIRequest?) -> String? {
        request?.untrusted.last { $0.kind == .emailBody }?.id
    }

    @Test func eachMessageGetsItsOwnDraftsFromTheMessagesUpToIt() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AISettings(draftReplies: .onDemand), providers: [provider])
        await f.loaded()
        let (thread, older, newest, afterOlder) = try await Self.conversation(f)
        let latest = f.center.quickReplies(for: thread, replyingTo: newest)
        let earlier = f.center.quickReplies(for: thread, replyingTo: older)
        #expect(latest !== earlier && latest.target == newest && earlier.target == older, "one model per message")
        #expect(f.center.quickReplies(for: thread, replyingTo: older) === earlier)

        latest.request(trigger: .user)
        await eventually { latest.phase == .ready }
        let before = provider.requests.count
        earlier.request(trigger: .user)
        await eventually { earlier.phase == .ready }
        let asked = Self.replyRequests(provider)
        #expect(asked.count == 2)
        #expect(Self.answered(asked.first) == AIThreadLoader.messageKey(newest))
        #expect(Self.answered(asked.last) == AIThreadLoader.messageKey(older))
        #expect(!afterOlder.isEmpty)
        for request in provider.requests[before...] {
            let ids = Set(request.untrusted.map(\.id))
            #expect(afterOlder.allSatisfy { !ids.contains($0) }, "never a message after the one answered")
            #expect(RequestInspector.problems(in: request).isEmpty, "email text only inside the delimiters")
        }
        #expect(f.recorder.calls.isEmpty, "nothing is written or sent")
    }

    @Test func movingTheCursorUpAndDownFindsEachMessagesDraftsAgain() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AISettings(draftReplies: .onDemand), providers: [provider])
        await f.loaded()
        let (thread, older, newest, _) = try await Self.conversation(f)
        f.router.open(thread)
        await eventually { f.router.reader?.thread == thread && f.router.reader?.state == .loaded }
        let reader = try #require(f.router.reader)

        let latest = f.center.quickReplies(for: thread)
        #expect(latest.target == newest)
        latest.request(trigger: .user)
        await eventually { latest.phase == .ready }

        reader.focus(older)
        let earlier = f.center.quickReplies(for: thread)
        #expect(earlier !== latest && earlier.target == older)
        earlier.request(trigger: .user)
        await eventually { earlier.phase == .ready }
        #expect(Self.replyRequests(provider).count == 2)

        let shown = earlier.options
        reader.focus(newest)
        #expect(f.center.quickReplies(for: thread) === latest && latest.phase == .ready)
        latest.request(trigger: .user)
        reader.focus(older)
        #expect(f.center.quickReplies(for: thread) === earlier && earlier.options == shown)
        earlier.request(trigger: .user)
        #expect(Self.replyRequests(provider).count == 2)

        earlier.retry()
        await eventually { earlier.phase == .ready }
        #expect(earlier.fromCache && earlier.options == shown && Self.replyRequests(provider).count == 2)
    }

    @Test func aNewMessageGetsAFreshDraftAndLeavesTheOlderOnes() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AISettings(draftReplies: .onDemand), providers: [provider])
        await f.loaded()
        let (thread, _, newest, _) = try await Self.conversation(f)
        f.router.open(thread)
        await eventually { f.router.reader?.thread == thread && f.router.reader?.state == .loaded }
        let before = f.center.quickReplies(for: thread)
        #expect(before.target == newest)
        before.request(trigger: .user)
        await eventually { before.phase == .ready }
        let options = before.options

        let arrived = f.store.deliverMessage(account: AIFixture.work, to: thread,
                                             from: EmailAddress(name: "Sam Ortiz", email: "sam@example.com"),
                                             text: "Friday works for me. Can you send the agenda?", at: fixedNow + 60)
        await eventually { f.router.reader?.replyTarget == arrived }
        let after = f.center.quickReplies(for: thread)
        #expect(after !== before && after.target == arrived && after.phase == .idle)
        after.request(trigger: .user)
        await eventually { after.phase == .ready }
        #expect(Self.replyRequests(provider).count == 2)
        #expect(Self.answered(Self.replyRequests(provider).last) == AIThreadLoader.messageKey(arrived))

        #expect(before.phase == .ready && before.options == options)
        f.center.quickReplies(for: thread, replyingTo: newest).request(trigger: .user)
        #expect(Self.replyRequests(provider).count == 2)
        let kept = await f.center.context(for: thread, upTo: newest, trigger: .user)
        #expect(kept?.messageKeys.last == newest && kept?.isNewest == false, "its text still ends at that message")
        #expect(f.center.loadedContext(thread)?.messageKeys.last == arrived)
    }

    @Test func anEditedReplyIsNeverOverwrittenAndOtherDraftsAreNotListedOverTypedText() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AISettings(draftReplies: .onDemand), providers: [provider])
        await f.loaded()
        let (thread, older, newest, _) = try await Self.conversation(f)
        let (session, editor) = try await f.reply(thread)
        #expect(session.replyTo == newest)
        editor.type("My own words. ")
        let asked = provider.requests.count

        #expect(f.compose.openReply(thread, mode: .reply, message: older) === session)
        #expect(session.isOpen && editor.text == "My own words. " && session.replyTo == newest)
        #expect(session.offeredReplyTarget == older)
        #expect(session.notice?.kind == .info && session.notice?.text.contains("⌘J") == true)
        #expect(provider.requests.count == asked, "nothing is generated on its own")

        let panel = try #require(f.center.togglePanel(session))
        #expect(panel.quickReplies == nil && panel.scope == .wholeDraft)
        #expect(editor.text == "My own words. ")
        #expect(provider.requests.count == asked)

        _ = f.compose.openReply(thread, mode: .reply, message: newest)
        #expect(session.offeredReplyTarget == nil && editor.text.hasPrefix("My own words. "))
    }

    @Test func aReplyToAnOlderMessageShowsThatMessagesOwnQuickRepliesRow() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: .stripOn, providers: [provider])
        f.holdStripClock()
        await f.loaded()
        let (thread, older, newest, afterOlder) = try await Self.conversation(f)
        let latest = await f.openConversation(thread)
        #expect(latest.target == newest && latest.phase == .ready)

        let session = try #require(f.compose.openReply(thread, mode: .reply, message: older))
        await session.settle()
        _ = FakeEditor(session: session, text: "", selection: 0..<0)
        f.compose.attachInstantReply(session)
        await eventually { session.instantReply != nil }
        let strip = try #require(session.instantReply)
        #expect(strip.replies.target == older && strip.replies !== latest)
        await eventually { strip.phase == .ready }
        let asked = Self.replyRequests(provider)
        #expect(asked.count == 2)
        let ids = Set(asked.last?.untrusted.map(\.id) ?? [])
        #expect(Self.answered(asked.last) == AIThreadLoader.messageKey(older))
        #expect(afterOlder.allSatisfy { !ids.contains($0) }, "never a message after the one answered")
        #expect(latest.phase == .ready, "the newest message keeps its own row")
    }
}
