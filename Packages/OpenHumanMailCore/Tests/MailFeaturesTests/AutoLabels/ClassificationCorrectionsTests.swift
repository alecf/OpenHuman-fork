import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct ClassificationCorrectionsTests {
    typealias F = AutoLabelFixture

    static let recruiter = EmailAddress(name: "Rae Hunter", email: "rae@talent.example")
    static let roleSubject = "A senior design role"

    func row(_ f: F, _ subject: String) async throws -> ThreadRow {
        try #require(try await f.inbox().first { $0.subject == subject })
    }

    func handler(_ f: F) -> ClassificationCorrectionHandler {
        ClassificationCorrectionHandler(environment: f.env, feedback: ActionFeedback(environment: f.env))
    }

    func perform(_ f: F, _ id: ActionID, on row: ThreadRow, sender: String? = recruiter.email) async {
        var context = ActionContext(scope: .reader, account: F.work, accountCount: 1, location: .system(.inbox),
                                    selection: [row.id], focusedThread: row.id, canWrite: true)
        context.sender = sender
        let handler = handler(f)
        if case .started(let task) = handler.perform(ActionRequest(id: id, context: context, source: .palette, host: nil)) {
            await task.value
        }
        withExtendedLifetime(handler) {}
    }

    @Test func labelAsWritesOurLabelInOneUndoEntryAndRecordsAnExample() async throws {
        let f = F(writes: true, verdict: { _ in .pitch })
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: "A role for you.")
        await f.center.classifyRecent()
        let role = try await row(f, Self.roleSubject)
        #expect(f.store.labelNames(of: role.id).contains("OpenHuman/Pitch"))
        let undo = try #require(f.env.undo)
        let before = undo.stack.count
        #expect(try await f.center.setLabel("news", thread: role.id, row: role, labels: await f.labelMap()) == "News")
        await f.center.settleCorrections()
        let names = f.store.labelNames(of: role.id)
        #expect(names.contains("OpenHuman/News") && !names.contains("OpenHuman/Pitch"))
        #expect(undo.stack.count == before + 1, "one undo entry")
        let entry = try #require(try await f.index.entry(account: F.work, thread: role.id.gmailThreadID))
        #expect(entry.category == "News" && entry.source == .user && entry.rejected == ["Pitch"])
        let example = try #require(await f.env.classification.examples().first)
        #expect(example.expected == "news" && example.was == "pitch" && example.source == "correction")
        #expect(example.sender == Self.recruiter.email && example.senderDomain == "talent.example")
        await undo.undoLast()
        let back = f.store.labelNames(of: role.id)
        #expect(!back.contains("OpenHuman/News") && back.contains("OpenHuman/Pitch"))
    }

    @Test func labelAsWithGmailWritesOffChangesOnlyThisMacsAnswer() async throws {
        let f = F(writes: false, verdict: { _ in .pitch })
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: "A role for you.")
        await f.center.classifyRecent()
        let role = try await row(f, Self.roleSubject)
        let calls = f.recorder.calls.count
        #expect(try await f.center.setLabel("Travel", thread: role.id, row: role, labels: await f.labelMap()) == "Travel")
        await f.center.settleCorrections()
        #expect(f.recorder.calls.count == calls, "nothing reaches the mail port")
        #expect(try await f.index.entry(account: F.work, thread: role.id.gmailThreadID)?.category == "Travel")
        #expect(await f.env.classification.examples().count == 1)
    }

    @Test func notImportantIsOneUndoEntryAndTheFollowUpSavesNothingUntilTapped() async throws {
        let f = F(writes: true)
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: "A role for you.",
                               important: true)
        let role = try await row(f, Self.roleSubject)
        let rulesBefore = f.rules.allRules.count
        await perform(f, .classificationNotImportant, on: role)
        let undo = try #require(f.env.undo)
        #expect(undo.stack.count == 1)
        #expect(f.rules.allRules.count == rulesBefore + 1, "one conversation rule")
        #expect(f.rules.allRules.contains { $0.value == role.id.gmailThreadID.rawValue })
        #expect(try await !row(f, Self.roleSubject).isImportant, "Gmail's mark comes off in the same undo entry")
        let followUp = try #require(f.env.notices.toasts.first { $0.message == "Never important for:" })
        #expect(followUp.actionTitle == "This sender" && followUp.secondaryActionTitle == "This domain")
        #expect(f.rules.allRules.count == rulesBefore + 1, "nothing saved before a tap")
        await f.env.notices.activate(followUp.id)
        #expect(f.rules.allRules.contains { $0.value == Self.recruiter.email })
        #expect(undo.stack.count == 2, "the follow-up rule is its own undo entry")
        let example = try #require(await f.env.classification.examples().first)
        #expect(example.expected == "not_important" && example.was == "important")
        await undo.undoLast()
        await undo.undoLast()
        #expect(f.rules.allRules.count == rulesBefore)
        #expect(try await row(f, Self.roleSubject).isImportant, "one ⌘Z puts Gmail's mark back with the rule")
    }

    @Test func withTheSwitchOffNotImportantChangesOnlyThisMac() async throws {
        let f = F(writes: true)
        try await f.store.set(AppSettings.importanceSendsToGmail, false)
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: "A role for you.",
                               important: true)
        let role = try await row(f, Self.roleSubject)
        let sent = f.recorder.commands.count
        await perform(f, .classificationNotImportant, on: role)
        let undo = try #require(f.env.undo)
        #expect(undo.stack.count == 1)
        #expect(String(localized: try #require(undo.stack.last).title) == "Moved to Other on this Mac")
        #expect(f.recorder.commands.count == sent, "nothing reaches Gmail")
        #expect(try await row(f, Self.roleSubject).isImportant, "Gmail's mark stays")
        #expect(f.rules.allRules.contains { $0.value == role.id.gmailThreadID.rawValue && $0.effect == .neverImportant })
        await undo.undoLast()
        #expect(!f.rules.allRules.contains { $0.value == role.id.gmailThreadID.rawValue }, "one ⌘Z removes the rule")
        #expect(f.recorder.commands.count == sent)
    }

    @Test func markImportantAddsTheConversationRule() async throws {
        let f = F(writes: true)
        let target = try #require(try await f.inbox().first)
        await perform(f, .classificationMarkImportant, on: target)
        #expect(f.rules.allRules.contains { $0.value == target.id.gmailThreadID.rawValue && $0.effect == .important })
        #expect(f.env.notices.toasts.contains { $0.message == "Always important for:" })
    }

    @Test func theLabelFollowUpOffersTheListWhenThereIsOne() {
        let withList = ClassificationCorrectionHandler.labelRuleOptions(.news, sender: "ed@letters.example",
                                                                       domain: "letters.example", listID: "weekly.letters.example")
        #expect(withList.map(\.0) == ["This list", "This sender"])
        #expect(withList[0].1.when == .fact(.listID, "equals", .text("weekly.letters.example")))
        #expect(withList[0].1.then == .setLabel(.news) && withList[0].1.origin == .user)
        let plain = ClassificationCorrectionHandler.labelRuleOptions(.news, sender: "ed@letters.example",
                                                                    domain: "letters.example", listID: nil)
        #expect(plain.map(\.0) == ["This sender", "This domain"])
        #expect(plain[1].1.when == .fact(.sender, "domain", .text("letters.example")))
    }

    @Test func aFollowUpRuleIsSavedOnlyOnTheTapAndUndoesAlone() async throws {
        let f = F(writes: false, verdict: { _ in .pitch })
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: "A role for you.")
        await f.center.classifyRecent()
        let role = try await row(f, Self.roleSubject)
        await perform(f, .classificationSetLabel("news"), on: role)
        let followUp = try #require(f.env.notices.toasts.first { $0.message == "Always label News for:" })
        #expect(f.env.classification.config.rules.isEmpty, "nothing saved before a tap")
        await f.env.notices.activate(followUp.id)
        let rule = try #require(f.env.classification.config.rules.first)
        #expect(rule.when == .fact(.sender, "equals", .text(Self.recruiter.email)) && rule.then == .setLabel(.news))
        await f.env.undo?.undoLast()
        #expect(f.env.classification.config.rules.isEmpty)
    }

    @Test func makeARuleOpensTheEditorPrefilled() {
        let list = ClassificationCorrectionHandler.draft(sender: "ed@letters.example", listID: "weekly.letters.example",
                                                         label: .news)
        #expect(list.when == .all([.fact(.listID, "equals", .text("weekly.letters.example"))]))
        let sender = ClassificationCorrectionHandler.draft(sender: "ed@letters.example", listID: nil, label: nil)
        #expect(sender.when == .all([.fact(.sender, "equals", .text("ed@letters.example"))]) && sender.then == .setLabel(.news))
    }

    @Test func theCatalogHasOneEntryPerCorrectionWithNoKeys() throws {
        let entries = ActionCatalog.all.filter { $0.id.rawValue.hasPrefix("classification.") }
        let ids = entries.map(\.id)
        #expect(Set(ids).count == ids.count, "registered once in the catalog")
        #expect(ids.count == 3 + ActionID.classificationLabelCategories.count)
        #expect(entries.allSatisfy { $0.defaultBindings.isEmpty })
        #expect(Set(ClassificationCorrectionHandler.ids) == Set(ids))
        #expect(ActionID.classificationSetLabel("News").classificationSetLabelCategory == "news")
        #expect(ActionID.classificationNotImportant.classificationSetLabelCategory == nil)
    }
}
