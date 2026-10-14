import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private final class AskedLog: Sendable {
    private let state = Mutex<[String]>([])
    func record(_ text: String) { state.withLock { $0.append(text) } }
    var asked: [String] { state.withLock { $0 } }
}

@MainActor
private func planner(enabled: Bool = true, available: Bool = true, log: AskedLog,
                     answer: @escaping @Sendable (String) throws -> SearchPlan) -> SearchPlanAskPlanner {
    let source = SearchPlanSource(isEnabled: { enabled }, isModelAvailable: { _ in available },
                                  plan: { text, _ in
                                      log.record(text)
                                      return try answer(text)
                                  })
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return SearchPlanAskPlanner(
        source: source,
        context: { account in
            SearchInterpretation.Context(account: account, accountKey: "work", labels: [], contacts: { _ in [] })
        },
        resolver: SearchPlanResolver(calendar: calendar, locale: Locale(identifier: "en_US_POSIX")),
        now: { Date(timeIntervalSince1970: 1_791_720_000) })
}

@MainActor
@Suite struct AskSearchPlannerTests {
    private let question = "what did the venue say about the offsite budget last week?"

    @Test func theResolvedPlanBecomesTheAskPlanAndThePlannerSeesOnlyTheQuestion() async {
        let log = AskedLog()
        let subject = planner(log: log) { _ in SearchPlan(keywords: ["offsite", "budget"], timeframe: .lastWeek) }
        let plan = await subject.plan("  \(question) ", account: AccountID(1))
        #expect(log.asked == [question], "the trimmed question and nothing else")
        let resolved = try? #require(plan)
        #expect(resolved?.query.contains("offsite") == true)
        #expect(resolved?.query.contains("budget") == true)
        #expect(resolved?.chips.contains("offsite") == true)
    }

    @Test func nothingIsPlannedForAllAccountsOrWithTheGateOffOrNoModel() async {
        let log = AskedLog()
        let answer: @Sendable (String) throws -> SearchPlan = { _ in SearchPlan(keywords: ["offsite"]) }
        #expect(await planner(log: log, answer: answer).plan(question, account: nil) == nil)
        #expect(await planner(enabled: false, log: log, answer: answer).plan(question, account: AccountID(1)) == nil)
        #expect(await planner(available: false, log: log, answer: answer).plan(question, account: AccountID(1)) == nil)
        #expect(log.asked.isEmpty, "the planner was never asked")
    }

    @Test func aFailedOrEmptyPlanMeansNoPlan() async {
        let log = AskedLog()
        struct Refused: Error {}
        #expect(await planner(log: log) { _ in throw Refused() }.plan(question, account: AccountID(1)) == nil)
        #expect(await planner(log: log) { _ in SearchPlan() }.plan(question, account: AccountID(1)) == nil)
    }
}
