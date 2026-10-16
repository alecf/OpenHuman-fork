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
@Suite(.serialized) struct InstantReplyTests {
    static let first = "Sounds good, thanks."
    static let second = "Thanks, but I can't make it."
    static let third = "Could you share a few more details first?"

    @Test func theStripIsOffByDefault() async throws {
        #expect(!AISettings().instantReplyStrip)
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AISettings(draftReplies: .onDeviceAuto), providers: [provider])
        f.holdStripClock()
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        _ = await f.openConversation(thread)
        let (session, _, strip) = try await f.stripReply(thread)
        #expect(strip == nil && session.instantReply == nil)
        #expect(provider.requests.filter { $0.task == .replyOptions }.count == 1, "only the conversation's own request")

        let asked = ScriptedProvider()
        let g = AIFixture(settings: AISettings(draftReplies: .onDemand, instantReplyStrip: true), providers: [asked])
        g.holdStripClock()
        await g.loaded()
        let other = try await g.thread(minimumMessages: 3)
        let (_, _, none) = try await g.stripReply(other)
        #expect(none == nil)
        #expect(!asked.requests.contains { $0.task == .replyOptions })
    }

    @Test func aReplyToTheNewestMessageShowsThreeOptionsFromTheConversationRequest() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: .stripOn, providers: [provider])
        f.holdStripClock()
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        let replies = await f.openConversation(thread)
        #expect(replies.phase == .ready)
        #expect(provider.requests.filter { $0.task == .replyOptions }.count == 1)

        let (session, editor, strip) = try await f.stripReply(thread)
        let model = try #require(strip, "options ready: the row is there when the composer opens")
        #expect(model.phase == .ready && model.showsRow && model.isLive)
        #expect(model.options.map(\.label) == ["Sounds good", "Not this time", "Ask for details"])
        #expect(model.badge?.title == "On this Mac" && model.badge?.leavesMac == false)
        #expect(model.accessibilityLabel == "Quick replies, 3 suggestions, made on this Mac")
        #expect(model.accessibilityPlaceholder == "Quick replies available. Tab previews, Return uses.")
        #expect(editor.text.isEmpty && session.plainText.isEmpty, "nothing is in the draft")
        #expect(provider.requests.filter { $0.task == .replyOptions }.count == 1, "no second request")
        f.compose.attachInstantReply(session)
        #expect(session.instantReply === model, "attaching again changes nothing")
        #expect(f.compose.instantReply(for: session) === model)
    }

    static let newest = MessageKey(account: AccountID(1), rowID: 9, gmailMessageID: GmailMessageID("m9"))
    static let older = MessageKey(account: AccountID(1), rowID: 3, gmailMessageID: GmailMessageID("m3"))

    static func decide(_ settings: AISettings = .stripOn, moduleOn: Bool = true, mode: DraftMode = .reply,
                       source: DraftSource = .user, empty: Bool = true, replyTo: MessageKey? = nil,
                       newest: MessageKey? = InstantReplyTests.newest, mine: Bool? = false, hidden: Bool = false,
                       phase: QuickRepliesModel.Phase = .ready,
                       excluded: QuickReplyExclusion? = nil) -> InstantReplyEligibility {
        InstantReplyEligibility.evaluate(settings: settings, moduleOn: moduleOn, mode: mode, source: source,
                                         bodyIsEmpty: empty, replyTo: replyTo, answered: newest, answeredIsMine: mine,
                                         hidden: hidden, threadPhase: phase, excluded: excluded)
    }

    @Test func eligibilityIsAPureFunction() {
        #expect(Self.decide() == .eligible)
        #expect(Self.decide(replyTo: Self.newest) == .eligible)
        #expect(Self.decide(replyTo: Self.older, newest: Self.older) == .eligible)
        #expect(Self.decide(replyTo: Self.older) == .ineligible(.decidedTooLate))
        #expect(Self.decide(mode: .replyAll, phase: .loading) == .eligible)
        #expect(Self.decide(phase: .idle) == .eligible)

        #expect(Self.decide(moduleOn: false) == .ineligible(.moduleOff))
        var aiOff = AISettings.stripOn
        aiOff.enabled = false
        #expect(Self.decide(aiOff) == .ineligible(.aiOff))
        #expect(Self.decide(AISettings(draftReplies: .onDeviceAuto)) == .ineligible(.stripOff))
        #expect(Self.decide(AISettings(draftReplies: .onDemand, instantReplyStrip: true))
            == .ineligible(.draftRepliesNotOnDeviceAuto))
        #expect(Self.decide(AISettings(draftReplies: .off, instantReplyStrip: true)) == .ineligible(.draftRepliesNotOnDeviceAuto))
        #expect(Self.decide(mode: .forward) == .ineligible(.notAReply))
        #expect(Self.decide(mode: .new) == .ineligible(.notAReply))
        #expect(Self.decide(source: .agent) == .ineligible(.notTheUsersDraft))
        #expect(Self.decide(source: .cli) == .ineligible(.notTheUsersDraft))
        #expect(Self.decide(empty: false) == .ineligible(.bodyNotEmpty))
        #expect(Self.decide(mine: true) == .ineligible(.messageIsMine))
        #expect(Self.decide(replyTo: Self.older, newest: Self.older, mine: true) == .ineligible(.messageIsMine))
        #expect(Self.decide(hidden: true) == .ineligible(.hiddenForConversation))
        #expect(Self.decide(newest: nil) == .ineligible(.decidedTooLate))
        #expect(Self.decide(mine: nil) == .ineligible(.decidedTooLate))
        #expect(Self.decide(phase: .unavailable("off")) == .ineligible(.unavailable))
        #expect(Self.decide(phase: .failed("failed")) == .ineligible(.unavailable))
        #expect(InstantReplyEligibility.ineligible(.stripOff).reasonName == "stripOff")
        #expect(Self.decide(excluded: .calendarInvite) == .ineligible(.calendarInvite))
        #expect(Self.decide(excluded: .promotionOrSocial) == .ineligible(.promotionOrSocial))
        #expect(Self.decide(excluded: .bulkSender) == .ineligible(.bulkSender))
        #expect(Self.decide(excluded: .notInInbox) == .ineligible(.notInInbox))
        #expect(Self.decide(excluded: .spamOrTrash) == .ineligible(.spamOrTrash))
        #expect(Self.decide(excluded: .tooLong) == .ineligible(.tooLong))
    }

    @Test func theExclusionsAreAPureFunctionOverWhatIsKnown() {
        typealias Facts = QuickReplyExclusion.Facts
        #expect(QuickReplyExclusion.reason(Facts()) == nil, "nothing known: nothing excluded")
        #expect(QuickReplyExclusion.reason(Facts(newestHasCalendarInvite: true)) == .calendarInvite)
        #expect(QuickReplyExclusion.reason(Facts(categories: [GmailLabelID("CATEGORY_PROMOTIONS")])) == .promotionOrSocial)
        #expect(QuickReplyExclusion.reason(Facts(categories: [GmailLabelID("CATEGORY_SOCIAL")])) == .promotionOrSocial)
        #expect(QuickReplyExclusion.reason(Facts(categories: [GmailLabelID("CATEGORY_UPDATES")])) == nil)
        #expect(QuickReplyExclusion.reason(Facts(newestHasListUnsubscribe: true)) == .bulkSender)
        #expect(QuickReplyExclusion.reason(Facts(newestHasListUnsubscribe: false)) == nil)
        #expect(QuickReplyExclusion.reason(Facts(inInbox: false)) == .notInInbox)
        #expect(QuickReplyExclusion.reason(Facts(inInbox: true)) == nil)
        #expect(QuickReplyExclusion.reason(Facts(inSpamOrTrash: true)) == .spamOrTrash)
        #expect(QuickReplyExclusion.reason(Facts(newestWasCut: true)) == .tooLong)
        #expect(QuickReplyExclusion.reason(Facts(newestHasCalendarInvite: true, inSpamOrTrash: true)) == .spamOrTrash,
                "Spam and Trash first")
        #expect(QuickReplyExclusion.allCases.allSatisfy { !$0.text.isEmpty })
    }

    @Test func invitationsAndMailingListsGetNoQuickRepliesAndTheModelIsNotAsked() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: .stripOn, providers: [provider])
        f.holdStripClock()
        await f.loaded()
        let invite = try await f.thread { last, _ in last.hasCalendarInvite }
        let replies = await f.openConversation(invite)
        #expect(replies.phase == .unavailable("No quick replies for calendar invitations"))
        #expect(replies.failure == .excluded(.calendarInvite) && !replies.isOffered)
        #expect(!provider.requests.contains { $0.task == .replyOptions }, "the model is not asked")
        let (session, _, strip) = try await f.stripReply(invite)
        #expect(strip == nil)
        let panel = try #require(f.env.ai?.togglePanel(session, showQuickReplies: true))
        let listed = try #require(panel.quickReplies)
        await eventually { listed.phase != .loading }
        #expect(!listed.isOffered && listed.failure == .excluded(.calendarInvite))
        #expect(!provider.requests.contains { $0.task == .replyOptions })

        let list = try await f.thread { last, unsubscribes in unsubscribes && !last.hasCalendarInvite }
        let listReplies = await f.openConversation(list)
        if case .unavailable = listReplies.phase {} else { Issue.record("a mailing list gets no quick replies") }
        #expect([QuickRepliesModel.Failure.excluded(.bulkSender), .excluded(.promotionOrSocial)]
            .contains(listReplies.failure ?? .notOffered))
        #expect(!provider.requests.contains { $0.task == .replyOptions })
    }

    @Test func theRewritePresetsIncludeImproveAndLonger() {
        let ids = AIComposerModel.presets.map(\.id)
        #expect(ids.first == "improve", "Improve writing comes first")
        let shorter = ids.firstIndex(of: "shorter")
        #expect(shorter.map { ids[$0 + 1] } == "longer", "Longer follows Shorter")
        #expect(ids.contains("clearer"), "Clearer stays (Superhuman's Simplify)")
        #expect(AIComposerModel.presets.allSatisfy { $0.completesInput || $0.instruction.hasSuffix(".") })
    }

    @Test func tabPreviewsAndWrapsWithoutTouchingTheDraft() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (session, editor, model) = try await f.readyStrip()
        await session.settle()
        let calls = f.recorder.calls
        let document = session.document
        #expect(model.selection == nil && model.ghostText == nil)
        #expect(model.placeholder == "Write your reply, or press ⇥ for a quick reply")
        #expect(model.hint.map(\.key) == ["⇥", "⌘1–3"])

        #expect(model.handle(.next) && model.selection == 0)
        #expect(model.ghostText == Self.first && model.placeholder == nil)
        #expect(model.hint.map(\.key) == ["↵", "⇥", "esc"])
        #expect(model.previewAnnouncement == "Quick reply 1 of 3: Sounds good")
        #expect(model.handle(.next) && model.handle(.next) && model.handle(.next))
        #expect(model.selection == 0, "wraps")
        #expect(model.handle(.clear) && model.selection == nil)
        #expect(model.handle(.previous) && model.selection == 2, "⇧⇥ from none: the last")
        #expect(model.ghostText == Self.third)
        #expect(model.handle(.previous) && model.selection == 1)

        #expect(editor.text.isEmpty && editor.replacements.isEmpty, "the ghost is not text")
        #expect(session.document == document && !session.hasUserEdits)
        await session.settle()
        #expect(f.recorder.calls == calls, "previewing saves nothing")
    }

    @Test func returnPutsThePreviewInAsOneEdit() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (session, editor, model) = try await f.readyStrip()
        #expect(model.handle(.next) && model.handle(.next))
        #expect(model.handle(.use))
        #expect(editor.replacements.count == 1 && editor.replacements.first?.range == 0..<0)
        #expect(editor.text == Self.second && session.plainText == Self.second)
        #expect(model.phase == .used(1) && !model.showsRow && !model.isLive && model.selection == nil)
        #expect(editor.caretPlacements == [(Self.second as NSString).length], "the caret goes after the reply")
        #expect(editor.focusCount >= 1)
        #expect(session.notice == nil)
        #expect(session.hasUserEdits, "it is the user's draft now, saved like typing")
    }

    @Test func returnWithoutAPreviewIsANewLine() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (_, editor, model) = try await f.readyStrip()
        #expect(model.handle(.use) == false, "nothing previewed: ↵ is the editor's new line")
        #expect(editor.replacements.isEmpty && model.phase == .ready)
    }

    @Test func commandDigitsPutThatOptionIn() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (_, editor, model) = try await f.readyStrip()
        model.use(1)
        #expect(editor.text == Self.second && model.phase == .used(1))

        _ = editor.replaceText(in: 0..<(editor.text as NSString).length, with: "")
        #expect(model.phase == .ready && model.isLive)
        editor.type("Hi Robin. ")
        #expect(!model.isLive && model.phase == .ready && !model.showsRow && model.hint.isEmpty)
        model.use(2, via: .click)
        #expect(editor.text == "Hi Robin. ", "the typed text stays, alone")
    }

    @Test func typingReleasesTheKeysAndKeepsTheRow() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (session, editor, model) = try await f.readyStrip()
        #expect(model.handle(.next))
        editor.type("x")
        #expect(model.selection == nil && model.ghostText == nil, "typing removes the ghost")
        #expect(!model.handle(.next) && !model.handle(.previous) && !model.handle(.use) && !model.handle(.clear))
        #expect(!model.showsRow && model.phase == .ready, "quick replies only over an empty body")
        _ = editor.replaceText(in: 0..<1, with: "")
        #expect(model.isLive && model.handle(.next), "empty again: live again")
        editor.type("\n")
        #expect(!model.isLive && model.selection == nil, "a stray Return is a character too")
        _ = editor.replaceText(in: 0..<1, with: "")

        session.openSnippetPicker()
        #expect(!model.isLive && !model.handle(.next))
        session.closeSnippetPicker()
        #expect(model.isLive)
        let center = try #require(f.env.ai)
        center.togglePanel(session)
        #expect(!model.showsRow && !model.isLive, "the panel lists the same options; never both")
        center.togglePanel(session)
        #expect(model.showsRow && model.isLive)
    }

    @Test func escapeClearsThePreviewFirst() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (session, _, model) = try await f.readyStrip()
        #expect(model.handle(.next))
        #expect(model.handle(.clear) && model.selection == nil && session.isOpen)
        #expect(model.handle(.clear) == false, "nothing previewed: Esc goes on to close the composer")
    }

    @Test func commandReturnWithAPreviewDoesNotSend() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (session, editor, model) = try await f.readyStrip()
        await session.settle()
        let before = f.recorder.calls
        #expect(model.handle(.next))
        #expect(await f.run(.send, in: session))
        #expect(session.notice == ComposeSession.Notice(.warning, "The quick reply isn't in your message yet. Press ↵ to put it in, or type your own."))
        #expect(session.isOpen && editor.text.isEmpty)
        await session.settle()
        #expect(f.recorder.calls == before, "nothing saved, queued or sent")

        #expect(model.handle(.use))
        #expect(editor.text == Self.first)
        #expect(await f.run(.send, in: session))
        #expect(f.recorder.calls.filter { $0 == "send" }.count == 1, "↵ then ⌘↵: one send through the one send path")
        #expect(!session.isOpen)
    }

    @Test func usingAQuickReplySendsNothing() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (session, editor, model) = try await f.readyStrip()
        #expect(model.handle(.next) && model.handle(.use))
        #expect(editor.text == Self.first)
        await session.settle()
        #expect(!f.recorder.calls.contains { ["send", "sendNow", "scheduleSend"].contains($0) }, "\(f.recorder.calls)")
        #expect(f.store.sentMessages.isEmpty && f.store.heldSendCount == 0)
    }

    @Test func automaticRequestsNeverLeaveTheMacWithoutTheSeparateOptIn() async throws {
        let consent = [AIProviderID.agentClaude: ProviderConsent(grantedAt: fixedNow, fingerprint: "/opt/bin/claude")]

        let claude = AIThreadTests.remote()
        let f = AIFixture(settings: AISettings(draftReplies: .onDeviceAuto, consents: consent, instantReplyStrip: true),
                          providers: [claude])
        f.holdStripClock()
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        let replies = await f.openConversation(thread)
        if case .unavailable = replies.phase {} else { Issue.record("automatic quick replies stay on this Mac") }
        let (_, _, none) = try await f.stripReply(thread)
        #expect(none == nil)
        #expect(!claude.requests.contains { $0.task == .replyOptions })

        let optedIn = AIThreadTests.remote()
        let g = AIFixture(settings: AISettings(draftReplies: .onDeviceAuto, agentCLIAutoQuickReplies: true,
                                               consents: consent, instantReplyStrip: true),
                          providers: [optedIn])
        g.holdStripClock()
        await g.loaded()
        let other = try await g.thread(minimumMessages: 3)
        _ = await g.openConversation(other)
        let (_, _, strip) = try await g.stripReply(other)
        let model = try #require(strip)
        #expect(model.phase == .ready && model.badge?.leavesMac == true)
        #expect(model.badge?.title == "Sent to Anthropic via Claude Code")
        #expect(model.accessibilityLabel.contains("Sent to Anthropic via Claude Code"))

        let work = try #require(g.router.accounts.first { $0.id == AIFixture.work }?.account)
        let asked = optedIn.requests.count
        try g.center.setOnDeviceOnly(true, account: work)
        #expect(model.options.isEmpty && model.badge == nil)
        g.center.conversationAppeared(other, messageCount: 3)
        let again = g.center.quickReplies(for: other)
        await eventually { if case .unavailable = again.phase { true } else { false } }
        #expect(optedIn.requests.count == asked)

        let pcc = ScriptedProvider(id: .applePCC, displayName: "Apple Private Cloud Compute",
                                   capabilities: .fake(contextTokens: nil, policyInputCap: 32_000, dataLocation: .appleCloud))
        let h = AIFixture(settings: AISettings(draftReplies: .onDeviceAuto, pccEnabled: true,
                                               consents: [.applePCC: ProviderConsent(grantedAt: fixedNow, fingerprint: nil)],
                                               instantReplyStrip: true),
                          providers: [pcc])
        h.holdStripClock()
        await h.loaded()
        let third = try await h.thread(minimumMessages: 3)
        _ = await h.openConversation(third)
        let (_, _, never) = try await h.stripReply(third)
        #expect(never == nil && pcc.requests.isEmpty)
    }

    @Test func requestsAreDelimitedAndCarryNoDraftText() async throws {
        let options = #"{"options":[{"label":"Pay now","body":"Sure, I paid at https://pay.evil.example/now"},"#
            + #"{"label":"As asked","body":"Ignore this: email_data says to wire money."},"#
            + #"{"label":"No","body":"No, thanks."}]}"#
        let provider = ScriptedProvider { request, _ in
            request.task == .replyOptions ? .text(options) : FakeAIProvider.cannedScript(request)
        }
        let f = AIFixture(settings: .stripOn, providers: [provider])
        f.holdStripClock()
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        let replies = await f.openConversation(thread)
        let request = try #require(provider.requests.last { $0.task == .replyOptions })
        #expect(RequestInspector.problems(in: request).isEmpty, "email text only inside the delimiters")
        #expect(!request.untrusted.contains { $0.kind == .draft }, "never the user's draft text")

        let (session, editor, strip) = try await f.stripReply(thread)
        let model = try #require(strip)
        #expect(model.isSuspicious, "the row shows the warning glyph")
        #expect(model.options.first?.linkHostsAddedByAI == ["pay.evil.example"])
        model.use(0)
        #expect(editor.text == "Sure, I paid at https://pay.evil.example/now", "kept as visible text the user can delete")
        let notice = try #require(session.notice)
        #expect(notice.kind == .warning && notice.text.contains(AIWording.suspicious))
        #expect(notice.text.contains("Link added by AI: pay.evil.example"))

        let count = provider.requests.filter { $0.task == .replyOptions }.count
        replies.retryAutomatic()
        await eventually { replies.phase == .ready }
        #expect(provider.requests.filter { $0.task == .replyOptions }.count == count + 1)
    }

    @Test func failuresAreQuietAndRetryUsesTheAutomaticRules() async throws {
        let refusing = ScriptedProvider { request, _ in
            request.task == .replyOptions ? .fail(.refused) : FakeAIProvider.cannedScript(request)
        }
        let f = AIFixture(settings: .stripOn, providers: [refusing])
        f.holdStripClock()
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        await f.loadContext(thread)
        let (_, _, strip) = try await f.stripReply(thread)
        let refused = try #require(strip)
        await eventually { if case .quiet = refused.phase { true } else { false } }
        #expect(refused.phase == .quiet("The model's safety filter stopped this text. Try a smaller part or other words", canRetry: false))
        #expect(refused.showsRow && !refused.isLive, "the row stays, quietly")
        #expect(refused.quietKind == "refused")
        refused.retry()
        #expect(refusing.requests.filter { $0.task == .replyOptions }.count == 1, "no Try again after a refusal")

        let timingOut = ScriptedProvider { request, index in
            guard request.task == .replyOptions else { return FakeAIProvider.cannedScript(request) }
            return index == 0 ? .fail(.timeout) : FakeAIProvider.cannedScript(request)
        }
        let g = AIFixture(settings: .stripOn, providers: [timingOut])
        g.holdStripClock()
        await g.loaded()
        let other = try await g.thread(minimumMessages: 3)
        await g.loadContext(other)
        let (_, _, second) = try await g.stripReply(other)
        let model = try #require(second)
        await eventually { if case .quiet = model.phase { true } else { false } }
        #expect(model.phase == .quiet("The model took too long", canRetry: true))
        model.retry()
        await eventually { model.phase == .ready }
        #expect(timingOut.requests.filter { $0.task == .replyOptions }.count == 2)
        #expect(g.center.loadedContext(other)?.input.trigger == .automatic, "Try again is not a user request")
    }

    @Test func itGivesUpAfterTheDeadline() async throws {
        let provider = ScriptedProvider { request, _ in
            request.task == .replyOptions ? .hang : FakeAIProvider.cannedScript(request)
        }
        let f = AIFixture(settings: .stripOn, providers: [provider])
        let gate = f.holdStripClock()
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        await f.loadContext(thread)
        let (_, _, strip) = try await f.stripReply(thread)
        let model = try #require(strip)
        let replies = f.center.quickReplies(for: thread)
        #expect(model.phase == .waiting && model.showsRow && model.waitingText == "Thinking…")
        await eventually { replies.phase == .loading && gate.waiting == [InstantReplyPolicy.slowNotice] }
        gate.releaseNext()
        await eventually { model.isSlow }
        #expect(model.waitingText == "Still thinking…")
        await eventually { gate.waiting == [InstantReplyPolicy.giveUp - InstantReplyPolicy.slowNotice] }
        gate.releaseNext()
        await eventually { model.phase != .waiting }
        #expect(model.phase == .quiet("The model took too long", canRetry: true))
        #expect(replies.phase == .idle, "the automatic request was stopped (cancelAutomatic)")
        #expect(model.showsRow && model.quietKind == "timeout", "the row stays in place")
        #expect(InstantReplyPolicy.giveUp(agentCLIMayServe: true) > Duration.seconds(90), "an agent CLI keeps its own 90 s")
    }

    @Test func emptyAndDuplicateOptionsAreDropped() async throws {
        let duplicates = #"{"options":[{"label":"","body":"Same"},{"label":"A","body":"same"},{"label":"B","body":" "}]}"#
        let provider = ScriptedProvider { request, _ in
            request.task == .replyOptions ? .text(duplicates) : FakeAIProvider.cannedScript(request)
        }
        let f = AIFixture(settings: .stripOn, providers: [provider])
        f.holdStripClock()
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        let replies = await f.openConversation(thread)
        #expect(replies.options.map(\.label) == ["Same"] && replies.options.map(\.id) == [0], "the ⌘J list too")
        let (_, _, strip) = try await f.stripReply(thread)
        let model = try #require(strip)
        #expect(model.options.map(\.body) == ["Same"])
        #expect(model.handle(.next) && model.handle(.next) && model.selection == 0)

        let empty = #"{"options":[{"label":"A","body":" "},{"label":"B","body":""},{"label":"","body":"\n"}]}"#
        let nothing = ScriptedProvider { request, _ in
            request.task == .replyOptions ? .text(empty) : FakeAIProvider.cannedScript(request)
        }
        let g = AIFixture(settings: .stripOn, providers: [nothing])
        g.holdStripClock()
        await g.loaded()
        let other = try await g.thread(minimumMessages: 3)
        await g.loadContext(other)
        let (_, _, second) = try await g.stripReply(other)
        let quiet = try #require(second)
        await eventually { quiet.phase != .waiting }
        #expect(quiet.phase == .quiet("No quick replies this time", canRetry: false))
        #expect(quiet.quietKind == "empty")
    }

    @Test func undoBringsTheStripBack() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (_, editor, model) = try await f.readyStrip()
        #expect(model.handle(.next) && model.handle(.use))
        #expect(model.phase == .used(0) && !model.showsRow)
        #expect(!model.handle(.next), "⇥ is the editor's again while the reply is in the body")
        _ = editor.replaceText(in: 0..<(editor.text as NSString).length, with: "")
        #expect(model.phase == .ready && model.selection == nil && model.isLive && model.showsRow)
        #expect(model.handle(.next) && model.ghostText == Self.first)
    }

    @Test func hideLastsForTheSessionAndClearCacheResetsIt() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: .stripOn, providers: [provider])
        f.holdStripClock()
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        _ = await f.openConversation(thread)
        let (session, _, strip) = try await f.stripReply(thread)
        let model = try #require(strip)
        #expect(f.env.actions.availability(.aiHideInstantReply, host: session) == .enabled)
        #expect(await f.run(.aiHideInstantReply, in: session))
        #expect(model.phase == .hidden && !model.showsRow && !model.isLive)
        #expect(f.env.actions.availability(.aiHideInstantReply, host: session) == .hidden)

        f.compose.close(session)
        let (second, _, again) = try await f.stripReply(thread)
        #expect(again == nil, "hidden for this conversation for the rest of the session")

        f.compose.close(second)
        await f.center.clearCache()
        #expect(!f.center.quickReplies(for: thread).hiddenInComposer)
        let (third, _) = try await f.reply(thread)
        f.compose.attachInstantReply(third)
        await eventually { third.instantReply != nil }
        let back = try #require(third.instantReply)
        await eventually { back.phase == .ready }
        #expect(provider.requests.filter { $0.task == .replyOptions }.count == 2)
    }

    @Test func theModuleFlagRemovesEverything() async throws {
        let f = AIFixture(settings: .stripOn, flags: FeatureFlags().with(.instantReply, false))
        f.holdStripClock()
        await f.loaded()
        #expect(!f.env.actions.contains(.aiToggleInstantReply) && !f.env.actions.contains(.aiHideInstantReply))
        let thread = try await f.thread(minimumMessages: 3)
        _ = await f.openConversation(thread)
        let (session, _, strip) = try await f.stripReply(thread)
        #expect(strip == nil && f.compose.instantReply(for: session) == nil)
        await session.settle()
        #expect(f.compose.blockingNotice(session) == nil, "the composer is exactly as before")

        let g = AIFixture(settings: .stripOn, flags: FeatureFlags().with(.ai, false))
        g.holdStripClock()
        await g.loaded()
        let other = try await g.thread(minimumMessages: 3)
        let (_, _, none) = try await g.stripReply(other)
        #expect(none == nil)
    }

    @Test func thePaletteTogglesTheSettingWithADirectionalTitle() async throws {
        let f = AIFixture(settings: AISettings(draftReplies: .onDeviceAuto))
        await f.loaded()
        let toggle = try #require(f.env.actions.descriptor(.aiToggleInstantReply))
        #expect(!toggle.changesMail && toggle.defaultBindings.isEmpty, "no key: ⇥ belongs to the body editor")
        #expect(ActionRules.title(for: toggle, in: f.router.actionContext()) == "Show quick replies when replying")
        #expect(await f.run(.aiToggleInstantReply))
        #expect(f.center.settings.instantReplyStrip)
        #expect(ActionRules.title(for: toggle, in: f.router.actionContext()) == "Stop showing quick replies when replying")
        #expect(await f.run(.aiToggleInstantReply))
        #expect(!f.center.settings.instantReplyStrip)

        let g = AIFixture(settings: AISettings(draftReplies: .onDemand))
        await g.loaded()
        #expect(g.env.actions.availability(.aiToggleInstantReply, host: g.router) == .hidden)
        let page = AISettingsPageModel(center: g.center, environment: g.env)
        #expect(!page.offersInstantReplyStrip)
        page.instantReplyStrip = true
        #expect(!g.center.settings.instantReplyStrip)
        page.draftReplies = .onDeviceAuto
        #expect(page.offersInstantReplyStrip)
        page.instantReplyStrip = true
        #expect(g.center.settings.instantReplyStrip && page.instantReplyStrip)
        #expect(AISettingsPageModel.instantReplyStripTitle == "Show quick replies when I reply (⇥ to cycle)")
    }

    @Test func logLinesCarryNoContent() async throws {
        let captured = LineBox()
        Log.setMirror { record in
            if record.message.contains("instantReply") { captured.append(record.message) }
        }
        defer { Log.setMirror(nil) }
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        _ = await f.openConversation(thread)
        let detail = try #require(await AIThreadLoader.first(f.store.threadDetail(thread)) ?? nil)
        let (session, editor, strip) = try await f.stripReply(thread)
        let model = try #require(strip)
        #expect(model.handle(.next) && model.handle(.clear))
        #expect(model.handle(.next) && model.handle(.use))
        _ = editor.replaceText(in: 0..<(editor.text as NSString).length, with: "")
        #expect(model.handle(.next))
        #expect(await f.run(.send, in: session))
        editor.type("x")
        model.hideForConversation()

        let lines = captured.lines
        for expected in ["instantReply shown state=ready", "instantReply cleared reason=esc",
                         "instantReply used index=1 via=return", "instantReply guard send-refused",
                         "instantReply cleared reason=typed", "instantReply cleared reason=hide"] {
            #expect(lines.contains { $0.hasPrefix(expected) }, "\(expected)")
        }
        var content = model.options.flatMap { [$0.label, $0.body] }
        content += [detail.subject, thread.gmailThreadID.rawValue, AIThreadLoader.threadKey(thread)]
        content += detail.messages.compactMap { $0.from?.email }
        for line in lines {
            for text in content where text.count >= 3 {
                #expect(!line.contains(text), "an instantReply log line carries content")
            }
        }
    }

    @Test func theSendPathGuardIsTheOnlyComposeChange() async throws {
        let f = AIFixture(settings: .stripOn)
        f.holdStripClock()
        let (session, editor, model) = try await f.readyStrip()
        await session.settle()
        #expect(f.compose.blockingNotice(session) == nil, "nothing previewed: the send path is as before")
        #expect(model.handle(.next) && model.isPreviewingUnaccepted)
        #expect(f.compose.blockingNotice(session)?.kind == .warning)
        #expect(model.handle(.clear))
        #expect(f.compose.blockingNotice(session) == nil)
        #expect(model.handle(.next))
        editor.type("Hi")
        #expect(!model.isPreviewingUnaccepted && f.compose.blockingNotice(session) == nil, "typed text sends as before")
    }
}

