import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct AIInlineTests {
    static let drafts = AISettings(draftReplies: .onDeviceAuto)

    @Test func theNeedsReplyMatrix() {
        let person = NeedsReply.Facts(lastIsFromMe: false, sender: "dana@example.org")
        #expect(NeedsReply.skipReason(person) == nil, "a person's message needs a reply")
        var mine = person
        mine.lastIsFromMe = true
        #expect(NeedsReply.skipReason(mine) == .youWroteLast, "the user wrote last (or a send-as address did)")
        for address in ["noreply@example.org", "no-reply@example.org", "do_not_reply@example.org",
                        "Notifications@example.org", "mailer-daemon@example.org", "noreply-billing@example.org"] {
            var facts = person
            facts.sender = address
            #expect(NeedsReply.skipReason(facts) == .noReplySender, "\(address)")
        }
        for address in ["reply@example.org", "dana.ruiz@example.org", "robin@noreply-like.example.org"] {
            #expect(!NeedsReply.isNoReply(address), "\(address) is a person")
        }
        var list = person
        list.exclusion.newestHasListUnsubscribe = true
        #expect(NeedsReply.skipReason(list) == .newsletter)
        var updates = person
        updates.exclusion.categories = [GmailLabelID("CATEGORY_UPDATES")]
        #expect(NeedsReply.skipReason(updates) == .automated)
        var promotions = person
        promotions.exclusion.categories = [GmailLabelID("CATEGORY_PROMOTIONS")]
        #expect(NeedsReply.skipReason(promotions) == .excluded)
        var spam = person
        spam.exclusion.inSpamOrTrash = true
        #expect(NeedsReply.skipReason(spam) == .excluded)
        var invite = person
        invite.exclusion.newestHasCalendarInvite = true
        #expect(NeedsReply.skipReason(invite) == .excluded)
        let byClass: [(TriageCategory, NeedsReplySkip?)] = [
            (.newsletter, .newsletter), (.notification, .automated), (.receipt, .automated), (.needsReply, nil),
            (.fyi, nil), (.personal, nil), (.calendar, nil), (.other, nil),
        ]
        for (category, expected) in byClass {
            var facts = person
            facts.triage = category
            #expect(NeedsReply.skipReason(facts) == expected, "\(category)")
        }
        var unknown = person
        unknown.sender = nil
        #expect(NeedsReply.skipReason(unknown) == nil, "an unknown fact excludes nothing")
    }

    @Test func theRowShowsWithNoClickAndPreviewsTheBestReply() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: Self.drafts, providers: [provider])
        await f.loaded()
        let (thread, newest) = try await f.needsReplyThread()
        #expect(!f.center.settings.instantReplyStrip, "no setting to turn on: the strip switch stays off")
        f.center.conversationAppeared(thread, messageCount: 3)
        let row = f.center.inlineReplies.row(for: thread, message: newest)
        row.appear()
        await eventually { row.state == .ready || row.state == .none }
        #expect(row.state == .ready && row.decision == .needsReply)
        #expect(row.options.count == 3 && row.selection == 0)
        #expect(row.preview?.body == InstantReplyTests.first, "the best (first) reply is previewed")
        #expect(provider.requests.filter { $0.task == .replyOptions }.count == 1, "the conversation's own request")
        #expect(f.recorder.calls.isEmpty, "nothing written, saved or sent")
    }

    @Test func whileTheModelWorksTheRowSaysWritingAndAFailureShowsNothing() async throws {
        let held = ScriptedProvider { request, _ in
            request.task == .replyOptions ? .hang : FakeAIProvider.cannedScript(request)
        }
        let f = AIFixture(settings: Self.drafts, providers: [held])
        await f.loaded()
        let (thread, newest) = try await f.needsReplyThread()
        let row = f.center.inlineReplies.row(for: thread, message: newest)
        row.appear()
        await eventually { row.state == .writing }
        #expect(row.state == .writing && row.preview == nil && row.accessibilityLabel.contains("Writing"))

        let failing = ScriptedProvider { request, _ in
            request.task == .replyOptions ? .fail(.providerFailed("x")) : FakeAIProvider.cannedScript(request)
        }
        let g = AIFixture(settings: Self.drafts, providers: [failing])
        await g.loaded()
        let (other, otherNewest) = try await g.needsReplyThread()
        let quiet = g.center.inlineReplies.row(for: other, message: otherNewest)
        quiet.appear()
        await eventually { failing.requests.contains { $0.task == .replyOptions } && quiet.state == .none }
        #expect(quiet.state == .none, "no error chrome: the row is simply not there")
    }

    @Test func noModelOnThisMacOrOnlyWhenIAskShowsNothing() async throws {
        let away = ScriptedProvider(availability: .unavailable(reason: .other("No model")))
        let f = AIFixture(settings: Self.drafts, providers: [away])
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 2)
        let detail = try #require(await AIThreadLoader.first(f.store.threadDetail(thread)) ?? nil)
        let row = f.center.inlineReplies.row(for: thread, message: try #require(detail.messages.last?.id))
        await row.evaluate()
        #expect(row.decision == .notOffered && row.state == .none && away.requests.isEmpty)

        let asked = ScriptedProvider()
        let g = AIFixture(settings: AISettings(draftReplies: .onDemand), providers: [asked])
        await g.loaded()
        let (other, newest) = try await g.needsReplyThread()
        let onDemand = g.center.inlineReplies.row(for: other, message: newest)
        await onDemand.evaluate()
        #expect(onDemand.state == .none && !asked.requests.contains { $0.task == .replyOptions },
                "Only when I ask: nothing runs on its own")
    }

    @Test func aConversationTheUserAnsweredLastGetsNoRow() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: Self.drafts, providers: [provider])
        await f.loaded()
        let thread = try await f.thread(lastFromMe: true)
        let detail = try #require(await AIThreadLoader.first(f.store.threadDetail(thread)) ?? nil)
        let row = f.center.inlineReplies.row(for: thread, message: try #require(detail.messages.last?.id))
        await row.evaluate()
        #expect(row.decision == .skipped(.youWroteLast) && row.state == .none)
        #expect(!provider.requests.contains { $0.task == .replyOptions }, "the model is not asked")
    }

    @Test func swapDismissAndAcceptAnAutoDraftThatIsNeverSent() async throws {
        let f = AIFixture(settings: Self.drafts)
        await f.loaded()
        let row = try await f.readyInlineRow()
        row.next()
        #expect(row.selection == 1 && row.preview?.body == InstantReplyTests.second && row.isEngaged)
        row.previous()
        row.previous()
        #expect(row.selection == 2, "wraps")
        row.select(0)
        #expect(row.selection == 0)
        let session = try #require(await row.accept())
        #expect(session.plainText.trimmingCharacters(in: .whitespacesAndNewlines) == InstantReplyTests.first)
        #expect(session.isAutoDraft && session.mode == .reply && session.replyTo == row.message)
        #expect(row.state == .ready && row.isAccepted && row.usedID == row.items.first?.id)
        #expect(!f.recorder.calls.contains { $0.hasPrefix("send") || $0 == "scheduleSend" }, "never sent")

        let g = AIFixture(settings: Self.drafts)
        await g.loaded()
        let other = try await g.readyInlineRow()
        #expect(!other.dismissIfEngaged(), "untouched: Esc keeps going back to the list")
        other.next()
        #expect(other.dismissIfEngaged() && other.state == .none && other.isDismissed)
    }

    @Test func acceptPutsTheReplyInThroughTheEditorAsOneEdit() async throws {
        let f = AIFixture(settings: Self.drafts)
        await f.loaded()
        let row = try await f.readyInlineRow()
        let (session, editor) = try await f.reply(row.thread)
        let again = try #require(await row.accept())
        let first = InstantReplyTests.first
        #expect(again === session)
        #expect(editor.text == first && session.plainText == first, "exactly the suggestion")
        #expect(editor.replacements.count == 1 && editor.replacements.first?.range == 0..<0, "one edit (one ⌘Z)")
        #expect(editor.caretPlacements.last == (first as NSString).length && editor.focusCount > 0, "caret at the end")
        #expect(session.isAutoDraft && session.notice == nil && session.pendingReply == nil && row.isAccepted)
    }

    @Test func aReplyWithTheUsersOwnTextGetsNoSuggestion() async throws {
        let f = AIFixture(settings: Self.drafts)
        await f.loaded()
        let row = try await f.readyInlineRow()
        let (session, editor) = try await f.reply(row.thread)
        editor.type("Hi Dana, ")
        editor.selection = 3..<7
        #expect(row.state == .none, "the strip steps aside: only ⌘J's edit tools now")
        #expect(await row.accept() == nil)
        #expect(editor.text == "Hi Dana, " && editor.replacements.count == 1, "nothing goes in")
        #expect(!session.isAutoDraft && !row.isAccepted)
        _ = editor.replaceText(in: 0..<(editor.text as NSString).length, with: "")
        #expect(row.state == .ready)
    }

    @Test func acceptWhileTheReplyIsStillBeingPrepared() async throws {
        let f = AIFixture(settings: Self.drafts)
        await f.loaded()
        let row = try await f.readyInlineRow()
        f.appSettings.hold()
        let accepting = Task { await row.accept() }
        await eventually { f.compose.sessions.contains { $0.thread == row.thread } }
        let session = try #require(f.compose.sessions.first { $0.thread == row.thread })
        #expect(row.isAccepted, "marked at once: a second ⇥ is not a second accept (the row stays, one suggestion set)")
        let editor = FakeEditor(session: session, text: "", selection: 0..<0)
        editor.type("\t")
        f.appSettings.release()
        let accepted = try #require(await accepting.value)
        let first = InstantReplyTests.first
        #expect(accepted === session)
        #expect(editor.text == first && session.plainText == first, "the suggestion over the white space")
        #expect(session.isAutoDraft && session.notice == nil)
    }

    @Test func acceptBeforeTheEditorIsOnScreenLeavesTheEditOfTheReplyToTheEditor() async throws {
        let f = AIFixture(settings: Self.drafts)
        await f.loaded()
        let row = try await f.readyInlineRow()
        let session = try #require(await row.accept())
        let first = InstantReplyTests.first
        #expect(session.plainText == first, "the draft holds it (saved like typing)")
        let pending = try #require(session.pendingReply)
        #expect(pending.insertion == first && pending.replacesAll && pending.revision == session.documentRevision)
        #expect(pending.base == RichTextDocument(), "the editor shows the body without it, then makes the edit (one ⌘Z)")
        session.pendingReplyApplied(pending)
        #expect(session.pendingReply == nil)
    }

    @Test func acceptAfterMovingBetweenMessagesWithTheArrowKeys() async throws {
        let f = AIFixture(settings: Self.drafts)
        await f.loaded()
        let (thread, _, _) = try await f.twoAnswerableMessages()
        f.router.open(thread)
        await eventually { f.router.reader?.state == .loaded && (f.router.reader?.messages.count ?? 0) >= 2 }
        let newest = try #require(f.router.reader?.messages.last?.id)
        let row = f.center.inlineReplies.row(for: thread, message: newest)
        row.appear()
        await eventually { row.state == .ready || row.state == .none }
        try #require(row.state == .ready)
        #expect(await f.run(.previousMessage))
        #expect(f.router.reader?.focusedMessage != newest, "↑ moved to an older message")
        #expect(await f.run(.nextMessage))
        #expect(await f.run(.previousMessage))
        #expect(await f.run(.aiUseInlineReply))
        let session = try #require(f.compose.sessions.first { $0.thread == thread && $0.mode == .reply })
        #expect(session.replyTo == newest, "the reply answers the message the suggestion was written for")
        #expect(session.plainText == InstantReplyTests.first && session.isAutoDraft)
    }

    @Test func tabUsesArrowsSwapAndEscDismissesOnlyOnceEngaged() async throws {
        let f = AIFixture(settings: Self.drafts)
        await f.loaded()
        let (thread, _) = try await f.needsReplyThread()
        #expect(f.env.actions.availability(.aiUseInlineReply, host: f.router) == .hidden, "no row: ⇥ passes through")
        f.router.open(thread)
        await eventually { f.router.reader?.state == .loaded && f.router.reader?.messages.isEmpty == false }
        let newest = try #require(f.router.reader?.messages.last?.id)
        let row = f.center.inlineReplies.row(for: thread, message: newest)
        row.appear()
        await eventually { row.state == .ready || row.state == .none }
        try #require(row.state == .ready)
        #expect(f.center.inlineReplies.current === row)
        #expect(f.env.actions.availability(.aiUseInlineReply, host: f.router) == .enabled)
        #expect(await f.run(.aiNextInlineReply) && row.selection == 1)
        #expect(await f.run(.aiPreviousInlineReply) && row.selection == 0)
        #expect(await f.run(.backToList) && f.router.mode == .reader && row.isDismissed, "engaged: Esc dismisses")
        #expect(f.env.actions.availability(.aiUseInlineReply, host: f.router) == .hidden)
        #expect(await f.run(.backToList) && f.router.mode == .list, "then Esc goes back as always")
    }

    @Test func tabPutsThePreviewInANewReply() async throws {
        let f = AIFixture(settings: Self.drafts)
        await f.loaded()
        let (thread, _) = try await f.needsReplyThread()
        f.router.open(thread)
        await eventually { f.router.reader?.state == .loaded && f.router.reader?.messages.isEmpty == false }
        let row = f.center.inlineReplies.row(for: thread, message: try #require(f.router.reader?.messages.last?.id))
        row.appear()
        await eventually { row.state == .ready || row.state == .none }
        try #require(row.state == .ready)
        #expect(await f.run(.aiUseInlineReply))
        let session = try #require(f.compose.sessions.first { $0.thread == thread && $0.mode == .reply })
        #expect(session.isAutoDraft && session.plainText.contains(InstantReplyTests.first))
        #expect(!f.recorder.calls.contains { $0.hasPrefix("send") || $0 == "scheduleSend" })
    }

    @Test func aNewNewestMessageGetsItsOwnRowAndLeavesTheOlderRepliesAlone() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: Self.drafts, providers: [provider])
        await f.loaded()
        let (thread, older, newer) = try await f.twoAnswerableMessages()
        let first = f.center.inlineReplies.row(for: thread, message: older)
        first.appear()
        await eventually { first.state == .ready || first.state == .none }
        try #require(first.state == .ready)
        let olderReplies = try #require(first.replies)
        let olderOptions = olderReplies.options
        let second = f.center.inlineReplies.row(for: thread, message: newer)
        #expect(first.state == .none, "the older message's row is retired")
        second.appear()
        await eventually { second.state == .ready || second.state == .none }
        #expect(second.state == .ready && second.replies !== olderReplies)
        #expect(olderReplies.phase == .ready && olderReplies.options == olderOptions,
                "the older message's replies are not invalidated")
        #expect(f.center.quickReplies(for: thread, replyingTo: older) === olderReplies)
        #expect(provider.requests.filter { $0.task == .replyOptions }.count == 2, "one request per message")
    }

    @Test func theAIViewsUseNoGradientNoAITintAndNoAccent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ai = root.appendingPathComponent("../OpenHumanMailUI/Sources/MailUI/AI")
        let files = ["AIComposerPanel.swift", "AIComposerParts.swift", "QuickReplyMessageRow.swift", "QuickRepliesList.swift",
                     "InstantReplyStrip.swift"]
        let forbidden = [#"Gradient\("#, #"LinearGradient"#, #"AngularGradient"#, #"RadialGradient"#, #"EllipticalGradient"#,
                         #"\btextAI\b"#, #"\baccentFill\b"#, #"\baccentText\b"#, #"\baccentSubtle\b"#, #"\baccentRing\b"#,
                         #"\bbgAISubtle\b"#, #"borderSelected"#, #"bgSelected"#, #"Color\.blue"#, #"\.blue\b"#,
                         #"accentColor"#, #"AIProgressLine"#, #"AISectionLabel"#]
        for name in files {
            let text = try String(contentsOf: ai.appendingPathComponent(name), encoding: .utf8)
            for pattern in forbidden {
                let regex = try NSRegularExpression(pattern: pattern)
                let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                #expect(!found, "\(name) uses \(pattern)")
            }
        }
    }
}

