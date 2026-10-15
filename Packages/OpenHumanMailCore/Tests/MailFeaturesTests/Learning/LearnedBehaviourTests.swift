import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

private let day: TimeInterval = 86_400
private let account = AccountID(1)

private func sender(_ address: String) -> LearnedSubject { LearnedSubject(account: account, kind: .sender, value: address) }
private func category(_ word: String) -> LearnedSubject { LearnedSubject(account: account, kind: .category, value: word) }

private func behaviour(_ events: [(TriageSignal, LearnedSubject, TimeInterval)]) -> LearnedBehaviour {
    var model = LearnedBehaviour()
    for (signal, subject, offset) in events { model.record(signal, for: subject, at: fixedNow.addingTimeInterval(offset)) }
    return model
}

@Suite struct LearnedBehaviourMathsTests {
    @Test func weightsHalveEveryThirtyDaysAndCountsStay() throws {
        let model = behaviour([(.archivedUnread, sender("Deals@Shop.example"), 0)])
        let later = try #require(model.tendency(for: sender("deals@shop.example"), at: fixedNow.addingTimeInterval(30 * day)))
        #expect(abs((later.weights[.archivedUnread] ?? 0) - 0.5) < 1e-9)
        #expect(later.counts[.archivedUnread] == 1)
        var again = model
        again.record(.archivedUnread, for: sender("deals@shop.example"), at: fixedNow.addingTimeInterval(30 * day))
        let both = try #require(again.tendency(for: sender("deals@shop.example"), at: fixedNow.addingTimeInterval(30 * day)))
        #expect(abs(both.totalWeight - 1.5) < 1e-9)
        #expect(both.totalCount == 2)
    }

    @Test func fiveUnreadArchivesMakeASenderSuggestionAndFourDoNot() {
        let five = behaviour((0..<5).map { (.archivedUnread, sender("deals@shop.example"), Double($0) * 60) })
        let four = behaviour((0..<4).map { (.archivedUnread, sender("deals@shop.example"), Double($0) * 60) })
        let now = fixedNow.addingTimeInterval(600)
        let found = five.suggestions(at: now)
        #expect(found.map(\.subject) == [sender("deals@shop.example")])
        #expect(found.first?.text.contains("5 of 5") == true)
        #expect(four.suggestions(at: now).isEmpty)
    }

    @Test func oneReplyOrReadingThemStopsTheSuggestion() {
        let now = fixedNow.addingTimeInterval(600)
        var withReply = (0..<6).map { (TriageSignal.archivedUnread, sender("a@news.example"), Double($0)) }
        withReply.append((.repliedLater, sender("a@news.example"), 7))
        #expect(behaviour(withReply).suggestions(at: now).isEmpty)
        var mostlyRead = (0..<4).map { (TriageSignal.archivedUnread, sender("b@news.example"), Double($0)) }
        mostlyRead += (0..<2).map { (TriageSignal.archivedRead, sender("b@news.example"), Double(10 + $0)) }
        #expect(behaviour(mostlyRead).suggestions(at: now).isEmpty)
    }

    @Test func oldHabitsFade() {
        let old = behaviour((0..<8).map { (.archivedUnread, sender("old@shop.example"), Double($0)) })
        #expect(!old.suggestions(at: fixedNow.addingTimeInterval(day)).isEmpty)
        #expect(old.suggestions(at: fixedNow.addingTimeInterval(60 * day)).isEmpty)
    }

    @Test func notNowHidesForThirtyDaysAndAcceptedOrCoveredNeverReturn() {
        var model = behaviour((0..<6).map { (.archivedUnread, sender("deals@shop.example"), Double($0)) })
        model.notNow[sender("deals@shop.example")] = fixedNow
        #expect(model.suggestions(at: fixedNow.addingTimeInterval(day)).isEmpty)
        let policy = LearnedSuggestionPolicy()
        for offset in 0..<6 { model.record(.archivedUnread, for: sender("deals@shop.example"),
                                           at: fixedNow.addingTimeInterval(31 * day + Double(offset))) }
        #expect(model.suggestions(at: fixedNow.addingTimeInterval(31 * day + 10), policy: policy).count == 1)
        #expect(model.suggestions(at: fixedNow.addingTimeInterval(31 * day + 10),
                                  covered: [sender("deals@shop.example")]).isEmpty)
        model.accepted.insert(sender("deals@shop.example"))
        #expect(model.suggestions(at: fixedNow.addingTimeInterval(31 * day + 10)).isEmpty)
    }

    @Test func aCategoryNeedsMoreEvidenceThanASender() {
        let nine = behaviour((0..<9).map { (.archivedUnread, category("Marketing"), Double($0)) })
        #expect(nine.suggestions(at: fixedNow.addingTimeInterval(60)).isEmpty)
        let ten = behaviour((0..<10).map { (.archivedUnread, category("Marketing"), Double($0)) })
        let found = ten.suggestions(at: fixedNow.addingTimeInterval(60))
        #expect(found.map(\.subject) == [category("Marketing")])
        #expect(found.first?.text.contains("Move Marketing mail to Other?") == true)
    }

    @Test func theAgreementReportComparesCategoriesWithActions() throws {
        var events: [(TriageSignal, LearnedSubject, TimeInterval)] = []
        events += [(.repliedQuickly, category("Respond"), 0), (.repliedLater, category("Respond"), 1),
                   (.starred, category("Respond"), 2), (.archivedUnread, category("Respond"), 3)]
        events += [(.archivedUnread, category("Marketing"), 4), (.muted, category("Marketing"), 5)]
        events += [(.archivedUnread, sender("x@shop.example"), 6)]
        let report = ClassifierAgreementReport.make(from: behaviour(events))
        #expect(report.rows.map(\.category) == ["Marketing", "Respond"])
        let respond = try #require(report.rows.first { $0.category == "Respond" })
        #expect(respond.agreeing == 3 && respond.disagreeing == 1)
        #expect(respond.text == "75% agree (3 of 4)")
        let marketing = try #require(report.rows.first { $0.category == "Marketing" })
        #expect(marketing.agreement == nil)
    }

    @Test func itRoundTripsAndForgetsAnAccount() throws {
        var model = behaviour([(.starred, sender("a@b.example"), 0), (.muted, category("News"), 1)])
        model.notNow[sender("a@b.example")] = fixedNow
        let decoded = try JSONDecoder().decode(LearnedBehaviour.self, from: JSONEncoder().encode(model))
        #expect(decoded == model)
        model.forget(account: account)
        #expect(model.isEmpty && model.notNow.isEmpty)
    }
}

