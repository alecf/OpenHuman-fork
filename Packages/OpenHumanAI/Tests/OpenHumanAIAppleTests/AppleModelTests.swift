import Foundation
import FoundationModels
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIApple
@testable import OpenHumanAITesting

let systemModelIsAvailable = ProcessInfo.processInfo.environment["OH_REAL_SERVICES"] == "1"
    && SystemLanguageModel.default.isAvailable

@Suite struct AppleModelAvailabilityTests {
    @Test func reportsAvailabilityOfTheSystemModelOnThisMac() async {
        let provider = AppleSystemProvider(source: SystemModelSource())
        let availability = await provider.availability()
        print("apple.system availability: \(availability)")
        #expect(availability == SystemModelSource.map(SystemLanguageModel.default.availability))
        let capabilities = await provider.capabilities()
        #expect(capabilities.dataLocation == .onDevice)
        if !availability.isAvailable { #expect(capabilities.contextTokens == nil) }
    }
}

@Suite(.enabled(if: systemModelIsAvailable, "needs the Apple system model")) struct AppleModelTests {
    let provider = AppleSystemProvider(source: SystemModelSource())

    @Test func contextSizeAndTokenCountsComeFromTheRuntime() async throws {
        let capabilities = await provider.capabilities()
        let contextSize = try #require(capabilities.contextTokens)
        #expect(contextSize > 0)
        #expect(capabilities.tokenCounting == .exact)
        let text = String(repeating: "The quarterly planning review moved to Friday. ", count: 20)
        let exact = await provider.countTokens(text)
        let heuristic = TokenHeuristic.count(text)
        let tokenCount = try await SystemLanguageModel.default.tokenCount(for: text)
        #expect(exact == tokenCount)
        #expect(exact > 0)
        #expect(heuristic >= exact)
        print("apple.system contextSize=\(contextSize) tokenCount=\(exact) heuristic=\(heuristic) os=\(ProcessInfo.processInfo.operatingSystemVersionString) guided=\(capabilities.structuredOutput)")
    }

    @Test func aFixtureThreadSummaryStreams() async throws {
        let thread = SyntheticThreads.short()
        let features = makeFeatures([provider])
        var chunks = 0
        var text = ""
        for try await piece in features.summarize(thread) {
            if case .textDelta(let delta) = piece {
                chunks += 1
                text += delta
            }
        }
        #expect(!text.isEmpty)
        #expect(chunks >= 1)
    }

    @Test func aRequestLargerThanTheContextWindowIsAContextOverflow() async throws {
        let contextSize = try #require(await provider.capabilities().contextTokens)
        let words = SyntheticThreads.words(contextSize * 3, sentences: true, using: &overflowRNG)
        var request = makeSampleRequest()
        request.untrusted = [UntrustedPart(kind: .emailBody, id: "m1", text: words)]
        let error = await aiError { for try await _ in provider.run(request) {} }
        guard case .contextOverflow(_, let limit)? = error else {
            Issue.record("expected contextOverflow, got \(String(describing: error))")
            return
        }
        #expect(limit > 0)
    }

    @Test func guidedGenerationDecodesExactlyThreeReplyOptions() async throws {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: "Write short reply options to the email.")
        let response = try await session.respond(
            to: "Email: Can you confirm the Friday review?", generating: FMReplyOptions.self)
        #expect(response.content.options.count == 3)
        #expect(response.content.options.allSatisfy { !$0.body.isEmpty })
    }

    @Test func theClassifierReturnsAValidCategory() async throws {
        let classifier = AppleSystemClassifier()
        let thread = AIThreadInput(
            threadKey: "t", subject: "Your receipt from Example Store",
            messages: [
                AIMessageInput(
                    messageKey: "m1", from: "Example Store <orders@example.com>", date: Date(timeIntervalSince1970: 1_790_000_000),
                    bodyText: "Thank you for your purchase. Order total: $12.00. Receipt attached.", subject: "Your receipt")
            ])
        let result = try await classifier.classify(ClassificationInput.make(from: thread))
        #expect(TriageCategory.allCases.contains(result.category))
        #expect((0...3).contains(result.priority))
        #expect(result.providerID == AppleSystemClassifier.providerID)
    }
}

nonisolated(unsafe) var overflowRNG = SeededGenerator(seed: 42)
