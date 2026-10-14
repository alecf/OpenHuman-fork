import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

private let planJSON =
    #"{"keywords":["invoice"],"from":["Sarah"],"to":[],"timeframe":"lastMonth","mailbox":"any","topic":"invoices from Sarah"}"#

@Suite struct SearchPlanFeatureTests {
    @Test func theOnDeviceModelSeesTheWordsAndTheDateOnly() async throws {
        let provider = ScriptedProvider(id: .appleSystem, responses: [.text(planJSON)])
        let result = try await makeFeatures([provider]).planSearch("invoices from Sarah last month", accountKey: "work")
        #expect(result.plan.keywords == ["invoice"])
        #expect(result.plan.from == ["Sarah"])
        #expect(result.plan.timeframe == .lastMonth)
        #expect(result.plan.topic == "invoices from Sarah")
        #expect(result.provenance.providerID == .appleSystem)
        #expect(result.provenance.dataLocation == .onDevice)
        #expect(!result.report.suspicious)

        let request = try #require(provider.requests.first)
        #expect(request.task == .searchPlan)
        #expect(request.promptID == PromptID("search.plan", version: 3))
        #expect(request.untrusted.isEmpty)
        #expect(request.trusted.map(\.kind) == [.userQuestion, .today])
        #expect(request.trusted.first?.text == "invoices from Sarah last month")
        #expect(request.output.schema == OutputGuard.searchPlanSchema)
        #expect(request.output.maxTokens == AIPolicy.reservedSearchPlanTokens)
        #expect(RequestInspector.problems(in: request).isEmpty)
        let today = request.trusted[1].text.components(separatedBy: ", ")
        #expect(today.count == 3)
        #expect(today.first?.count == 10)
        #expect(today.last == TimeZone.current.identifier)
    }

    @Test func longTextIsCutAndEmptyTextRefused() async throws {
        let provider = ScriptedProvider(id: .appleSystem, responses: [.text(planJSON)])
        _ = try await makeFeatures([provider]).planSearch(String(repeating: "word ", count: 200), accountKey: nil)
        #expect(provider.requests.first?.trusted.first?.text.count == AIPolicy.searchQuestionCharacterCap)
        let empty = await aiError { _ = try await makeFeatures([provider]).planSearch("   ", accountKey: nil) }
        #expect(empty == .invalidOutput("empty search"))
    }

    @Test func anInvalidAnswerIsRepairedOnceThenRefused() async throws {
        let repaired = ScriptedProvider(id: .appleSystem, responses: [
            .text(#"{"keywords":[],"timeframe":"lastDecade","mailbox":"any"}"#), .text(planJSON),
        ])
        let result = try await makeFeatures([repaired]).planSearch("invoices from Sarah last month", accountKey: nil)
        #expect(result.plan.timeframe == .lastMonth)
        #expect(repaired.requests.count == 2)
        #expect(repaired.requests[1].system.contains("Your previous answer was not valid"))

        let broken = ScriptedProvider(id: .appleSystem, responses: [
            .text(#"{"keywords":[],"timeframe":"pastDays","mailbox":"any"}"#),
            .text(#"{"keywords":["a","b","c","d","e","f","g"],"timeframe":"none","mailbox":"any"}"#),
        ])
        let error = await aiError { _ = try await makeFeatures([broken]).planSearch("mail from the past few days", accountKey: nil) }
        guard case .invalidOutput? = error else {
            Issue.record("expected invalidOutput, got \(String(describing: error))")
            return
        }
        #expect(broken.requests.count == 2)
    }

    @Test func itNeverLeavesTheMacPinnedOrNot() async throws {
        let pcc = FakeAIProvider(id: .applePCC, capabilities: .fake(dataLocation: .appleCloud))
        let claude = FakeAIProvider(id: .agentClaude, capabilities: remoteCapabilities())
        var settings = consenting([.applePCC, .agentClaude], AISettings(pccEnabled: true))
        let text = "invoices from Sarah last month"
        #expect(await aiError { _ = try await makeFeatures([pcc, claude], settings: settings).planSearch(text, accountKey: nil) }
                == .unavailable(.onDeviceOnly))
        for pin in [AIProviderID.applePCC, .agentClaude] {
            settings.featurePins[.searchPlan] = pin
            #expect(await aiError { _ = try await makeFeatures([pcc, claude], settings: settings).planSearch(text, accountKey: nil) }
                    == .unavailable(.onDeviceOnly))
        }
        settings.featurePins = [:]
        settings.providerOrder = [.applePCC, .agentClaude, .appleSystem]
        let local = ScriptedProvider(id: .appleSystem, responses: [.text(planJSON)])
        let result = try await makeFeatures([pcc, claude, local], settings: settings).planSearch(text, accountKey: nil)
        #expect(result.provenance.providerID == .appleSystem)
        #expect(ProviderSelectionPolicy.workload(for: .searchPlan, trigger: .user) == .background)
    }

    @Test func theSettingsSwitchItOff() async {
        let provider = ScriptedProvider(id: .appleSystem, responses: [.text(planJSON), .text(planJSON)])
        var settings = AISettings()
        settings.smartSearch.understandSentences = false
        #expect(await aiError { _ = try await makeFeatures([provider], settings: settings).planSearch("a b c", accountKey: nil) }
                == .unavailable(.disabledBySettings))
        #expect(await aiError { _ = try await makeFeatures([provider], settings: AISettings(enabled: false)).planSearch("a b c", accountKey: nil) }
                == .unavailable(.disabledBySettings))
        #expect(provider.requests.isEmpty)
    }

    @Test func theFakeScriptAnswersWithAValidPlan() async throws {
        let result = try await makeFeatures([FakeAIProvider(id: .appleSystem)]).planSearch("Receipts from last week", accountKey: nil)
        #expect(result.plan.keywords == ["receipts"])
    }
}

