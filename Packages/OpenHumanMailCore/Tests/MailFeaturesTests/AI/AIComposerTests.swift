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
@Suite(.serialized) struct AIComposerTests {
    @Test func cmdJOpensThePanelOnTheSelectionAndClosesOnTheSecondPress() async throws {
        let f = AIFixture()
        await f.loaded()
        let (session, editor) = try f.newMessage("Hello there, Dana", selection: 0..<5)
        #expect(f.env.actions.availability(.aiRewrite, host: session) == .enabled)
        #expect(f.env.actions.descriptor(.aiRewrite)?.shortcutHint == "⌘J")
        #expect(await f.run(.aiRewrite, in: session))
        let panel = try #require(session.aiPanel)
        #expect(panel.scope == .selection && panel.original == "Hello")
        #expect(panel.quickReplies == nil, "a new message has no conversation to answer")
        #expect(await f.run(.aiRewrite, in: session))
        #expect(session.aiPanel == nil && editor.focusCount == 1, "⌘J again closes it and the editor gets the keys")
    }

    @Test func theScopeIsTheWholeDraftWithoutASelectionAndNotesWhenTheBodyIsEmpty() async throws {
        let f = AIFixture()
        await f.loaded()
        let (whole, _) = try f.newMessage("Thanks for the notes.")
        f.env.ai?.togglePanel(whole)
        #expect(whole.aiPanel?.scope == .wholeDraft && whole.aiPanel?.original == "Thanks for the notes.")
        let (empty, _) = try f.newMessage("  \n")
        f.env.ai?.togglePanel(empty)
        #expect(empty.aiPanel?.scope == .notes && empty.aiPanel?.original == "")
        #expect(empty.aiPanel?.placeholder == "Write, find, schedule, or ask anything")
    }

    @Test func aRewriteStreamsWithItsBadgeAndReplacesTheScopeAsOneEdit() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let (session, editor) = try f.newMessage("Hello there, Dana", selection: 0..<5)
        let panel = try #require(f.env.ai?.togglePanel(session))
        panel.instruction = "Make it shorter"
        panel.submit()
        await eventually { panel.phase == .done }
        let version = try #require(panel.currentVersion)
        #expect(version.text == "Rewritten: Hello" && version.isComplete && !version.isSuspicious)
        #expect(version.badge?.title == "On this Mac" && version.badge?.leavesMac == false, "every AI surface has its badge")
        let request = try #require(provider.requests.last)
        #expect(request.task == .rewrite)
        #expect(request.trusted.map(\.text) == ["Make it shorter"])
        #expect(request.untrusted.contains { $0.kind == .draft && $0.text == "Hello" })
        #expect(RequestInspector.problems(in: request).isEmpty)
        #expect(editor.replacements.isEmpty, "nothing reaches the draft before ↵")

