import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct ComposeReplyTargetTests {
    static func conversation(_ f: ComposeFixture) async throws -> (ThreadKey, [MessageSummary]) {
        let account = try #require(f.router.accounts.first { $0.id == ComposeFixture.work }?.account)
        let rows = try await f.store.threadPage(.system(.allMail), account: ComposeFixture.work, after: nil, limit: 1_000).rows
        for row in rows {
            var messages: [MessageSummary] = []
            for try await detail in f.store.threadDetail(row.id) {
                messages = detail?.messages ?? []
                break
            }
            guard messages.count >= 3, let middle = messages[messages.count - 2].from?.email,
                  !account.isMe(middle), middle != messages.last?.from?.email else { continue }
            return (row.id, messages)
        }
        throw TestFailure.noConversation
    }

    enum TestFailure: Error { case noConversation }

    @Test func rAnswersTheFocusedMessageElseTheNewest() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (thread, messages) = try await Self.conversation(f)
        let middle = messages[messages.count - 2]
        f.router.open(thread)
        await soon { f.router.reader?.state == .loaded }
        let reader = try #require(f.router.reader)
        #expect(reader.replyTarget == messages.last?.id, "until the user moves the focus: the newest")
        #expect(f.router.actionContext().focusedMessage == messages.last?.id)

        reader.focus(middle.id)
        #expect(reader.replyTarget == middle.id && f.router.actionContext().focusedMessage == middle.id)
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        #expect(session.replyTo == middle.id && session.replyToGmailMessageID == middle.id.gmailMessageID)
        #expect(session.to.tokens.map(\.email) == [try #require(middle.from?.email)], "the focused message's sender")
        let key = try #require(session.draftKey)
        let row = try #require(await f.draftRow(key))
        #expect(row.replyToGmailMessageID == middle.id.gmailMessageID, "the draft answers that message")
        let quote = QuotePreview(quotedText: session.quotedText, quotedHTML: session.quotedHTML)
        #expect(quote.header.contains(try #require(middle.from?.email)) && quote.header.hasSuffix("wrote:"))
        #expect(QuoteSplit.quoteBlockCount(session.assembledFields().bodyHTML) == 1)

        f.compose.dockedComposerHasFocus = { _ in false }
        session.focusHandled = session.focusRequest
        #expect(await f.run(.replyAll))
        let all = try #require(f.compose.windowSession)
        await all.settle()
        #expect(all !== session && all.mode == .replyAll && all.replyTo == middle.id)
        #expect(f.compose.sessions.count == 1)
        await f.compose.settle()
        #expect(f.recorder.calls.contains("discardDraft"))

        all.updateBody(doc("Typed"))
        all.focusHandled = all.focusRequest
        reader.focus(try #require(messages.last?.id))
        #expect(await f.run(.reply))
        #expect(f.compose.windowSession === all && all.plainText == "Typed")
    }

    @Test func withoutAWritePortAReplyPrefillsFromTheSkeletonAndWritesNothing() async throws {
        let f = ComposeFixture(writePort: false)
        await f.loaded()
        let (thread, messages) = try await Self.conversation(f)
        let account = try #require(f.router.accounts.first { $0.id == ComposeFixture.work }?.account)
        let last = try #require(messages.last)

        let reply = try #require(f.compose.openReply(thread, mode: .reply))
        await reply.settle()
        #expect(reply.draftKey == nil && !reply.canPersist)
        let sender = try #require(last.from)
        let expectedTo = account.isMe(sender.email) ? last.to.map { $0.email.lowercased() } : [sender.email.lowercased()]
        #expect(reply.to.tokens.map { $0.email.lowercased() } == expectedTo, "To is prefilled")
        #expect(reply.subject.hasPrefix("Re: ") && reply.notice == nil)
        #expect(QuoteSplit.quoteBlockCount(reply.quotedHTML) == 1)
        #expect(QuoteSplit.quoteBlockCount(reply.assembledFields().bodyHTML) == 1, "the quote, once, in what would be sent")
        #expect(QuotePreview(quotedText: reply.quotedText, quotedHTML: reply.quotedHTML).header.hasPrefix("On "))
        #expect(!reply.hasUserEdits, "a prefill is not an edit")
        f.compose.close(reply)

        let all = try #require(f.compose.openReply(thread, mode: .replyAll))
        await all.settle()
        let everyone = (all.to.tokens + all.cc.tokens).map(\.email)
        #expect(!everyone.isEmpty && !everyone.contains { account.isMe($0) })
        f.compose.close(all)
        await f.compose.settle()
        #expect(f.recorder.calls.isEmpty, "nothing created, saved or sent: \(f.recorder.calls)")
        #expect(f.store.pendingOperationCount == 0 && f.store.heldSendCount == 0)
    }

    @Test func aDockedComposerHasTheKeysOnlyWhileShownAndFocused() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (thread, _) = try await Self.conversation(f)
        let session = try #require(f.compose.openReply(thread, mode: .reply))
        await session.settle()
        #expect(f.compose.isShown(session) && f.compose.keySession === session)
        #expect(f.router.actionContext().scope == .composer)
        var focused = false
        f.compose.dockedComposerHasFocus = { _ in focused }
        #expect(f.compose.keySession === session, "still taking the focus it was opened with")
        session.focusHandled = session.focusRequest
        #expect(f.compose.keySession == nil && f.router.actionContext().scope == .reader)
        focused = true
        #expect(f.router.actionContext().scope == .composer)
        focused = false
        #expect(await f.run(.backToList))
        #expect(!f.compose.isShown(session) && f.compose.keySession == nil && f.router.actionContext().scope == .list)
        #expect(session.isOpen && f.compose.dockedSession(for: thread) === session)
        let request = session.focusRequest
        f.router.open(thread)
        #expect(f.compose.openReply(thread, mode: .reply) === session && session.focusRequest == request + 1)
    }

    @Test func theFakeSkeletonIsWhatADraftWouldStart() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (_, messages) = try await Self.conversation(f)
        let middle = messages[messages.count - 2]
        let input = DraftInput(account: ComposeFixture.work, mode: .reply, replyTo: middle.id)
        let fields = try #require(try await f.store.draftSkeleton(input))
        #expect(fields.to.map(\.email) == [try #require(middle.from?.email)] && fields.subject.hasPrefix("Re: "))
        #expect(try await f.store.draftSkeleton(DraftInput(account: ComposeFixture.work, mode: .new)) == nil)
        #expect(f.store.pendingOperationCount == 0)
    }

    @Test func theQuoteReadsAsAnAttributionAndText() {
        let reply = QuotePreview(quotedText: "On Oct 7, 2026, Dana <dana@acme.example> wrote:\n> Hi there\n>\n> Thanks", quotedHTML: "")
        #expect(reply == QuotePreview(header: "On Oct 7, 2026, Dana <dana@acme.example> wrote:", body: "Hi there\n\nThanks"))
        let forward = QuotePreview(quotedText: "---------- Forwarded message ---------\nFrom: Dana\nSubject: Plan\n\nBody line",
                                   quotedHTML: "")
        #expect(forward.header == "---------- Forwarded message ---------\nFrom: Dana\nSubject: Plan" && forward.body == "Body line")
        let htmlOnly = QuotePreview(quotedText: "", quotedHTML: """
        <div class="gmail_quote" data-oh-quote="1"><div class="gmail_attr">On Tue, Sam &lt;sam@x.example&gt; wrote:<br></div><blockquote>x</blockquote></div>
        """)
        #expect(htmlOnly == QuotePreview(header: "On Tue, Sam <sam@x.example> wrote:", body: ""))
    }
}