@Suite struct SearchPlanGuardTests {
    private func plan(_ json: String) throws -> SearchPlan { try OutputGuard.searchPlan(from: Data(json.utf8)) }

    @Test func nullsReadAsAbsentAndValuesAreCleaned() throws {
        let cleaned = try plan(#"{"keywords":[" invoice ",""],"from":["Sarah"],"to":null,"timeframe":"pastDays","count":7,"mailbox":"any","label":" ","topic":"one two three four five six seven eight nine ten eleven twelve thirteen","unread":null}"#)
        #expect(cleaned.keywords == ["invoice"])
        #expect(cleaned.to == [])
        #expect(cleaned.count == 7)
        #expect(cleaned.unread == nil)
        #expect(cleaned.label == nil)
        #expect(cleaned.topic?.split(separator: " ").count == AIPolicy.searchPlanTopicWords)
        let minimal = try plan(#"{"keywords":[],"timeframe":"none","mailbox":"inbox"}"#)
        #expect(minimal.mailbox == .inbox)
        #expect(minimal.from.isEmpty)
    }

    @Test func badEnumsRangesAndCapsAreRejected() {
        let bad = [
            #"{"keywords":[],"timeframe":"month","month":13,"mailbox":"any"}"#,
            #"{"keywords":[],"timeframe":"year","year":1999,"mailbox":"any"}"#,
            #"{"keywords":[],"timeframe":"none","attachment":"zip","mailbox":"any"}"#,
            #"{"keywords":[],"timeframe":"none","mailbox":"spam"}"#,
            #"{"keywords":[],"timeframe":"pastWeeks","mailbox":"any"}"#,
            #"{"keywords":[],"timeframe":"sinceMonth","year":2026,"mailbox":"any"}"#,
            #"{"keywords":[],"timeframe":"none","mailbox":"any","query":"from:x"}"#,
            #"{"keywords":["1","2","3","4","5","6","7"],"timeframe":"none","mailbox":"any"}"#,
            #"{"keywords":[],"from":["a","b","c","d"],"timeframe":"none","mailbox":"any"}"#,
            #"{"keywords":[],"timeframe":"none"}"#,
            #"["not an object"]"#,
            "nonsense",
        ]
        for json in bad {
            #expect(throws: AIError.self, "\(json)") { try plan(json) }
        }
    }

    @Test func everyEnumValueIsInTheSchema() throws {
        for timeframe in SearchPlan.Timeframe.allCases {
            var fields = #""timeframe":"\#(timeframe.rawValue)""#
            if timeframe.needsCount { fields += #","count":2"# }
            if [.month, .sinceMonth, .beforeMonth].contains(timeframe) { fields += #","month":3"# }
            if timeframe == .year { fields += #","year":2025"# }
            #expect(try plan(#"{"keywords":[],"mailbox":"any","# + fields + "}").timeframe == timeframe)
        }
        for attachment in SearchPlan.AttachmentType.allCases {
            #expect(try plan(#"{"keywords":[],"timeframe":"none","mailbox":"any","attachment":""# + attachment.rawValue + #""}"#)
                .attachment == attachment)
        }
    }

    @Test func emptyPlansAreRecognized() {
        #expect(SearchPlan().isEmpty)
        #expect(!SearchPlan(keywords: ["x"]).isEmpty)
        #expect(!SearchPlan(unread: true).isEmpty)
        #expect(SearchPlan(unread: false).isEmpty)
    }
}