@MainActor
@Suite struct LearnedBehaviourCenterTests {
    private struct Fixture {
        let store: FakeMailStore
        let rules: FakeImportanceRules
        let saved: InMemoryLearnedBehaviourStore
        let env: AppEnvironment
        let center: LearnedBehaviourCenter
        let thread: ThreadKey
    }

    private func fixture() async throws -> Fixture {
        let store = FakeMailStore(corpus: .rich(threadCount: 20, now: fixedNow),
                                  options: .init(remoteAck: .immediate, heldSends: .manual, now: { fixedNow }))
        let rules = FakeImportanceRules(corpus: nil, now: { fixedNow })
        let saved = InMemoryLearnedBehaviourStore()
        let env = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: true,
                                 importance: rules, learnedBehaviourStore: saved)
        let center = LearnedBehaviourCenter(environment: env, store: saved, now: { fixedNow })
        await center.start()
        let row = try #require(try await store.threadPage(.system(.inbox), account: account, after: nil, limit: 50).rows.first)
        return Fixture(store: store, rules: rules, saved: saved, env: env, center: center, thread: row.id)
    }

    private func archive(_ f: Fixture, unread: Bool) -> ActionContext {
        ActionContext(scope: .list, account: account, selection: [f.thread], targets: TargetState(anyUnread: unread))
    }

    @Test func itIsOffByDefaultAndRecordsNothingThen() async throws {
        let f = try await fixture()
        #expect(f.center.isOn == false)
        f.center.observe(.markDone, context: archive(f, unread: true))
        await f.center.settle()
        #expect(f.center.behaviour.isEmpty)
        #expect(f.center.suggestions.isEmpty)
    }

    @Test func whenOnItRecordsArchivesAndSuggestsMovingTheSenderToOther() async throws {
        let f = try await fixture()
        await f.center.setOn(true)
        for _ in 0..<5 { f.center.observe(.markDone, context: archive(f, unread: true)) }
        f.center.observe(.toggleStar, context: ActionContext(account: account, selection: [f.thread],
                                                             targets: TargetState(allStarred: true)))
        await f.center.settle()
        let senders = f.center.behaviour.tendencies.filter { $0.key.kind == .sender }
        #expect(senders.count == 1)
        #expect(senders.first?.value.counts == [.archivedUnread: 5])
        let suggestion = try #require(f.center.suggestions.first)
        #expect(f.center.bannerSuggestion(account: account) == suggestion)
        #expect(f.center.bannerSuggestion(account: AccountID(99)) == nil)

        #expect(await f.center.accept(suggestion))
        let rules = await AIThreadLoader.first(f.rules.rules(account)) ?? []
        #expect(rules.contains { $0.kind == .neverSender && $0.value == suggestion.subject.value })
        #expect(f.env.undo?.nextUndo != nil)
        #expect(f.center.suggestions.isEmpty)
        #expect(await f.saved.load()?.accepted.contains(suggestion.subject) == true)
    }

    @Test func notNowAndResetAndTheSwitch() async throws {
        let f = try await fixture()
        await f.center.setOn(true)
        for _ in 0..<5 { f.center.observe(.markDone, context: archive(f, unread: true)) }
        await f.center.settle()
        let suggestion = try #require(f.center.suggestions.first)
        await f.center.notNow(suggestion)
        #expect(f.center.suggestions.isEmpty)
        await f.center.reset()
        #expect(f.center.behaviour.isEmpty && f.center.observationCount == 0)
        #expect(await f.saved.load() == nil)
        await f.center.setOn(false)
        #expect((try? await f.store.get(AppSettings.learnFromActions)) == false)
        f.center.observe(.markDone, context: archive(f, unread: true))
        await f.center.settle()
        #expect(f.center.behaviour.isEmpty)
    }

    @Test func readArchivesAndRepliesAreTold() async throws {
        let f = try await fixture()
        await f.center.setOn(true)
        f.center.observe(.markDone, context: archive(f, unread: false))
        f.center.observe(.reply, context: ActionContext(account: account, selection: [f.thread]))
        f.center.observe(.aiReplyOptions, context: ActionContext(account: account, selection: [f.thread]))
        await f.center.settle()
        let counts = f.center.behaviour.tendencies.filter { $0.key.kind == .sender }.first?.value.counts ?? [:]
        #expect(counts[.archivedRead] == 1)
        #expect((counts[.repliedQuickly] ?? 0) + (counts[.repliedLater] ?? 0) == 1)
        #expect(f.center.observationCount == 2)
    }
}
