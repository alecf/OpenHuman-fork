import Foundation
import FoundationModels
import OpenHumanAI

public protocol FMModelSource: Sendable {
    associatedtype Model: LanguageModel
    var providerID: AIProviderID { get }
    var displayName: String { get }
    var dataLocation: AIDataLocation { get }
    func availability() async -> AIAvailability
    func makeModel() async throws -> Model
    func makeModel(for task: AITask) async throws -> Model
    func contextSize() async -> Int?
    func tokenCount(for text: String) async -> Int?
    func supportsGuidedGeneration() async -> Bool
    func modelLabel() -> String
    func modelVersion() async -> String
}

extension FMModelSource {
    public func makeModel(for task: AITask) async throws -> Model { try await makeModel() }
}

public struct SystemModelSource: FMModelSource {
    public enum UseCase: Sendable, Hashable {
        case general
        case contentTagging
    }

    private let model: SystemLanguageModel
    private let transforming: SystemLanguageModel?
    private let useCase: UseCase

    public init(useCase: UseCase = .general) {
        self.useCase = useCase
        switch useCase {
        case .general:
            model = SystemLanguageModel.default
            transforming = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        case .contentTagging:
            model = SystemLanguageModel(useCase: .contentTagging)
            transforming = nil
        }
    }

    // Why: default guardrails refuse rewrites of ordinary mail as "declined"; only rewrite uses the permissive transformation mode
    public static func usesTransformationGuardrails(_ task: AITask) -> Bool {
        task == .rewrite
    }

    public func makeModel(for task: AITask) async throws -> SystemLanguageModel {
        if Self.usesTransformationGuardrails(task), let transforming { return transforming }
        return model
    }

    public var providerID: AIProviderID { .appleSystem }
    public var displayName: String { "Apple on-device model" }
    public var dataLocation: AIDataLocation { .onDevice }

    public func availability() async -> AIAvailability {
        Self.map(model.availability)
    }

    static func map(_ availability: SystemLanguageModel.Availability) -> AIAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(reason: .deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(reason: .appleIntelligenceNotEnabled)
            case .modelNotReady: return .unavailable(reason: .modelNotReady)
            @unknown default: return .unavailable(reason: .other("The system model is unavailable"))
            }
        }
    }

    public func makeModel() async throws -> SystemLanguageModel { model }

    public func contextSize() async -> Int? {
        guard model.isAvailable else { return nil }
        let size = model.contextSize
        return size > 0 ? size : nil
    }

    public func tokenCount(for text: String) async -> Int? {
        guard model.isAvailable else { return nil }
        return try? await model.tokenCount(for: text)
    }

    public func supportsGuidedGeneration() async -> Bool { model.capabilities.contains(.guidedGeneration) }

    public func supportsLocale(_ locale: Locale = .current) -> Bool { model.supportsLocale(locale) }

    public func modelLabel() -> String {
        switch useCase {
        case .general: return "apple.system"
        case .contentTagging: return "apple.system.contentTagging"
        }
    }

    public func modelVersion() async -> String {
        "\(ProcessInfo.processInfo.operatingSystemVersionString)|\(model.variant.displayName)|\(useCase)"
    }
}

public struct PrivateCloudComputeSource: FMModelSource {
    private let entitlementConfirmed: Bool

    public init(entitlementConfirmed: Bool = false) { self.entitlementConfirmed = entitlementConfirmed }

    public var providerID: AIProviderID { .applePCC }
    public var displayName: String { "Apple Private Cloud Compute" }
    public var dataLocation: AIDataLocation { .appleCloud }

    public func availability() async -> AIAvailability {
        guard entitlementConfirmed else { return .unavailable(reason: .entitlementMissing) }
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(reason: .deviceNotEligible)
            case .systemNotReady: return .unavailable(reason: .modelNotReady)
            @unknown default: return .unavailable(reason: .other("Private Cloud Compute is unavailable"))
            }
        }
    }

    public func makeModel() async throws -> PrivateCloudComputeLanguageModel { PrivateCloudComputeLanguageModel() }

    public func contextSize() async -> Int? {
        guard entitlementConfirmed else { return nil }
        let size = try? await PrivateCloudComputeLanguageModel().contextSize
        return size.flatMap { $0 > 0 ? $0 : nil }
    }

    public func tokenCount(for text: String) async -> Int? { nil }

    public func supportsGuidedGeneration() async -> Bool {
        PrivateCloudComputeLanguageModel().capabilities.contains(.guidedGeneration)
    }

    public func modelLabel() -> String { "apple.pcc" }

    public func modelVersion() async -> String { ProcessInfo.processInfo.operatingSystemVersionString }
}
