import Foundation

public struct AIProviderID: RawRepresentable, Hashable, Sendable, Codable, CodingKeyRepresentable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public var description: String { rawValue }

    public static let appleSystem: AIProviderID = "apple.system"
    public static let applePCC: AIProviderID = "apple.pcc"
    public static let agentClaude: AIProviderID = "agent.claude"
    public static let agentCodex: AIProviderID = "agent.codex"
    public static let fake: AIProviderID = "fake"

    public static func local(_ modelID: String) -> AIProviderID { AIProviderID("local." + modelID) }

    public var isLocalModel: Bool { rawValue.hasPrefix("local.") }
    public var isAgentCLI: Bool { rawValue.hasPrefix("agent.") }

    public var isExperimental: Bool { self == .agentCodex }
}
