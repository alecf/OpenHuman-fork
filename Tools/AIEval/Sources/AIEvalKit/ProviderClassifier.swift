import Foundation
import OpenHumanAI

public struct ProviderClassifier: AIClassificationProvider {
    public let id: AIProviderID
    public let displayName: String
    public let dataLocation: AIDataLocation
    private let provider: any AIProvider

    public init(wrapping provider: any AIProvider, dataLocation: AIDataLocation) {
        self.provider = provider
        self.id = provider.id
        self.displayName = provider.displayName
        self.dataLocation = dataLocation
    }

    public func availability() async -> AIAvailability { await provider.availability() }
    public func modelVersion() async -> String? { await provider.modelVersion() }

    public func classify(_ input: ClassificationInput) async throws -> TriageResult {
        let nonce = Untrusted.makeNonce()
        let system = try PromptLibrary.standard.system(
            .classify, values: ["nonce": nonce, "languageRule": PromptLibrary.languageRule(.matchEmail)]
        ).text
        let request = AIRequest(
            task: .classify, promptID: PromptID("triage.classify", version: 1), system: system, trusted: [],
            untrusted: input.parts,
            output: .json(schema: OutputGuard.triageSchema, maxTokens: AIPolicy.reservedTriageTokens), temperature: 0,
            nonce: nonce)
        var text = ""
        var structured: Data?
        for try await event in provider.run(request) {
            switch event {
            case .textDelta(let delta): text += delta
            case .structured(let data): structured = data
            case .started, .finished: break
            }
        }
        guard let data = structured ?? OutputGuard.extractJSON(from: text) else {
            throw AIError.invalidOutput("not JSON")
        }
        return try OutputGuard.triage(from: data, nonce: nonce, providerID: id).0
    }
}
