import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIAgentCLI

@Suite struct AgentCLIParserTests {
    private func lines(_ fixture: String) throws -> [String] {
        try Fixtures.text(fixture).split(separator: "\n").map(String.init)
    }

    @Test func claudeStreamYieldsDeltasModelAndUsage() throws {
        var parser = ClaudeOutputParser()
        let events = try lines("claude/stream-text.jsonl").flatMap { parser.parse(line: $0) }
        let deltas = events.compactMap { event -> String? in
            if case .textDelta(let text) = event { return text }
            return nil
        }
        #expect(deltas.joined() == "The team agreed to move the launch review to Friday.\nDana will send the updated agenda tomorrow.")
        #expect(events.contains(.model("claude-fixture-model")))
        #expect(events.contains(.usage(AIUsage(inputTokens: 412, outputTokens: 31, cachedTokens: 0))))
        #expect(parser.sawDeltas)
        #expect(!events.contains { if case .finalText = $0 { return true } else { return false } })
    }

    @Test func claudeStructuredOutputFieldAndTextFallback() throws {
        var direct = ClaudeOutputParser()
        let events = direct.parse(document: try Fixtures.text("claude/result-structured.json"))
        let data = try #require(events.compactMap { event -> Data? in
            if case .structured(let data) = event { return data }
            return nil
        }.first)
        let value = try JSONValue.parse(data)
        #expect(value["category"]?.stringValue == "receipt")

        var fallback = ClaudeOutputParser()
        let text = fallback.parse(document: try Fixtures.text("claude/result-structured-as-text.json"))
        guard case .finalText(let answer)? = text.last(where: { if case .finalText = $0 { return true } else { return false } }) else {
            Issue.record("no final text")
            return
        }
        #expect(OutputGuard.extractJSON(from: answer) != nil)
    }

    @Test func claudeErrorResultBecomesAFailure() throws {
        var parser = ClaudeOutputParser()
        let events = try lines("claude/error-not-logged-in.jsonl").flatMap { parser.parse(line: $0) }
        #expect(events.contains(.failure("Not logged in. Please run /login.")))
    }

    @Test func claudeIgnoresBlankAndNonJSONLines() {
        var parser = ClaudeOutputParser()
        #expect(parser.parse(line: "").isEmpty)
        #expect(parser.parse(line: "Warning: something on stdout").isEmpty)
        #expect(parser.parse(line: #"{"type":"unknown"}"#).isEmpty)
    }

    @Test func codexAgentMessageAndUsage() throws {
        var parser = CodexOutputParser()
        let events = try lines("codex/exec-text.jsonl").flatMap { parser.parse(line: $0) }
        #expect(parser.lastMessage == "Summary: the launch review moved to Friday.\nDana sends the agenda.")
        #expect(events == [.usage(AIUsage(inputTokens: 512, outputTokens: 24, cachedTokens: 128, reasoningTokens: 8))])
    }

    @Test func codexFailureEvents() throws {
        var parser = CodexOutputParser()
        let events = try lines("codex/turn-failed.jsonl").flatMap { parser.parse(line: $0) }
        #expect(events == [.failure("unexpected status 401 Unauthorized: not logged in")])
    }

    @Test func failureClassification() {
        func classify(_ text: String) -> AIError {
            CLIFailureClassifier.classify(text, kind: .claude, inputTokens: 10, limit: 100)
        }
        #expect(classify("Not logged in. Please run /login.") == .unavailable(.notLoggedIn(name: "claude")))
        #expect(classify("error: unknown option '--safe-mode'") == .unavailable(.unsupportedVersion(found: "unknown", minimum: "2.1.259")))
        #expect(classify("Prompt is too long") == .contextOverflow(counted: 10, limit: 100))
        #expect(classify("429 rate limit exceeded") == .providerFailed("Claude Code is rate limited"))
        #expect(classify("kaboom with the email text: ZEBRA") == .providerFailed("Claude Code failed"))
    }
}
