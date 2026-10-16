import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct GapsBImportanceTests {
    func fixture(options: FakeMailStore.Options = .init(remoteAck: .immediate)) async -> ActionFixture {
        let f = ActionFixture(corpus: .make(threadCount: 12, now: fixedNow), options: options, location: .system(.inbox))
        await f.loaded()
        return f
    }

    func rules(_ f: ActionFixture) -> FakeImportanceRules { f.env.importance as! FakeImportanceRules }

    @Test func theCatalogHasTheNewEntriesWhereTheyBelong() {
        for id in [ActionID.moveToImportant, .moveToOther] {
            let descriptor = ActionCatalog.descriptor(id)
            #expect(descriptor?.module == .importance && descriptor?.changesMail == true, "\(id)")
            #expect(descriptor?.appearsInPalette == true && descriptor?.defaultBindings.isEmpty == true, "\(id): no key")
        }
        #expect(ImportanceActionHandler.ids.contains(.moveToImportant) && ImportanceActionHandler.ids.contains(.moveToOther))
        #expect(ActionCatalog.descriptor(.formatIndent)?.shortcutHint == "⌘]")
        #expect(ActionCatalog.descriptor(.formatOutdent)?.shortcutHint == "⌘[")
        #expect(ActionCatalog.formatIDs.contains(.formatIndent) && ActionCatalog.formatIDs.contains(.formatOutdent))
        #expect(ActionCatalog.descriptor(.formatIndent)?.scopes == [.composer])
    }

    @Test func moveToImportantAndOtherAreOneConversationRulesWithOneUndoEach() async throws {
        let f = await fixture()
        let thread = try #require(f.router.actionContext().focusedThread)
        #expect(f.registry.availability(.moveToImportant, host: f.router) == .enabled)
        #expect(await f.run(.moveToImportant))
        await f.toast("Moved to Important")
        #expect(rules(f).allRules.map(\.kind) == [.alwaysThread])
        #expect(rules(f).allRules.first?.value == thread.gmailThreadID.rawValue)
        #expect(rules(f).allRules.first?.match == .thread)
        #expect(await f.run(.explainPlacement))
        await f.toast("In Important: Moved to Important (this conversation only)")

        #expect(await f.run(.moveToOther))
        await f.toast("Moved to Other")
        #expect(rules(f).allRules.map(\.kind) == [.neverThread], "Move to Other replaces Move to Important")
        #expect(await f.run(.undo))
        #expect(rules(f).allRules.map(\.kind) == [.alwaysThread], "one undo entry puts the first move back")
        #expect(await f.run(.undo))
        #expect(rules(f).allRules.isEmpty)
    }

    @Test func aSenderRuleStillWinsAndTheToastSaysSo() async throws {
        let f = await fixture()
        let sender = try #require(f.router.actionContext().sender)
        #expect(await f.run(.neverImportant))
        #expect(await f.run(.moveToImportant))
        let explanation = ImportanceExplanation(isImportant: false, placement: "Other", reason: "Never important from \(sender)")
        await f.toast(ImportanceMover.ruleWinsText(explanation, gmail: true))
        #expect(ImportanceMover.ruleWinsText(explanation, gmail: true)
            == ImportanceActionHandler.senderRuleWinsText(explanation) + " Gmail now marks it important.")
        #expect(Set(rules(f).allRules.map(\.kind)) == [.neverSender, .alwaysThread], "the move is kept for later")
    }

    @Test func settingsListsConversationRulesBelowSendersByTheirSubject() {
        let account = AccountID(1)
        let sender = ImportanceRuleInfo(id: "1", kind: .alwaysSender, account: account, value: "ann@acme.example",
                                        split: nil, createdAt: fixedNow)
        let moved = ImportanceRuleInfo(id: "2", kind: .neverThread, account: account, value: "t42", split: nil,
                                       createdAt: fixedNow)
        let gone = ImportanceRuleInfo(id: "3", kind: .alwaysThread, account: account, value: "t43", split: nil,
                                      createdAt: fixedNow)
        let groups = ImportanceSettingsModel.groups([moved, gone, sender], threadSubjects: ["t42": "Quarterly plan"])
        #expect(groups.map(\.title) == ["Senders", "Conversations"])
        #expect(groups[1].rows.map(\.title)
                == ["Moved to Other: Quarterly plan", "Moved to Important: a conversation not on this Mac"])
        #expect(groups[1].rows.allSatisfy { !$0.isEditable && $0.detail == "This conversation only" })
        #expect(ImportanceSettingsModel.normalized("t42", for: .thread) == nil, "made on the conversation, not typed")
        #expect(!ImportanceSettingsModel.editableMatches.contains(.thread))
        #expect(ImportanceRuleMatch.allCases.firstIndex(of: .thread) == 1, "right below sender")
        #expect(ImportanceRuleKind.kind(match: .thread, effect: .important) == .alwaysThread)
        #expect(ImportanceRuleKind.kind(match: .thread, effect: .neverImportant) == .neverThread)
        let change = ImportanceChange(kind: .alwaysThread, account: account, value: " ThreadIDCase ")
        #expect(change.value == "ThreadIDCase" && change.effect == .important, "a Gmail id keeps its case")
    }
}

