import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct MailSearchToolBackendTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func backend(_ source: AskTestSource, accounts: [AccountID]? = nil) -> MailSearchToolBackend {
        MailSearchToolBackend(data: source, accounts: accounts, calendar: calendar, now: { fixedNow })
    }

    private func source() -> AskTestSource {
        AskTestSource(FakeMailStore(corpus: .rich(threadCount: 60, now: fixedNow),
                                    options: .init(remoteAck: .immediate, now: { fixedNow })))
    }

    @Test func theQueryHasNoOperatorsFromTheModelAndTheWindowIsADate() {
        let tool = backend(source())
        let query = tool.storeQuery(AISearchToolQuery(keywords: ["invoice", "label:secret", "in:trash", "OR", "x\"y"],
                                                      sender: "Sam \"Sample\": evil", withinDays: 7))
        #expect(query == "invoice labelsecret intrash xy from:\"Sam Sample evil\" after:\(dateString(daysBack: 7))")
        #expect(tool.storeQuery(AISearchToolQuery(keywords: [], sender: "", withinDays: 0)) == nil)
        #expect(tool.storeQuery(AISearchToolQuery(keywords: ["OR", "and"])) == nil)
    }

    private func dateString(daysBack: Int) -> String {
        let day = calendar.date(byAdding: .day, value: -daysBack, to: fixedNow)!
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!)
    }

    @Test func hitsComeFromTheLocalSearchWithOpaqueIdsThatMapBack() async throws {
        let source = source()
        let work = AskFixture.work
        let tool = backend(source, accounts: [work])
        let hits = try await tool.search(AISearchToolQuery(keywords: ["offsite"]))
        #expect(!hits.isEmpty && hits.count <= AIPolicy.searchToolMaxHits)
        #expect(source.searches.map(\.query) == ["offsite"])
        #expect(source.searches.first?.accounts == [work], "scoped to the chosen account")
        #expect(source.searches.first?.semanticText == nil)
        for hit in hits {
            #expect(hit.id.hasPrefix("t") && !hit.subject.isEmpty)
            #expect(!hit.snippet.contains("\u{2}") && !hit.snippet.contains("\u{3}"), "match marks are removed")
            let key = try #require(tool.thread(for: hit.id))
            #expect(key.account == work)
        }
        #expect(tool.thread(for: "t99-99") == nil)
        #expect(try await tool.search(AISearchToolQuery(keywords: [])) == [])
        #expect(source.searches.count == 1, "an empty query never reaches the store")
    }

    @Test func theFeatureRunsTheModelsSearchOverTheStoreAndNothingChanges() async throws {
        let source = source()
        let tool = backend(source, accounts: [AskFixture.work])
        let provider = FakeSearchToolProvider(calls: [AISearchToolQuery(keywords: ["offsite"])],
                                              answer: "Two conversations match.")
        let features = DefaultAIFeatures(registry: ProviderRegistry(providers: [provider]), settings: { AISettings() },
                                         cache: InMemoryAIResultCache(), activity: nil, now: { fixedNow })
        let result = try await features.searchWithTool("offsite mail", accountKey: nil, backend: tool)
        #expect(result.summary == "Two conversations match.")
        #expect(!result.hits.isEmpty)
        #expect(result.hits.allSatisfy { tool.thread(for: $0.id) != nil })
        #expect(source.searches.count == 1)
        #expect(provider.toolOutputs.first?.contains("<email_data") == true)
    }

    @Test func withTheModelUnavailableNoSearchRuns() async throws {
        let source = source()
        let provider = FakeSearchToolProvider(availability: .unavailable(reason: .modelNotReady), calls: [AISearchToolQuery(keywords: ["offsite"])])
        let features = DefaultAIFeatures(registry: ProviderRegistry(providers: [provider]), settings: { AISettings() },
                                         cache: InMemoryAIResultCache(), activity: nil, now: { fixedNow })
        do {
            _ = try await features.searchWithTool("offsite", accountKey: nil, backend: backend(source))
            Issue.record("should be unavailable")
        } catch let error as AIError {
            guard case .unavailable = error else { Issue.record("wrong error \(error)"); return }
        }
        #expect(source.searches.isEmpty)
    }
}
