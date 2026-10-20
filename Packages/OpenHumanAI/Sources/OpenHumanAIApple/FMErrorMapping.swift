import Foundation
import FoundationModels
import OpenHumanAI

@available(macOS 27, iOS 27, *)
enum FMErrorMapping {
    static func map(_ error: any Error, estimatedTokens: Int, contextLimit: Int?) -> AIError {
        if let error = error as? AIError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded(let details):
                return .contextOverflow(counted: details.tokenCount, limit: details.contextSize)
            case .guardrailViolation, .refusal:
                return .refused
            case .rateLimited:
                return .unavailable(.usageLimitReached)
            case .unsupportedLanguageOrLocale:
                return .unavailable(.localeNotSupported)
            case .timeout:
                return .timeout
            case .unsupportedCapability: return .providerFailed("unsupportedCapability")
            case .unsupportedTranscriptContent: return .providerFailed("unsupportedTranscriptContent")
            case .unsupportedGenerationGuide: return .providerFailed("unsupportedGenerationGuide")
            @unknown default: return .providerFailed("unknown")
            }
        }
        let typeName = String(describing: type(of: error))
        if typeName.hasSuffix("GenerationError") {
            switch caseName(error) {
            case "exceededContextWindowSize": return .contextOverflow(counted: estimatedTokens, limit: contextLimit ?? 0)
            case "guardrailViolation", "refusal": return .refused
            case "rateLimited": return .unavailable(.usageLimitReached)
            case "unsupportedLanguageOrLocale": return .unavailable(.localeNotSupported)
            case "assetsUnavailable": return .unavailable(.modelNotReady)
            case let name: return .providerFailed(name)
            }
        }
        return .providerFailed(typeName)
    }

    static func caseName(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        if let label = mirror.children.first?.label { return label }
        return String(describing: value)
    }
}
