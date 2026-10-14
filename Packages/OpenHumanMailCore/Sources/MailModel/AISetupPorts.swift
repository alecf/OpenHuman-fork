import Foundation
import OpenHumanCore

public enum DraftRepliesChoice: String, Sendable, Hashable, CaseIterable, Codable {
    case onDeviceAuto
    case onDemand
    case off
}

public enum OnDeviceAIStatus: Sendable, Hashable {
    case available
    case unavailable(hint: String)

    public var isAvailable: Bool { self == .available }
}

public protocol AIOnboardingPort: Sendable {
    func onDeviceStatus() async -> OnDeviceAIStatus
    func draftReplies() async -> DraftRepliesChoice
    func setDraftReplies(_ choice: DraftRepliesChoice) async throws
    func agentCLIAutoQuickReplies() async -> Bool
    func summarizeOnDevice(_ thread: ThreadKey) async throws -> String?
}

public enum AIConnectionKind: String, Sendable, Hashable, Codable, CaseIterable {
    case agentCLI
    case privateCloud
    case apiKey

    public var leavesMac: Bool { true }
}

public struct AIConnection: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var kind: AIConnectionKind
    public var binaryPath: String?
    public var hasKey: Bool
    public var isInUse: Bool
    public var consentGrantedAt: Date?

    public init(id: String, title: String, kind: AIConnectionKind, binaryPath: String? = nil, hasKey: Bool = false,
                isInUse: Bool = false, consentGrantedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.binaryPath = binaryPath
        self.hasKey = hasKey
        self.isInUse = isInUse
        self.consentGrantedAt = consentGrantedAt
    }
}

public struct AIConnectionDraft: Sendable, Hashable {
    public var id: String?
    public var title: String
    public var kind: AIConnectionKind
    public var binaryPath: String?

    public init(id: String? = nil, title: String, kind: AIConnectionKind, binaryPath: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.binaryPath = binaryPath
    }
}

public protocol AIConnectionsPort: Sendable {
    func connections() async -> [AIConnection]
    func save(_ draft: AIConnectionDraft, hasKey: Bool) async throws -> AIConnection
    func remove(_ id: String) async throws
    func setInUse(_ id: String, inUse: Bool, consentGrantedAt: Date?) async throws
}

public protocol SecretStoring: Sendable {
    func setSecret(_ value: String, for name: String) throws
    func hasSecret(for name: String) -> Bool
    func removeSecret(for name: String) throws
}
