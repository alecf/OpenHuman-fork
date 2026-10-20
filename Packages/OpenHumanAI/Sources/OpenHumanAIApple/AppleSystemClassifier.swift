import Foundation
import FoundationModels
import OpenHumanAI

protocol TriageGenerating: Sendable {
    func supportsGuidedGeneration() async -> Bool
    func generate(system: String, input: String, maxTokens: Int) async throws -> TriageResult
    func generateAutoLabel(system: String, input: String, maxTokens: Int) async throws -> AutoLabelCategory?
}

extension TriageGenerating {
    func generateAutoLabel(system: String, input: String, maxTokens: Int) async throws -> AutoLabelCategory? {
        throw AIError.unavailable(.other("Auto labels are not available on this model"))
    }
}

@available(macOS 27, iOS 27, *)
struct SystemModelTriageGenerator: TriageGenerating {
    let source: SystemModelSource

    func supportsGuidedGeneration() async -> Bool { await source.supportsGuidedGeneration() }

    func generate(system: String, input: String, maxTokens: Int) async throws -> TriageResult {
        let model = try await source.makeModel()
        let session = LanguageModelSession(model: model, tools: [], instructions: system)
        let options = GenerationOptions(maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: input, generating: FMTriage.self, options: options)
        return response.content.result
    }

    func generateAutoLabel(system: String, input: String, maxTokens: Int) async throws -> AutoLabelCategory? {
        let model = try await source.makeModel()
        let session = LanguageModelSession(model: model, tools: [], instructions: system)
        let options = GenerationOptions(maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: input, generating: FMAutoLabel.self, options: options)
        return response.content.category.category
    }
}

@available(macOS 27, iOS 27, *)
public struct AppleSystemClassifier: AIClassificationProvider {
    public static let providerID: AIProviderID = .appleSystemClassifier

    private let source: SystemModelSource
    private let generator: any TriageGenerating
    private let promptSource: any PromptLibrarySource
    private var prompts: PromptLibrary { promptSource.current }

    public init(useCase: SystemModelSource.UseCase = .general, prompts: any PromptLibrarySource = PromptLibraryProvider.shared) {
        let source = SystemModelSource(useCase: useCase)
        self.init(source: source, generator: SystemModelTriageGenerator(source: source), prompts: prompts)
    }

    init(source: SystemModelSource, generator: any TriageGenerating, prompts: any PromptLibrarySource) {
        self.source = source
        self.generator = generator
        self.promptSource = prompts
    }

    public var id: AIProviderID { Self.providerID }
    public var displayName: String { "Apple on-device model (classification)" }
    public var dataLocation: AIDataLocation { .onDevice }

    public func availability() async -> AIAvailability { await source.availability() }

    public func modelVersion() async -> String? { await source.modelVersion() + "|classifier@1" }

    public func classify(_ input: ClassificationInput) async throws -> TriageResult {
        guard await generator.supportsGuidedGeneration() else {
            throw AIError.unavailable(.other("Guided generation is not available on this model"))
        }
        let nonce = Untrusted.makeNonce()
        let system: String
        do {
            let library = prompts
            system = try library.system(
                .classify, values: ["nonce": nonce, "languageRule": library.languageRule(.matchEmail)]
            ).text
        } catch {
            throw AIError.providerFailed("classification prompt unavailable")
        }
        let rendered = Untrusted.render(input.parts, nonce: nonce)
        let raw: TriageResult
        do {
            raw = try await generator.generate(system: system, input: rendered, maxTokens: AIPolicy.reservedTriageTokens)
        } catch {
            throw FMErrorMapping.map(
                error, estimatedTokens: TokenHeuristic.count(rendered), contextLimit: await source.contextSize())
        }
        let (result, _) = OutputGuard.checkedTriage(
            TriageResult(category: raw.category, priority: raw.priority, reason: raw.reason, providerID: id), nonce: nonce)
        return result
    }

    public func autoLabel(_ input: ClassificationInput) async throws -> AutoLabelCategory? {
        guard await generator.supportsGuidedGeneration() else {
            throw AIError.unavailable(.other("Guided generation is not available on this model"))
        }
        let nonce = Untrusted.makeNonce()
        let system: String
        do {
            let library = prompts
            system = try library.system(
                .autoLabel, values: ["nonce": nonce, "languageRule": library.languageRule(.matchEmail)]
            ).text
        } catch {
            throw AIError.providerFailed("auto label prompt unavailable")
        }
        let rendered = Untrusted.render(input.parts, nonce: nonce)
        do {
            return try await generator.generateAutoLabel(
                system: system, input: rendered, maxTokens: AIPolicy.reservedTriageTokens)
        } catch let error as AIError {
            throw error
        } catch {
            throw FMErrorMapping.map(
                error, estimatedTokens: TokenHeuristic.count(rendered), contextLimit: await source.contextSize())
        }
    }
}
