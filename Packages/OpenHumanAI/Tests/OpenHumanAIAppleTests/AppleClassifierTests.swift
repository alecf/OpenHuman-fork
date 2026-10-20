import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIApple
@testable import OpenHumanAITesting

@Suite struct AppleClassifierTests {
    final class RecordingGenerator: TriageGenerating, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(system: String, input: String, maxTokens: Int)] = []
        let guided: Bool
        let behaviour: @Sendable () throws -> TriageResult

        init(guided: Bool = true, behaviour: @escaping @Sendable () throws -> TriageResult) {
            self.guided = guided
            self.behaviour = behaviour
        }

        func supportsGuidedGeneration() async -> Bool { guided }

        func generate(system: String, input: String, maxTokens: Int) async throws -> TriageResult {
            lock.withLock { calls.append((system, input, maxTokens)) }
            return try behaviour()
        }
    }

    @available(macOS 27, iOS 27, *)
    private func classifier(_ generator: RecordingGenerator) -> AppleSystemClassifier {
        AppleSystemClassifier(source: SystemModelSource(), generator: generator, prompts: PromptLibrary.standard)
    }

    private func input(body: String = "Hi, can you confirm the Friday review? Thanks, Dana") -> ClassificationInput {
        ClassificationInput.make(
            from: AIThreadInput(
                threadKey: "t1", subject: "Friday review",
                messages: [AIMessageInput(messageKey: "m1", from: "Dana <dana@example.com>", date: fixedDate, bodyText: body, subject: "Friday review")]))
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    @available(macOS 27, iOS 27, *)
    @Test func theEmailTextOnlyAppearsInsideNonceTaggedBlocks() async throws {
        let generator = RecordingGenerator { TriageResult(category: .needsReply, priority: 2, reason: "Asks to confirm.") }
        let result = try await classifier(generator).classify(input())
        #expect(result.category == .needsReply)
        #expect(result.providerID == AppleSystemClassifier.providerID)

        let call = try #require(generator.calls.first)
        #expect(call.maxTokens == AIPolicy.reservedTriageTokens)
        #expect(!call.system.contains("Friday"))
        #expect(!call.system.contains("dana@example.com"))
        let nonce = try #require(call.input.firstMatch(of: #/nonce="([A-Za-z0-9]+)"/#)?.output.1)
        #expect(call.system.contains(String(nonce)))
        #expect(call.input.matches(of: #/<email_data /#).count == 3)
        #expect(call.input.contains("Friday review"))
    }

    @available(macOS 27, iOS 27, *)
    @Test func autoLabelsUseTheirOwnPinnedPromptAndUntrustedBlocks() async throws {
        final class LabelGenerator: TriageGenerating, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var calls: [(system: String, input: String)] = []
            func supportsGuidedGeneration() async -> Bool { true }
            func generate(system: String, input: String, maxTokens: Int) async throws -> TriageResult {
                Issue.record("auto labels never ask for a triage verdict")
                return TriageResult(category: .other, priority: 0, reason: "")
            }
            func generateAutoLabel(system: String, input: String, maxTokens: Int) async throws -> AutoLabelCategory? {
                lock.withLock { calls.append((system, input)) }
                return .respond
            }
        }
        let generator = LabelGenerator()
        let provider = AppleSystemClassifier(source: SystemModelSource(), generator: generator, prompts: PromptLibrary.standard)
        #expect(try await provider.autoLabel(input()) == .respond)
        let call = try #require(generator.calls.first)
        #expect(call.system.contains("auto label") && !call.system.contains("Friday"))
        #expect(call.input.matches(of: #/<email_data /#).count == 3)
        #expect(AutoLabelPrompt.version == 3)
        #expect(!AutoLabelCategory.modelCategories.contains(.waiting), "Waiting is derived by the app, never asked")
    }

    @available(macOS 27, iOS 27, *)
    @Test func aGeneratorWithoutAutoLabelsSaysSo() async {
        let generator = RecordingGenerator { TriageResult(category: .fyi, priority: 0, reason: "") }
        await #expect(throws: AIError.self) { _ = try await classifier(generator).autoLabel(input()) }
        #expect(generator.calls.isEmpty)
    }

    @available(macOS 27, iOS 27, *)
    @Test func eachCallGetsAFreshNonce() async throws {
        let generator = RecordingGenerator { TriageResult(category: .fyi, priority: 0, reason: "") }
        let provider = classifier(generator)
        _ = try await provider.classify(input())
        _ = try await provider.classify(input())
        let nonces = generator.calls.compactMap { $0.input.firstMatch(of: #/nonce="([A-Za-z0-9]+)"/#).map { String($0.output.1) } }
        #expect(Set(nonces).count == 2)
    }

    @available(macOS 27, iOS 27, *)
    @Test func aReasonThatEchoesThePromptStructureIsDropped() async throws {
        let generator = RecordingGenerator { TriageResult(category: .other, priority: 3, reason: "see <email_data> block") }
        let result = try await classifier(generator).classify(input())
        #expect(result.reason.isEmpty)
        #expect(result.category == .other)
    }

    @available(macOS 27, iOS 27, *)
    @Test func priorityAndReasonAreClamped() async throws {
        let long = String(repeating: "r", count: 400)
        let generator = RecordingGenerator { TriageResult(category: .fyi, priority: 9, reason: long) }
        let result = try await classifier(generator).classify(input())
        #expect(result.priority == 3)
        #expect(result.reason.count <= AIPolicy.triageReasonCharacters)
    }

    @available(macOS 27, iOS 27, *)
    @Test func foundationModelsFailuresMapToAIErrors() async {
        let generator = RecordingGenerator { throw CancellationError() }
        await #expect(throws: AIError.cancelled) { _ = try await classifier(generator).classify(input()) }
    }

    @available(macOS 27, iOS 27, *)
    @Test func withoutGuidedGenerationItDeclinesInsteadOfGuessing() async {
        let generator = RecordingGenerator(guided: false) { TriageResult(category: .fyi, priority: 0, reason: "") }
        await #expect(throws: AIError.unavailable(.other("Guided generation is not available on this model"))) {
            _ = try await classifier(generator).classify(input())
        }
        #expect(generator.calls.isEmpty)
    }

    @available(macOS 27, iOS 27, *)
    @Test func theClassifierIsOnDeviceAndBackgroundEligible() async {
        let provider = classifier(RecordingGenerator { TriageResult(category: .fyi, priority: 0, reason: "") })
        #expect(provider.dataLocation == .onDevice)
        #expect(await provider.modelVersion()?.hasSuffix("|classifier@1") == true)
    }

    @available(macOS 27, iOS 27, *)
    @Test func selectionPicksTheClassifierForClassifyAndNeverForAnythingElse() async throws {
        let generator = RecordingGenerator { TriageResult(category: .receipt, priority: 1, reason: "A receipt.") }
        let apple = classifier(generator)
        let registry = ProviderRegistry(classifiers: [apple])
        let candidates = await registry.candidates(for: .classify, settings: AISettings())
        #expect(candidates.map(\.id) == [AppleSystemClassifier.providerID])
        #expect(candidates.first?.kind == .classifier)
        let others = await registry.candidates(for: .summarize, settings: AISettings())
        #expect(others.isEmpty)
    }
}