@MainActor
@Suite struct GapsBSendLaterTests {
    @Test func theCardOffersOnlyIfNoReplyForAReplyAndItIsOffByDefault() {
        var chosen: [TimeChoice] = []
        let key = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1"))
        let reply = TimePickerModel(kind: .sendLater, targets: [key], now: { fixedNow }) { chosen.append($0) }
        #expect(reply.offersOnlyIfNoReply && !reply.onlyIfNoReply)
        reply.onlyIfNoReply = true
        #expect(reply.chooseNumber(1))
        if case .at(_, let kind)? = chosen.last { #expect(kind == .ifNoReply) } else { Issue.record("no time chosen") }

        let new = TimePickerModel(kind: .sendLater, targets: [], now: { fixedNow }) { chosen.append($0) }
        #expect(!new.offersOnlyIfNoReply)
        new.onlyIfNoReply = true
        #expect(new.chooseNumber(1))
        if case .at(_, let kind)? = chosen.last { #expect(kind == .always, "a new message has nothing to wait on") } else {
            Issue.record("no time chosen")
        }
        #expect(!TimePickerModel(kind: .snooze, targets: [key]) { _ in }.offersOnlyIfNoReply)
        #expect(TimePickerModel(kind: .remind, targets: []) { _ in }.offersOnlyIfNoReply, "remind cards as before")
    }

    @Test func aReplyScheduledOnlyIfNoReplyPassesTheConditionToThePort() async throws {
        let f = ComposeFixture()
        await f.loaded()
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.updateBody(doc("Synthetic answer"))
        #expect(await f.run(.sendLater, in: session))
        let picker = try #require(f.timePicker)
        #expect(picker.kind == .sendLater && picker.offersOnlyIfNoReply && !picker.onlyIfNoReply)
        picker.onlyIfNoReply = true
        #expect(picker.chooseNumber(1))
        await f.compose.settle()
        let key = try #require(session.draftKey)
        #expect(f.recorder.calls.contains("scheduleSend:ifNoReply") && !f.recorder.calls.contains("scheduleSend"))
        #expect(f.store.sendCondition(key) == .ifNoReply)
        await f.posted("Scheduled for ")
        #expect(f.toasts.contains { $0.hasPrefix("Scheduled for ") && $0.contains(" if no reply") })
    }

    @Test func aPlainScheduleStaysOnTheOldCallAndANewMessageNeverOffersTheBox() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@example.invalid,"
        session.subject = "Later"
        session.updateBody(doc("See you"))
        #expect(await f.run(.sendLater, in: session))
        let picker = try #require(f.timePicker)
        #expect(!picker.offersOnlyIfNoReply)
        #expect(picker.chooseNumber(1))
        await f.compose.settle()
        let key = try #require(session.draftKey)
        #expect(f.recorder.calls.contains("scheduleSend") && !f.recorder.calls.contains { $0.hasPrefix("scheduleSend:") })
        #expect(f.store.sendCondition(key) == .always)
    }
}

@MainActor
@Suite struct GapsBSettingsTests {
    @Test func alsoShowInImportantOtherIsAPerSplitSettingOffByDefault() async throws {
        let f = SettingsFixture()
        let model = SplitSettingsModel(environment: f.env)
        model.start()
        await eventually { model.account != nil && !model.splits.isEmpty }
        let split = try #require(model.splits.first)
        let account = try #require(model.account)
        #expect(!model.isAlsoShownInInbox(split) && model.canSetAlsoShow)
        await model.setAlsoShownInInbox(split, true)
        #expect(model.isAlsoShownInInbox(split))
        #expect(try await f.store.get(AppSettings.alsoShowSplitInInbox(account)) == [split.id.rawValue])
        await model.setAlsoShownInInbox(split, false)
        #expect(try await f.store.get(AppSettings.alsoShowSplitInInbox(account)).isEmpty)
        #expect(AppSettings.alsoShowSplitInInbox(account).name == "split.also_show_in_inbox")
    }

    @Test func theZoomRowSaysWhatItChanges() {
        #expect(GeneralSettingsModel.zoomNote.contains("conversation list"))
        #expect(ReaderPreferences.zoomSteps.map(ReaderPreferences.percent) == ["90%", "100%", "110%", "125%", "150%"])
    }
}
