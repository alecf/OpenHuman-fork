import Foundation

public protocol AIProvider: Sendable {
    var id: AIProviderID { get }
    var displayName: String { get }
    func capabilities() async -> AICapabilities
    func availability() async -> AIAvailability
    func countTokens(_ text: String) async -> Int
    func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error>
    func modelVersion() async -> String?
    func consentFingerprint() async -> String?
}

extension AIProvider {
    public func modelVersion() async -> String? { nil }
    public func consentFingerprint() async -> String? { nil }
}

public enum AIError: Error, Sendable, Hashable {
    case unavailable(AIAvailability.UnavailableReason)
    case contextOverflow(counted: Int, limit: Int)
    case invalidOutput(String)
    case refused
    case timeout, cancelled
    case providerFailed(String)
    case outputBlocked(String)
}
