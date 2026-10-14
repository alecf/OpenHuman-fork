import Foundation
import OpenHumanAI

public enum AgentCLIArguments {
    public static let claudePromptStub = "Follow the system prompt. The input is provided on stdin."

    public static func claude(structuredSchema: String?, systemPromptFile: String, model: String?) -> [String] {
        var arguments = ["-p", claudePromptStub]
        if let structuredSchema {
            arguments += ["--output-format", "json", "--json-schema", structuredSchema]
        } else {
            arguments += ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        }
        arguments += [
            "--system-prompt-file", systemPromptFile,
            "--tools", "",
            "--disallowedTools", "mcp__*",
            "--strict-mcp-config",
            "--safe-mode",
            "--no-session-persistence",
            "--permission-prompts", "none",
            "--max-turns", "1",
        ]
        if let model = sanitizedModel(model) { arguments += ["--model", model] }
        return arguments
    }

    public static func codex(
        workingDirectory: String, lastMessageFile: String, schemaFile: String?, model: String?
    ) -> [String] {
        var arguments = [
            "exec", "--json",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--ephemeral",
            "--cd", workingDirectory,
            "--output-last-message", lastMessageFile,
        ]
        if let schemaFile { arguments += ["--output-schema", schemaFile] }
        if let model = sanitizedModel(model) { arguments += ["--model", model] }
        arguments.append("-")
        return arguments
    }

    public static func codexStdin(system: String, input: String) -> String {
        "=== SYSTEM INSTRUCTIONS (trusted) ===\n\(system)\n=== END SYSTEM INSTRUCTIONS ===\n\n\(input)"
    }

    static func sanitizedModel(_ model: String?) -> String? {
        guard let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty, !model.hasPrefix("-"),
            model.count <= 100,
            model.allSatisfy({ $0.isLetter || $0.isNumber || "-_.:/[]".contains($0) })
        else { return nil }
        return model
    }
}
