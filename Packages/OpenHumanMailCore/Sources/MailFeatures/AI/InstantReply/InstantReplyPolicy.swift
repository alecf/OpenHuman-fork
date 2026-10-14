import Foundation

public enum InstantReplyPolicy {
    public static let slowNotice: Duration = .seconds(8)
    public static let giveUp: Duration = .seconds(30)
    public static let giveUpWithAgentCLI: Duration = .seconds(100)
    public static let lateEligibility: Duration = .milliseconds(500)

    public static func giveUp(agentCLIMayServe: Bool) -> Duration {
        agentCLIMayServe ? giveUpWithAgentCLI : giveUp
    }
}

public struct InstantReplyTiming: Sendable {
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }
}