        panel.submit()
        #expect(editor.replacements.count == 1, "one edit")
        #expect(editor.text == "Rewritten: Hello there, Dana")
        #expect(session.aiPanel == nil)
        await session.settle()
        #expect(!f.recorder.calls.contains { $0.hasPrefix("send") || $0 == "scheduleSend" }, "never sent")
        #expect(f.store.sentMessages.isEmpty)
    }

    @Test func insertBelowKeepsTheOriginalText() async throws {
        let f = AIFixture()
        await f.loaded()
        let (session, editor) = try f.newMessage("Thanks for the notes.")
        let panel = try #require(f.env.ai?.togglePanel(session))
        panel.instruction = "Friendlier"
        panel.generate()
        await eventually { panel.phase == .done }
        panel.insertBelow()
        #expect(editor.text == "Thanks for the notes.\n\nRewritten: Thanks for the notes.")
    }

    @Test func textThatCannotBePutBackIsCopiedNotPasted() async throws {
        let f = AIFixture()
        await f.loaded()
        let (session, editor) = try f.newMessage("Hello there", selection: 0..<5)
        let panel = try #require(f.env.ai?.togglePanel(session))
        panel.instruction = "Shorter"
        panel.generate()
        await eventually { panel.phase == .done }
        editor.text = "Goodbye there"
        panel.replace()
        #expect(editor.replacements.isEmpty && editor.text == "Goodbye there", "never pasted over other text")
        #expect(f.pasteboard.copied == ["Rewritten: Hello"])
        #expect(session.notice?.text.contains("clipboard") == true)

        let (other, _) = try f.newMessage("Second draft")
        let second = try #require(f.env.ai?.togglePanel(other))
        second.instruction = "Clearer"
        second.generate()
        await eventually { second.phase == .done }
        other.editor = nil
        second.replace()
        #expect(f.pasteboard.copied.last == "Rewritten: Second draft")
    }

    @Test func threeVersionsAreKeptAndTryAgainAsksForANewOne() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let (session, _) = try f.newMessage("Draft text")
        let panel = try #require(f.env.ai?.togglePanel(session))
        panel.instruction = "Shorter"
        for _ in 0..<4 {
            panel.generate()
            await eventually { panel.phase == .done }
        }
        #expect(panel.versions.count == AIComposerModel.maxVersions)
        #expect(panel.counterText == "3/3")
        panel.previousVersion()
        #expect(panel.counterText == "2/3")
        panel.nextVersion()
        #expect(panel.counterText == "3/3")
        #expect(provider.requests.filter { $0.task == .rewrite }.count == 4)
    }

    @Test func presetsRunAndTranslateWaitsForTheLanguage() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let (session, _) = try f.newMessage("Draft text")
        let panel = try #require(f.env.ai?.togglePanel(session))
        let translate = try #require(AIComposerModel.presets.first { $0.completesInput })
        panel.run(translate)
        #expect(panel.instruction == "Translate into " && panel.phase == .ready && provider.requests.isEmpty)
        let shorter = try #require(AIComposerModel.presets.first { $0.id == "shorter" })
        panel.run(shorter)
        await eventually { panel.phase == .done }
        #expect(provider.requests.last?.trusted.first?.text == shorter.instruction)
    }

    @Test func notesBecomeADraft() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let (session, editor) = try f.newMessage("")
        let panel = try #require(f.env.ai?.togglePanel(session))
        panel.submit()
        #expect(panel.phase == .failed("Jot a few notes first") && provider.requests.isEmpty)
        panel.instruction = "thank Dana, meet Thursday"
        panel.submit()
        await eventually { panel.phase == .done }
        let request = try #require(provider.requests.last)
        #expect(request.trusted.first?.text == "Write the email from these notes: thank Dana, meet Thursday")
        panel.replace()
        #expect(editor.text == "Rewritten text.")
    }

    @Test func quickRepliesInAReplyPutTheChosenOptionInTheDraftAndNeverSend() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        let (session, editor) = try await f.reply(thread)
        #expect(f.env.actions.availability(.aiReplyOptions, host: session) == .enabled)
        #expect(await f.run(.aiRewrite, in: session))
        let panel = try #require(session.aiPanel)
        let replies = try #require(panel.quickReplies)
        #expect(panel.scope == .notes)
        await eventually { replies.phase == .ready }
        #expect(replies.options.map(\.label) == ["Sounds good", "Not this time", "Ask for details"])
        #expect(replies.badge?.title == "On this Mac")
        let request = try #require(provider.requests.last { $0.task == .replyOptions })
        #expect(request.trusted.contains { $0.kind == .userName && $0.text == "Robin Example" })
        #expect(RequestInspector.problems(in: request).isEmpty)

        replies.selectNext()
        replies.selectNext()
        #expect(replies.selectedOption?.label == "Not this time")
        replies.selectPrevious()
        #expect(replies.selection == 0)
        panel.submit()
        #expect(editor.text == "Sounds good, thanks.")
        #expect(session.aiPanel == nil)
        await session.settle()
        #expect(!f.recorder.calls.contains { $0.hasPrefix("send") || $0 == "scheduleSend" })
        #expect(f.store.sentMessages.isEmpty, "nothing is ever sent from a quick reply")

        f.env.ai?.togglePanel(session)
        #expect(provider.requests.filter { $0.task == .replyOptions }.count == 1)
    }

    @Test func linksTheAIAddedAreNamedInTheComposer() async throws {
        let options = #"{"options":[{"label":"Pay now","body":"Sure, I paid at https://pay.evil.example/now"},"#
            + #"{"label":"No","body":"No, thanks."},{"label":"Later","body":"Later this week."}]}"#
        let provider = ScriptedProvider { request, _ in
            request.task == .replyOptions ? .text(options) : FakeAIProvider.cannedScript(request)
        }
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        let (session, editor) = try await f.reply(thread)
        let panel = try #require(f.env.ai?.togglePanel(session))
        let replies = try #require(panel.quickReplies)
        await eventually { replies.phase == .ready }
        let pay = try #require(replies.options.first)
        #expect(pay.linkHostsAddedByAI == ["pay.evil.example"])
        panel.use(pay)
        #expect(editor.text.contains("https://pay.evil.example/now"), "kept as visible text the user can delete")
        #expect(session.notice?.text.contains("pay.evil.example") == true)
    }

    @Test func draftRepliesOffHidesQuickReplies() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AISettings(draftReplies: .off), providers: [provider])
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        let (session, _) = try await f.reply(thread)
        #expect(f.env.actions.availability(.aiReplyOptions, host: session) == .hidden)
        let panel = try #require(f.env.ai?.togglePanel(session))
        #expect(panel.quickReplies?.isOffered == false)
        #expect(!provider.requests.contains { $0.task == .replyOptions })
    }

    @Test func aProviderThatLeavesTheMacNeedsConsentFirst() async throws {
        let claude = ScriptedProvider(id: .agentClaude, displayName: "Claude Code", capabilities: .remote(),
                                      consentFingerprint: "/opt/bin/claude")
        let f = AIFixture(providers: [claude])
        await f.loaded()
        let (session, _) = try f.newMessage("Hello there")
        let panel = try #require(f.env.ai?.togglePanel(session))
        panel.instruction = "Shorter"
        panel.generate()
        await eventually { panel.consent != nil }
        #expect(claude.requests.isEmpty, "blocked until accepted: nothing was sent")
        let consent = try #require(panel.consent)
        #expect(consent.title == "Send email text to Claude Code?")
        #expect(consent.paragraphs.contains { $0.contains("Anthropic") && $0.contains("your own Claude Code login") })
        #expect(consent.accounts.count == 2, "every account's On-device AI only switch is in the sheet")

        await panel.acceptConsent()
        await eventually { panel.phase == .done }
        #expect(f.center.settings.consents[.agentClaude]?.fingerprint == "/opt/bin/claude")
        #expect(claude.requests.count == 1)
        let badge = try #require(panel.currentVersion?.badge)
        #expect(badge.leavesMac && badge.title == "Sent to Anthropic via Claude Code")
        #expect(badge.short == "Claude Code · leaves this Mac")

        try await f.center.revokeConsent(.agentClaude)
        panel.generate()
        await eventually { panel.consent != nil }
        #expect(claude.requests.count == 1, "revoked: asks again before sending")
    }

    @Test func anOnDeviceOnlyAccountNeverReachesAProviderThatLeavesTheMac() async throws {
        let claude = ScriptedProvider(id: .agentClaude, displayName: "Claude Code", capabilities: .remote(),
                                      consentFingerprint: "/opt/bin/claude")
        let consented = AISettings(consents: [.agentClaude: ProviderConsent(grantedAt: fixedNow, fingerprint: "/opt/bin/claude")])
        let f = AIFixture(settings: consented, providers: [claude])
        await f.loaded()
        let work = try #require(f.router.accounts.first { $0.id == AIFixture.work }?.account)
        try f.center.setOnDeviceOnly(true, account: work)
        #expect(f.center.isOnDeviceOnly(work))
        #expect(f.center.settings.onDeviceOnlyAccounts.allSatisfy { !$0.contains("@") }, "the address itself is not stored")

        let (session, _) = try f.newMessage("Hello there")
        let panel = try #require(f.env.ai?.togglePanel(session))
        panel.instruction = "Shorter"
        panel.generate()
        await eventually { if case .failed = panel.phase { true } else { false } }
        #expect(panel.phase == .failed(AIWording.reason(.onDeviceOnly)))
        #expect(claude.requests.isEmpty)

        let personal = try #require(f.compose.openNew(placement: .modal, account: AccountID(2)))
        _ = FakeEditor(session: personal, text: "Hi", selection: nil)
        let other = try #require(f.env.ai?.togglePanel(personal))
        other.instruction = "Shorter"
        other.generate()
        await eventually { other.phase == .done }
        #expect(claude.requests.count == 1)
    }

    @Test func aiOnAReplyDraftsAndSendsNothing() async throws {
        let f = AIFixture()
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        let (session, editor) = try await f.reply(thread)
        #expect(f.env.actions.availability(.aiRewrite, host: session) == .enabled)
        #expect(await f.run(.aiRewrite, in: session))
        let panel = try #require(session.aiPanel)
        let replies = try #require(panel.quickReplies)
        await eventually { replies.phase == .ready }
        panel.use(try #require(replies.options.first))
        #expect(editor.text == "Sounds good, thanks.")
        let rewrite = try #require(f.env.ai?.togglePanel(session))
        rewrite.instruction = "Friendlier"
        rewrite.generate()
        await eventually { rewrite.phase == .done }
        rewrite.replace()
        await session.settle()
        #expect(!f.recorder.calls.contains { ["send", "sendNow", "scheduleSend"].contains($0) }, "\(f.recorder.calls)")
        #expect(f.store.sentMessages.isEmpty && f.store.heldSendCount == 0)
    }

    @Test func theModuleFlagOrAMissingAICenterRemovesEverything() async throws {
        let off = AIFixture(flags: FeatureFlags().with(.ai, false))
        await off.loaded()
        #expect(!off.env.actions.contains(.aiRewrite) && !off.env.actions.contains(.aiSummarize))
        #expect(off.compose.aiCenter == nil, "no AI button or panel in the composer")
        let (session, _) = try off.newMessage("Hello")
        #expect(await off.run(.aiRewrite, in: session) == false)
        #expect(session.aiPanel == nil)

        let none = AIFixture(withAI: false)
        await none.loaded()
        let (plain, _) = try none.newMessage("Hello")
        #expect(none.env.actions.availability(.aiRewrite, host: plain) == .hidden)
        #expect(none.env.actions.availability(.aiSummarize, host: none.router) == .hidden)
        #expect(none.compose.aiCenter == nil)
    }
}
