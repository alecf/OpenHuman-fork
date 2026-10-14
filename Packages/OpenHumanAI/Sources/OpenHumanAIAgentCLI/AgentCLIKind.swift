import Foundation
import OpenHumanAI

public struct CLIVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let components: [Int]

    public init(_ components: [Int]) { self.components = components }

    public init?(parsing output: String) {
        guard let match = output.firstMatch(of: #/(\d+)\.(\d+)(?:\.(\d+))?/#) else { return nil }
        var parts = [Int(match.output.1) ?? 0, Int(match.output.2) ?? 0]
        if let patch = match.output.3 { parts.append(Int(patch) ?? 0) }
        self.components = parts
    }

    public static func < (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

public enum AgentCLIKind: String, Sendable, Hashable, CaseIterable {
    case claude, codex

    public var providerID: AIProviderID { self == .claude ? .agentClaude : .agentCodex }
    public var executableName: String { rawValue }
    public var displayName: String { self == .claude ? "Claude Code" : "Codex (Experimental)" }
    public var vendor: String { self == .claude ? "Anthropic" : "OpenAI" }

    public var minimumVersion: CLIVersion? { self == .claude ? CLIVersion([2, 1, 259]) : nil }

    public var turnedOffReason: String? {
        self == .codex ? "Not available: Mail can't run Codex without its tools, which can read files on this Mac" : nil
    }

    func knownLocations(home: String) -> [String] {
        var locations = self == .claude ? ["\(home)/.claude/local/claude"] : []
        for directory in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"] {
            locations.append("\(directory)/\(executableName)")
        }
        return locations
    }

    func timeout(for task: AITask) -> Duration {
        switch task {
        case .summarize, .rewrite, .summarizeChunk, .reduce, .classify: return .seconds(60)
        case .replyOptions: return .seconds(90)
        case .askInbox: return .seconds(120)
        case .searchPlan: return .seconds(30)
        case .followUp: return .seconds(30)
        case .scheduling: return .seconds(30)
        }
    }
}
