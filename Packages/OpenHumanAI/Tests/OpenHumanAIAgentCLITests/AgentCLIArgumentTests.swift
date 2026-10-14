import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIAgentCLI

@Suite struct AgentCLIArgumentTests {
    @Test func claudeTextArgumentsDisableEverythingThatGivesTheModelAuthority() {
        let arguments = AgentCLIArguments.claude(structuredSchema: nil, systemPromptFile: "/tmp/x/system.txt", model: nil)
        let tools = arguments.firstIndex(of: "--tools")
        #expect(tools != nil)
        #expect(tools.map { arguments[$0 + 1] } == "")
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(pair("--disallowedTools", "mcp__*", in: arguments))
        #expect(pair("--permission-prompts", "none", in: arguments))
        #expect(pair("--max-turns", "1", in: arguments))
        #expect(pair("--system-prompt-file", "/tmp/x/system.txt", in: arguments))
        #expect(pair("--output-format", "stream-json", in: arguments))
        #expect(arguments.contains("--include-partial-messages"))
        #expect(!arguments.contains("--bare"))
        #expect(!arguments.contains("--model"))
        #expect(arguments.first == "-p")
        #expect(arguments[1] == AgentCLIArguments.claudePromptStub)
    }

    @Test func claudeStructuredArgumentsCarryTheSchema() {
        let schema = OutputGuard.triageSchema.jsonString
        let arguments = AgentCLIArguments.claude(structuredSchema: schema, systemPromptFile: "/s", model: "sonnet")
        #expect(pair("--output-format", "json", in: arguments))
        #expect(pair("--json-schema", schema, in: arguments))
        #expect(pair("--model", "sonnet", in: arguments))
        #expect(!arguments.contains("--include-partial-messages"))
    }

    @Test func codexArgumentsUseTheReadOnlySandboxAndReadStdin() {
        let arguments = AgentCLIArguments.codex(
            workingDirectory: "/tmp/w", lastMessageFile: "/tmp/last.txt", schemaFile: "/tmp/schema.json", model: nil)
        #expect(arguments.first == "exec")
        #expect(arguments.contains("--json"))
        #expect(pair("--sandbox", "read-only", in: arguments))
        #expect(arguments.contains("--skip-git-repo-check"))
        #expect(arguments.contains("--ephemeral"))
        #expect(pair("--cd", "/tmp/w", in: arguments))
        #expect(pair("--output-last-message", "/tmp/last.txt", in: arguments))
        #expect(pair("--output-schema", "/tmp/schema.json", in: arguments))
        #expect(arguments.last == "-")
    }

    @Test func modelSettingCannotBecomeAFlagOrCarryShellSyntax() {
        for bad in ["--tools", "-x", "$(touch /tmp/x)", "a b", "x;y", "`id`", String(repeating: "m", count: 101), ""] {
            let arguments = AgentCLIArguments.claude(structuredSchema: nil, systemPromptFile: "/s", model: bad)
            #expect(!arguments.contains("--model"), "accepted \(bad)")
        }
        #expect(AgentCLIArguments.sanitizedModel("claude-sonnet-4.5") == "claude-sonnet-4.5")
        #expect(AgentCLIArguments.sanitizedModel("gpt-5-codex[1m]") == "gpt-5-codex[1m]")
    }

    @Test func codexStdinMarksTheTrustedSystemSectionFirst() {
        let stdin = AgentCLIArguments.codexStdin(system: "SYS", input: "INPUT")
        #expect(stdin.hasPrefix("=== SYSTEM INSTRUCTIONS (trusted) ===\nSYS\n=== END SYSTEM INSTRUCTIONS ===\n\nINPUT"))
    }

    @Test func versionsParseAndCompare() {
        #expect(CLIVersion(parsing: "2.1.295 (Claude Code)") == CLIVersion([2, 1, 295]))
        #expect(CLIVersion(parsing: "codex-cli 0.9.1") == CLIVersion([0, 9, 1]))
        #expect(CLIVersion(parsing: "no version") == nil)
        #expect(CLIVersion([2, 1, 258]) < CLIVersion([2, 1, 259]))
        #expect(CLIVersion([2, 2]) > CLIVersion([2, 1, 999]))
        #expect(!(CLIVersion([2, 1]) < CLIVersion([2, 1, 0])))
    }

    private func pair(_ flag: String, _ value: String, in arguments: [String]) -> Bool {
        arguments.indices.contains { $0 + 1 < arguments.count && arguments[$0] == flag && arguments[$0 + 1] == value }
    }
}