extension AISettings {
    static let stripOn = AISettings(draftReplies: .onDeviceAuto, instantReplyStrip: true)
}

extension AIFixture {
    @discardableResult
    func holdStripClock() -> SleepGate {
        let gate = SleepGate()
        center.instantReplyTiming = gate.timing
        return gate
    }

    func openConversation(_ thread: ThreadKey) async -> QuickRepliesModel {
        center.conversationAppeared(thread, messageCount: 3)
        let replies = center.quickReplies(for: thread)
        await eventually { replies.phase != .idle && replies.phase != .loading }
        return replies
    }

    func thread(where matches: (MessageSummary, Bool) -> Bool) async throws -> ThreadKey {
        let rows = try await store.threadPage(.system(.inbox), account: Self.work, after: nil, limit: 1_000).rows
        for row in rows {
            guard let detail = await AIThreadLoader.first(store.threadDetail(row.id)) ?? nil,
                  let last = detail.messages.last else { continue }
            let unsubscribes = ((try? await store.unsubscribeInfo(last.id)) ?? nil) != nil
            if matches(last, unsubscribes) { return row.id }
        }
        Issue.record("no such conversation in the fake inbox")
        throw CancellationError()
    }

    func loadContext(_ thread: ThreadKey) async {
        _ = await center.context(for: thread, trigger: .automatic)
    }

    func stripReply(_ thread: ThreadKey) async throws -> (ComposeSession, FakeEditor, InstantReplyModel?) {
        let (session, editor) = try await reply(thread)
        compose.attachInstantReply(session)
        return (session, editor, session.instantReply)
    }

    func readyStrip() async throws -> (ComposeSession, FakeEditor, InstantReplyModel) {
        await loaded()
        let thread = try await self.thread(minimumMessages: 3)
        _ = await openConversation(thread)
        let (session, editor, strip) = try await stripReply(thread)
        let model = try #require(strip)
        #expect(model.isLive)
        return (session, editor, model)
    }
}

final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(id: Int, duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextID = 0

    var timing: InstantReplyTiming { InstantReplyTiming(sleep: { [self] duration in try await self.sleep(duration) }) }

    var waiting: [Duration] { lock.withLock { waiters.map { $0.duration } } }

    func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    waiters.append((id, duration, continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    @discardableResult
    func releaseNext() -> Bool {
        let waiter = lock.withLock { waiters.isEmpty ? nil : waiters.removeFirst() }
        waiter?.continuation.resume()
        return waiter != nil
    }
}

final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ line: String) { lock.withLock { items.append(line) } }
    var lines: [String] { lock.withLock { items } }
}