extension AIFixture {
    func needsReplyThread() async throws -> (ThreadKey, MessageKey) {
        let rows = try await store.threadPage(.system(.inbox), account: Self.work, after: nil, limit: 1_000).rows
        for row in rows {
            guard let context = await center.context(for: row.id, trigger: .automatic),
                  let newest = context.messageKeys.last else { continue }
            if NeedsReply.skipReason(center.needsReplyFacts(for: row.id, context: context)) == nil {
                return (row.id, newest)
            }
        }
        Issue.record("no conversation that needs a reply in the fake Inbox")
        throw CancellationError()
    }

    func twoAnswerableMessages() async throws -> (ThreadKey, MessageKey, MessageKey) {
        let rows = try await store.threadPage(.system(.inbox), account: Self.work, after: nil, limit: 1_000).rows
        for row in rows {
            guard let detail = await AIThreadLoader.first(store.threadDetail(row.id)) ?? nil,
                  detail.messages.count >= 2, let newer = detail.messages.last?.id,
                  let b = await center.context(for: row.id, upTo: newer, trigger: .automatic),
                  NeedsReply.skipReason(center.needsReplyFacts(for: row.id, context: b)) == nil else { continue }
            for message in detail.messages.dropLast().reversed() {
                guard let a = await center.context(for: row.id, upTo: message.id, trigger: .automatic),
                      NeedsReply.skipReason(center.needsReplyFacts(for: row.id, context: a)) == nil else { continue }
                return (row.id, message.id, newer)
            }
        }
        Issue.record("no conversation with two answerable messages in the fake Inbox")
        throw CancellationError()
    }

    func readyInlineRow() async throws -> InlineReplyRow {
        let (thread, newest) = try await needsReplyThread()
        let row = center.inlineReplies.row(for: thread, message: newest)
        row.appear()
        await eventually { row.state == .ready || row.state == .none }
        try #require(row.state == .ready)
        return row
    }
}
