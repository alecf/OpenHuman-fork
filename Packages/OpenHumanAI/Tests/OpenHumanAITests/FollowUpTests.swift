import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

private let yes = #"{"needsFollowUp":true,"reason":"Asked for the signed contract","suggestedDays":null}"#
private let no = #"{"needsFollowUp":false,"reason":"Only says thanks","suggestedDays":null}"#

private func input(_ text: String = "Could you send the signed contract by Friday?", key: String = "1.m-sent",
                   context: [AIMessageInput] = []) -> FollowUpInput {
    FollowUpInput(messageKey: key, threadKey: "1.t-1", subject: "Contract", from: "Sam Lee <sam@work.example> (the user)",
                  text: text, sentAt: fixedNow, context: context, accountKey: "work")
}

private func earlier(_ index: Int, _ text: String = "Here is the draft.") -> AIMessageInput {
    AIMessageInput(messageKey: "1.m-\(index)", from: "Dana Ruiz <dana@else.example>",
                   date: fixedNow.addingTimeInterval(Double(index - 10) * 3_600), bodyText: text)
}

@Suite struct FollowUpFeatureTests {
    @Test func aRequestIsJudgedOnThisMacWithEverythingDelimited() async throws {
        let provider = ScriptedProvider(id: .appleSystem, responses: [.text(yes)])
        let result = try await makeFeatures([provider]).detectFollowUp(input(context: (1...5).map { earlier($0) }))
        #expect(result.needsFollowUp)
        #expect(result.reason == "Asked for the signed contract")
        #expect(result.suggestedDays == nil)
        #expect(result.providerID == .appleSystem)
        #expect(!result.fromCache)

        let request = try #require(provider.requests.first)
        #expect(request.task == .followUp)
        #expect(request.promptID == PromptID("followup.detect", version: 2))
        #expect(request.output.schema == OutputGuard.followUpSchema)
        #expect(request.output.maxTokens == AIPolicy.reservedFollowUpTokens)
        #expect(request.trusted.isEmpty, "everything about the mail is email data")
        #expect(request.untrusted.map(\.kind) == [.subject, .sender, .emailBody, .sender, .emailBody, .sender, .emailBody,
                                                 .sender, .emailBody])
        #expect(request.untrusted.compactMap { $0.kind == .emailBody ? $0.id : nil } == ["1.m-3", "1.m-4", "1.m-5", "1.m-sent"])
        #expect(request.untrusted.last?.text == "Could you send the signed contract by Friday?")
        #expect(request.untrusted.last?.date == fixedNow)
        #expect(RequestInspector.problems(in: request).isEmpty)
        #expect(request.system.contains("Judge only the message the user sent"))
    }

    @Test func thanksAndFYIAreNo() async throws {
        let provider = ScriptedProvider(id: .appleSystem, responses: [.text(no), .text(#"{"needsFollowUp":false,"reason":"Shares information only"}"#)])
        let features = makeFeatures([provider])
        let thanks = try await features.detectFollowUp(input("Thanks, got it!", key: "1.m-a"))
        let fyi = try await features.detectFollowUp(input("FYI: the office is closed Monday.", key: "1.m-b"))
        #expect(!thanks.needsFollowUp && thanks.reason == "Only says thanks")
        #expect(!fyi.needsFollowUp && fyi.suggestedDays == nil)
    }

    @Test func anEmptyMessageAsksNothing() async throws {
        let provider = ScriptedProvider(id: .appleSystem, responses: [.text(yes)])
        let result = try await makeFeatures([provider]).detectFollowUp(input("  \n "))
        #expect(result == .no)
        #expect(provider.requests.isEmpty)
    }

    @Test func malformedJSONIsRepairedOnceThenRefused() async throws {
        let repaired = ScriptedProvider(id: .appleSystem, responses: [.text("Yes, it needs one."), .text(yes)])
        #expect(try await makeFeatures([repaired]).detectFollowUp(input()).needsFollowUp)
        #expect(repaired.requests.count == 2)
        #expect(repaired.requests[1].system.contains("Your previous answer was not valid"))

        let broken = ScriptedProvider(id: .appleSystem, responses: [
            .text(#"{"needsFollowUp":"yes","reason":"x"}"#), .text(#"{"needsFollowUp":true,"reason":"x","suggestedDays":30}"#),
        ])
        let error = await aiError { _ = try await makeFeatures([broken]).detectFollowUp(input()) }
        guard case .invalidOutput? = error else {
            Issue.record("expected invalidOutput, got \(String(describing: error))")
            return
        }
    }

    @Test func theAnswerIsCachedByMessageIdAndPromptVersion() async throws {
        let cache = InMemoryAIResultCache()
        let provider = ScriptedProvider(id: .appleSystem, responses: [.text(yes), .text(no), .text(no)])
        let features = makeFeatures([provider], cache: cache)
        _ = try await features.detectFollowUp(input())
        let again = try await features.detectFollowUp(input(context: [earlier(1, "A reply arrived")]))
        #expect(again.needsFollowUp && again.fromCache)
        #expect(provider.requests.count == 1)
        let other = try await features.detectFollowUp(input(key: "1.m-other"))
        #expect(!other.needsFollowUp && !other.fromCache)
        #expect(provider.requests.count == 2)

        var templates = PromptLibrary.standard.templates
        let current = try #require(templates[PromptName.followUp.rawValue])
        templates[PromptName.followUp.rawValue] = PromptTemplate(id: PromptID(current.id.name, version: 3), body: current.body)
        let bumped = DefaultAIFeatures(registry: ProviderRegistry(providers: [provider]), settings: { AISettings() },
                                       cache: cache, prompts: PromptLibrary(templates: templates), now: { fixedNow })
        let fresh = try await bumped.detectFollowUp(input())
        #expect(!fresh.fromCache && !fresh.needsFollowUp)
        #expect(provider.requests.count == 3)
        #expect(provider.requests.last?.promptID == PromptID("followup.detect", version: 3))
    }

    @Test func aSuspiciousAnswerIsNoAndNotCached() async throws {
        let nonce = "Nn0Nn0Nn0Nn0"
        let echo = #"{"needsFollowUp":true,"reason":"see email_data block","suggestedDays":2}"#
        let provider = ScriptedProvider(id: .appleSystem, responses: [.text(echo), .text(yes)])
        let features = DefaultAIFeatures(registry: ProviderRegistry(providers: [provider]), settings: { AISettings() },
                                         now: { fixedNow }, makeNonce: { nonce })
        let first = try await features.detectFollowUp(input())
        #expect(!first.needsFollowUp && first.reason.isEmpty)
        let second = try await features.detectFollowUp(input())
        #expect(second.needsFollowUp && !second.fromCache, "nothing was cached")
    }

    @Test func theReasonIsCappedAndDaysAreRead() throws {
        let long = #"{"needsFollowUp":true,"reason":"one two three four five six seven eight nine ten eleven twelve thirteen","suggestedDays":3}"#
        let result = try OutputGuard.followUp(from: Data(long.utf8))
        #expect(result.reason.split(separator: " ").count == AIPolicy.followUpReasonWords)
        #expect(result.suggestedDays == 3)
        for bad in [#"{"needsFollowUp":true}"#, #"{"needsFollowUp":1,"reason":""}"#,
                    #"{"needsFollowUp":true,"reason":"","suggestedDays":0}"#, #"{"needsFollowUp":true,"reason":"","extra":1}"#,
                    "[true]", "nonsense"] {
            #expect(throws: AIError.self) { try OutputGuard.followUp(from: Data(bad.utf8)) }
        }
    }

    @Test func aLongConversationKeepsTheSentMessageAndDropsContextFirst() async throws {
        let small = AICapabilities.fake(contextTokens: 1_400)
        let provider = ScriptedProvider(id: .appleSystem, capabilities: small, responses: [.text(yes)])
        let context = (1...3).map { earlier($0, String(repeating: "Earlier words here. ", count: 50)) }
        _ = try await makeFeatures([provider]).detectFollowUp(input(context: context))
        let request = try #require(provider.requests.first)
        #expect(request.untrusted.last?.text == "Could you send the signed contract by Friday?")
        #expect(request.untrusted.count < 9, "some earlier messages were dropped")
        #expect(untrustedTokens(request) <= (try independentBudget(request, capabilities: small)))
    }

    @Test func itNeverLeavesTheMacPinnedOrNot() async throws {
        let pcc = FakeAIProvider(id: .applePCC, capabilities: .fake(dataLocation: .appleCloud))
        let claude = FakeAIProvider(id: .agentClaude, capabilities: remoteCapabilities())
        var settings = consenting([.applePCC, .agentClaude], AISettings(pccEnabled: true))
        #expect(await aiError { _ = try await makeFeatures([pcc, claude], settings: settings).detectFollowUp(input()) }
                == .unavailable(.onDeviceOnly))
        for pin in [AIProviderID.applePCC, .agentClaude] {
            settings.featurePins[.followUp] = pin
            #expect(await aiError { _ = try await makeFeatures([pcc, claude], settings: settings).detectFollowUp(input()) }
                    == .unavailable(.onDeviceOnly))
        }
        #expect(ProviderSelectionPolicy.workload(for: .followUp, trigger: .user) == .background)
    }

    @Test func anUnavailableModelOrAIOffMeansNoCheck() async {
        let off = ScriptedProvider(id: .appleSystem, availability: .unavailable(reason: .appleIntelligenceNotEnabled)) { _, _ in
            .text(yes)
        }
        #expect(await aiError { _ = try await makeFeatures([off]).detectFollowUp(input()) }
                == .unavailable(.appleIntelligenceNotEnabled))
        #expect(off.requests.isEmpty)
        let provider = ScriptedProvider(id: .appleSystem, responses: [.text(yes)])
        #expect(await aiError { _ = try await makeFeatures([provider], settings: AISettings(enabled: false)).detectFollowUp(input()) }
                == .unavailable(.disabledBySettings))
        #expect(provider.requests.isEmpty)
    }

    @Test func theFakeScriptAnswersFromTheQuestionMark() async throws {
        let features = makeFeatures([FakeAIProvider(id: .appleSystem)])
        let question = try await features.detectFollowUp(input("Are you free on Tuesday?", key: "1.q"))
        let thanks = try await features.detectFollowUp(input("Thanks, all good.", key: "1.t"))
        #expect(question.needsFollowUp && !thanks.needsFollowUp)
    }
}
