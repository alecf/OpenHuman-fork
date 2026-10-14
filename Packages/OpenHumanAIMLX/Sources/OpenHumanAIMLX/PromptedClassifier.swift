import Foundation
import OpenHumanAI

public struct PromptedClassifier: AIClassificationProvider {
    public let id: AIProviderID
    public let displayName: String
    public let dataLocation: AIDataLocation
    private let provider: any AIProvider
    private let promptSource: any PromptLibrarySource
    private var prompts: PromptLibrary { promptSource.current }
    private let gate: LocalClassifierGate?

    public static let autoLabelMaxTokens = 24

    public init?(
        wrapping provider: any AIProvider, dataLocation: AIDataLocation = .onDevice, id: AIProviderID? = nil,
        displayName: String? = nil, prompts: any PromptLibrarySource = PromptLibraryProvider.shared, gate: LocalClassifierGate? = nil
    ) {
        guard !dataLocation.leavesDevice else { return nil }
        self.provider = provider
        self.id = id ?? AIProviderID(provider.id.rawValue + ".classifier")
        self.displayName = displayName ?? (provider.displayName + " (classification)")
        self.dataLocation = dataLocation
        self.promptSource = prompts
        self.gate = gate
    }

    public func availability() async -> AIAvailability {
        if let gate, case .unavailable = gate.availability { return gate.availability }
        return await provider.availability()
    }

    public func modelVersion() async -> String? {
        await provider.modelVersion().map { $0 + "|classifier@1" }
    }

    public func classify(_ input: ClassificationInput) async throws -> TriageResult {
        try await checkRunnable()
        let nonce = Untrusted.makeNonce()
        let rendered: String
        do {
            let library = prompts
            rendered = try library.system(
                .classify, values: ["nonce": nonce, "languageRule": library.languageRule(.matchEmail)]
            ).text
        } catch {
            throw AIError.providerFailed("classification prompt unavailable")
        }
        let request = AIRequest(
            task: .classify, promptID: PromptID("triage.classify", version: 1), system: rendered, trusted: [],
            untrusted: input.parts, output: .json(schema: OutputGuard.triageSchema, maxTokens: AIPolicy.reservedTriageTokens),
            temperature: 0, nonce: nonce)
        let (text, structured) = try await collect(request)
        guard let data = structured ?? OutputGuard.extractJSON(from: text) else {
            throw AIError.invalidOutput("The classifier did not return JSON.")
        }
        return try OutputGuard.triage(from: data, nonce: nonce, providerID: id).0
    }

    public func autoLabel(_ input: ClassificationInput) async throws -> AutoLabelCategory? {
        try await checkRunnable()
        let nonce = Untrusted.makeNonce()
        let template: (text: String, id: PromptID)
        do {
            let library = prompts
            let system = try library.system(
                .autoLabel, values: ["nonce": nonce, "languageRule": library.languageRule(.matchEmail)])
            template = (system.text, system.id)
        } catch {
            throw AIError.providerFailed("auto label prompt unavailable")
        }
        let schema = JSONSchema.object(
            properties: ["category": .string(enumValues: AutoLabelOutput.allowedWords.sorted())], required: ["category"])
        let request = AIRequest(
            task: .classify, promptID: template.id, system: template.text, trusted: [], untrusted: input.parts,
            output: .json(schema: schema, maxTokens: Self.autoLabelMaxTokens), temperature: 0, nonce: nonce)
        let (text, structured) = try await collect(request)
        if let structured { return try AutoLabelOutput.parse(String(decoding: structured, as: UTF8.self)) }
        return try AutoLabelOutput.parse(text)
    }

    private func checkRunnable() async throws {
        if let reason = gate?.blockingReason() { throw AIError.unavailable(.other(reason)) }
        guard await provider.capabilities().dataLocation == .onDevice else {
            throw AIError.unavailable(.onDeviceOnly)
        }
    }

    private func collect(_ request: AIRequest) async throws -> (String, Data?) {
        var text = ""
        var structured: Data?
        for try await event in provider.run(request) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta): text += delta
            case .structured(let data): structured = data
            case .started, .finished: break
            }
        }
        try Task.checkCancellation()
        return (text, structured)
    }
}
