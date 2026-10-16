import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct ClassificationRulesCenterTests {
    typealias F = AutoLabelFixture

    static let service = EmailAddress(name: "Build Service", email: "noreply@builds.example")
    static let client = EmailAddress(name: "Lee Park", email: "lee@client.example")
    static let bulkSubject = "Your nightly build finished"
    static let bulkText = "Build 412 passed. Download the artifacts within 7 days."

    func row(_ f: F, _ subject: String) async throws -> ThreadRow {
        try #require(try await f.inbox().first { $0.subject == subject })
    }

    func decisions(_ f: F) async -> [ClassificationDecision] {
        (try? await f.index.decisions(limit: 10_000)) ?? []
    }

    @Test func oneRowPerFreshDecisionAndNoneForACacheHit() async throws {
        let f = F(writes: false)
        let sorted = await f.center.classifyRecent()
        let first = await decisions(f)
        let fresh = try await f.index.entries(account: F.work).count + f.index.entries(account: F.personal).count
        #expect(sorted > 0 && first.count == fresh && fresh > 0)
        #expect(first.contains { $0.decidedBy == "model" && $0.providerID == "fake.autolabels" && $0.modelID == "classifier-1"
            && $0.promptID == "autolabel.classify" && $0.modelOutput == "Marketing" })
        #expect(first.contains { $0.decidedBy == "rule" && $0.ruleID == DefaultRules.waiting && $0.outputLabel == "waiting" })
        #expect(first.allSatisfy { $0.appliedState == .localOnly && $0.ruleSetVersion == 1 })
        await f.center.classifyRecent()
        #expect(await decisions(f).count == first.count)
    }

    @Test func writtenAnswersStartPendingUntilGmailConfirms() async throws {
        let f = F(writes: true)
        await f.center.classifyRecent()
        let rows = await decisions(f)
        #expect(rows.contains { $0.appliedState == .pending })
        let model = try #require(rows.first { $0.decidedBy == "model" })
        let entry = try #require(try await f.index.entry(account: model.account, thread: model.thread))
        try await f.index.setApplied(account: entry.account, thread: entry.thread, latestMessage: entry.latestMessage,
                                     state: .written, label: "marketing")
        #expect(try await f.index.latestDecision(account: entry.account, thread: entry.thread)?.appliedState == .written)
    }

    @Test func switchingTheBulkRuleOffAndOnReResolvesWithoutAskingTheModelAgain() async throws {
        let f = F(writes: false, verdict: { _ in .respond })
        f.store.deliverMessage(account: F.work, from: Self.service, subject: Self.bulkSubject, text: Self.bulkText)
        await f.center.classifyRecent()
        let bulk = try await row(f, Self.bulkSubject)
        let before = try #require(try await f.index.entry(account: F.work, thread: bulk.id.gmailThreadID))
        #expect(before.category == nil && before.modelOutput == "Respond", "bulk mail is never Respond")
        let calls = f.center.modelCalls
        #expect(await f.env.classification.setDefault(DefaultRules.bulkNeverRespond, enabled: false))
        await f.center.classifyRecent()
        #expect(try await f.index.entry(account: F.work, thread: bulk.id.gmailThreadID)?.category == "Respond")
        #expect(await f.env.classification.setDefault(DefaultRules.bulkNeverRespond, enabled: true))
        await f.center.classifyRecent()
        #expect(try await f.index.entry(account: F.work, thread: bulk.id.gmailThreadID)?.category == nil)
        #expect(f.center.modelCalls == calls, "a rule change re-resolves the cached answer")
        let logged = await decisions(f).filter { $0.thread == bulk.id.gmailThreadID }
        #expect(logged.count == 3 && logged.map(\.ruleSetVersion) == [3, 2, 1])
        #expect(logged.last?.constraintsJSON?.contains(DefaultRules.bulkNeverRespond) == true)
    }

    @Test func aUserRuleBeatsTheModelAndTheLogNamesIt() async throws {
        let f = F(writes: false, verdict: { _ in .respond })
        f.store.deliverMessage(account: F.work, from: Self.client, subject: "Flights for the offsite", text: "Here are the options.")
        let rule = ClassificationRule(id: "user.client-travel", title: "Mail from the client is Travel",
                                      when: .fact(.sender, "domain", .text("client.example")), then: .setLabel(.travel))
        #expect(await f.env.classification.add(rule))
        await f.center.classifyRecent()
        let thread = try await row(f, "Flights for the offsite")
        let entry = try #require(try await f.index.entry(account: F.work, thread: thread.id.gmailThreadID))
        #expect(entry.category == "Travel" && entry.source == .derived && entry.ruleID == "user.client-travel")
        #expect(entry.modelID == f.env.classification.config.rulesModelID && entry.modelID != "rules@1")
        #expect(!f.log.all.contains(AIThreadLoader.threadKey(thread.id)), "the model is never asked")
        let logged = try #require(try await f.index.latestDecision(account: F.work, thread: thread.id.gmailThreadID))
        #expect(logged.decidedBy == "rule" && logged.ruleID == "user.client-travel" && logged.outputLabel == "travel")
        let undo = try #require(f.env.undo)
        await undo.undoLast()
        #expect(f.env.classification.config.rules.isEmpty && f.env.classification.version == 3)
        await f.center.classifyRecent()
        #expect(try await f.index.entry(account: F.work, thread: thread.id.gmailThreadID)?.category == "Respond")
    }

    @Test func noEmailTextIsKeptUnlessAsked() async throws {
        let subject = "Quarterly plan for the orchard project"
        let text = "Attached is the orchard planting schedule for spring."
        let f = F(writes: false, verdict: { _ in .respond })
        f.store.deliverMessage(account: F.work, from: Self.client, subject: subject, text: text)
        await f.center.classifyRecent()
        let thread = try await row(f, subject)
        _ = try await f.center.setLabel("Invoice", thread: thread.id, row: thread, labels: await f.labelMap())
        await f.center.settleCorrections()
        let rows = await decisions(f)
        let examples = await f.env.classification.examples()
        #expect(!rows.isEmpty && examples.count == 1)
        let stored = rows.map { [$0.featuresJSON, $0.constraintsJSON ?? "", $0.textJSON ?? "", $0.modelOutput ?? ""] }.flatMap { $0 }
            + examples.map { [$0.featuresJSON, $0.textJSON ?? ""] }.flatMap { $0 }
        for word in ["orchard", "Quarterly", "planting", Self.client.email] {
            #expect(!stored.contains { $0.contains(word) }, "\(word) is not stored")
        }
        #expect(rows.allSatisfy { $0.textJSON == nil } && examples.allSatisfy { $0.textJSON == nil })
        #expect(examples[0].expected == "invoice" && examples[0].was == "respond" && examples[0].senderDomain == "client.example")
        try await f.store.set(AppSettings.classificationKeepInputText, true)
        f.store.deliverMessage(account: F.work, from: Self.client, subject: "Orchard invoice", text: "The orchard invoice is due.")
        await f.center.classifyRecent()
        let kept = try await row(f, "Orchard invoice")
        let latest = try #require(try await f.index.latestDecision(account: F.work, thread: kept.id.gmailThreadID))
        #expect(latest.textJSON?.contains("Orchard invoice") == true)
    }

    @Test func theLogIsBoundedByRowsAndDaysAndClears() async throws {
        let log = InMemoryAutoLabelStore()
        func row(_ n: Int, _ at: Date) -> ClassificationDecision {
            ClassificationDecision(account: F.work, thread: GmailThreadID("t\(n)"), latestMessage: GmailMessageID("m\(n)"),
                                   decidedAt: at, decidedBy: "model")
        }
        let now = fixedNow
        try await log.appendDecisions([row(1, now.addingTimeInterval(-200 * 86_400)), row(2, now), row(3, now)], now: now,
                                      maxRows: 100, maxDays: 180)
        #expect(try await log.decisionCount() == 2, "older than 180 days goes")
        try await log.appendDecisions([row(4, now), row(5, now)], now: now, maxRows: 3, maxDays: 180)
        #expect(try await log.decisions(limit: 10).map(\.thread.rawValue) == ["t5", "t4", "t3"])
        try await log.removeAllDecisions()
        #expect(try await log.decisionCount() == 0)
    }

    @Test func theDecisionLogSwitchStopsLogging() async throws {
        let f = F(writes: false)
        try await f.store.set(AppSettings.classificationDecisionLogEnabled, false)
        await f.center.classifyRecent()
        #expect(await decisions(f).isEmpty)
        #expect(try await f.index.entries(account: F.work).count > 0, "sorting goes on")
    }
}
