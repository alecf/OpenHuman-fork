import Foundation
import FoundationModels
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIApple
@testable import OpenHumanAITesting

@Suite struct AppleAdapterTests {
    @available(macOS 27, iOS 27, *)
    @Test func systemAvailabilityMapsOneToOne() {
        #expect(SystemModelSource.map(.available) == .available)
        #expect(SystemModelSource.map(.unavailable(.deviceNotEligible)) == .unavailable(reason: .deviceNotEligible))
        #expect(
            SystemModelSource.map(.unavailable(.appleIntelligenceNotEnabled))
                == .unavailable(reason: .appleIntelligenceNotEnabled))
        #expect(SystemModelSource.map(.unavailable(.modelNotReady)) == .unavailable(reason: .modelNotReady))
    }

    @available(macOS 27, iOS 27, *)
    @Test func onlyTheRewriteUsesTheContentTransformationGuardrails() async throws {
        #expect(SystemModelSource.usesTransformationGuardrails(.rewrite))
        for task in AITask.allCases where task != .rewrite {
            #expect(!SystemModelSource.usesTransformationGuardrails(task), "\(task)")
        }
        let tagging = SystemModelSource(useCase: .contentTagging)
        _ = try await tagging.makeModel(for: .rewrite)
    }

    @available(macOS 27, iOS 27, *)
    @Test func privateCloudComputeIsNeverAvailableWithoutTheEntitlement() async {
        let provider = ApplePrivateCloudComputeProvider(source: PrivateCloudComputeSource())
        #expect(provider.id == .applePCC)
        #expect(await provider.availability() == .unavailable(reason: .entitlementMissing))
        let capabilities = await provider.capabilities()
        #expect(capabilities.dataLocation == .appleCloud)
        #expect(capabilities.dataLeavesDevice)
        #expect(capabilities.contextTokens == nil)
        await #expect(throws: AIError.unavailable(.entitlementMissing)) {
            for try await _ in provider.run(makeSampleRequest()) {}
        }
    }

    @available(macOS 27, iOS 27, *)
    @Test func registrationAddsSystemProviderAndClassifierButNotPCC() {
        #expect(!AppleProviders.registersPrivateCloudComputeInV1)
        let registry = AppleProviders.makeRegistry(support: .supported)
        #expect(registry.providers.map(\.id) == [.appleSystem])
        #expect(registry.classifiers.map(\.id) == [AppleSystemClassifier.providerID])
        #expect(registry.provider(.applePCC) == nil)
        #expect(registry.classifiers.allSatisfy { $0.dataLocation == .onDevice })
    }

    @available(macOS 27, iOS 27, *)
    @Test func foundationModelsErrorsMapPerSection412() {
        func map(_ error: any Error) -> AIError { FMErrorMapping.map(error, estimatedTokens: 77, contextLimit: 1000) }
        let secret = "ZEBRA email text that must not leak"
        #expect(
            map(LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: secret)))
                == .contextOverflow(counted: 5000, limit: 4096))
        #expect(map(LanguageModelError.guardrailViolation(.init(debugDescription: secret))) == .refused)
        #expect(map(LanguageModelError.refusal(.init(explanation: secret, debugDescription: secret))) == .refused)
        #expect(map(LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: secret))) == .unavailable(.usageLimitReached))
        #expect(map(LanguageModelError.timeout(.init(debugDescription: secret))) == .timeout)
        #expect(
            map(LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: .english, debugDescription: secret)))
                == .unavailable(.localeNotSupported))
        #expect(map(CancellationError()) == .cancelled)
        #expect(map(AIError.timeout) == .timeout)
        struct Odd: Error, CustomStringConvertible { var description: String { "ZEBRA leak" } }
        let other = map(Odd())
        #expect(other == .providerFailed("Odd"))
        for error in [other, map(LanguageModelError.guardrailViolation(.init(debugDescription: secret)))] {
            #expect(!"\(error)".contains("ZEBRA"))
        }
    }

    @available(macOS 27, iOS 27, *)
    @Test func caseNameDropsThePayload() {
        #expect(FMErrorMapping.caseName(LanguageModelError.timeout(.init(debugDescription: "ZEBRA"))) == "timeout")
        #expect(!FMErrorMapping.caseName(LanguageModelError.refusal(.init(explanation: "ZEBRA", debugDescription: "ZEBRA"))).contains("ZEBRA"))
    }

    @available(macOS 27, iOS 27, *)
    @Test func generableTriageProducesJSONThatTheCoreValidates() throws {
        for category in [FMTriageCategory.needsReply, .fyi, .newsletter, .notification, .receipt, .calendar, .personal, .other] {
            let triage = FMTriage(category: category, priority: 2, reason: "Because.")
            let (result, suspicious) = try OutputGuard.triage(from: triage.json, nonce: "Ab12Cd34Ef56", providerID: .appleSystem)
            #expect(result.category == category.category)
            #expect(!suspicious)
        }
        #expect(Set(TriageCategory.allCases.map(\.rawValue)).count == 8)
    }

    @available(macOS 27, iOS 27, *)
    @Test func generableReplyOptionsProduceJSONThatTheCoreValidates() throws {
        let options = FMReplyOptions(options: [
            FMReplyOption(label: "Yes", body: "Yes, Friday works."),
            FMReplyOption(label: "Later", body: "Can we move it to Monday?"),
            FMReplyOption(label: "No", body: "Sorry, I cannot make it."),
        ])
        let parsed = try OutputGuard.replyOptions(from: options.json, sources: ["Friday Monday"])
        #expect(parsed.count == 3)
        #expect(parsed[0].label == "Yes")
    }

    @available(macOS 27, iOS 27, *)
    @Test func generableSchemasExposeTheClosedCategorySet() throws {
        let schema = try JSONEncoder().encode(FMTriage.generationSchema)
        let text = String(decoding: schema, as: UTF8.self)
        for category in TriageCategory.allCases { #expect(text.contains(category.rawValue), "missing \(category)") }
    }
}

func makeSampleRequest() -> AIRequest {
    AIRequest(
        task: .summarize, promptID: PromptID("summarize.thread", version: 1), system: "Summarize.", trusted: [],
        untrusted: [UntrustedPart(kind: .emailBody, id: "m1", text: "Synthetic email text.")],
        output: .text(maxTokens: 100), nonce: "Ab12Cd34Ef56")
}
