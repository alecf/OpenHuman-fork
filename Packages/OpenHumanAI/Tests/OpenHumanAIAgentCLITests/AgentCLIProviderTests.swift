import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIAgentCLI

@Suite struct AgentCLIProviderTests {
    @Test func availabilityReflectsDiscoveryVersionAndLogin() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        let provider = env.provider()
        #expect(await provider.availability() == .available)
        #expect(await provider.consentFingerprint() == env.binary.path)
        #expect(await provider.modelVersion() == "claude-2.1.295|default")
        let capabilities = await provider.capabilities()
        #expect(capabilities.contextTokens == nil)
        #expect(capabilities.policyInputCap == AIPolicy.agentCLIDefaultInputCap)
        #expect(capabilities.dataLocation == .thirdParty(vendor: "Anthropic"))
        #expect(capabilities.dataLeavesDevice)

        try env.set("auth", "1")
        provider.refresh()
        #expect(await provider.availability() == .unavailable(reason: .notLoggedIn(name: "claude")))
    }

    @Test func oldVersionIsUnsupported() async throws {
        let env = try FakeCLIEnvironment(kind: .claude, versionFixture: "claude/version-old.txt")
        #expect(
            await env.provider().availability()
                == .unavailable(reason: .unsupportedVersion(found: "2.1.200", minimum: "2.1.259")))
    }

    @Test func missingBinaryIsReportedByName() async throws {
        let configuration = AgentCLIConfiguration(
            overridePath: "/nonexistent/claude", homeDirectory: "/nonexistent")
        let provider = AgentCLIProvider(kind: .claude, configuration: configuration)
        #expect(await provider.availability() == .unavailable(reason: .binaryNotFound(name: "claude")))
        await #expect(throws: AIError.unavailable(.binaryNotFound(name: "claude"))) {
            _ = try await collectEvents(provider.run(makeRequest()))
        }
    }

    @Test func discoveryOrderIsOverrideThenLoginShellThenKnownLocations() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        let home = env.directory.deletingLastPathComponent().appendingPathComponent("home")
        let local = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: env.binary, to: local.appendingPathComponent("claude"))

        var configuration = AgentCLIConfiguration(homeDirectory: home.path, shellLookup: { _ in nil })
        #expect(await AgentCLIDiscovery.locate(.claude, configuration: configuration)?.path == local.appendingPathComponent("claude").path)

        configuration.shellLookup = { _ in env.binary.path }
        #expect(await AgentCLIDiscovery.locate(.claude, configuration: configuration)?.path == env.binary.path)

        configuration.overridePath = local.appendingPathComponent("claude").path
        #expect(await AgentCLIDiscovery.locate(.claude, configuration: configuration)?.path == local.appendingPathComponent("claude").path)

        configuration.overridePath = "/nonexistent/claude"
        #expect(await AgentCLIDiscovery.locate(.claude, configuration: configuration) == nil)
    }

    @Test func claudeStreamsTextThroughTheSecretGate() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.setFixture("stdout", "claude/stream-text.jsonl")
        let provider = env.provider()
        let (text, structured, usage) = try await collectEvents(provider.run(makeRequest()))
        #expect(text == "The team agreed to move the launch review to Friday.\nDana will send the updated agenda tomorrow.")
        #expect(structured == nil)
        #expect(usage == AIUsage(inputTokens: 412, outputTokens: 31, cachedTokens: 0))

        let arguments = try env.lastArguments()
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--no-session-persistence"))
        let tools = try #require(arguments.firstIndex(of: "--tools"))
        #expect(arguments[tools + 1] == "")
        #expect(!arguments.joined(separator: " ").contains("ZEBRA"))
        #expect(try env.lastStdin().contains(emailMarker))
        #expect(!(try env.lastStdin().contains("SYSTEM-MARKER")))
    }

    @Test func childGetsAnAllowlistedEnvironmentAndAnEmptyWorkingDirectory() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.setFixture("stdout", "claude/stream-text.jsonl")
        _ = try await collectEvents(env.provider().run(makeRequest()))
        let keys = try env.lastEnvironmentKeys()
        // The shell adds PWD, SHLVL and `_`; everything else must come from the allowlist
        let allowed: Set<String> = ["HOME", "USER", "PATH", "LANG", "TMPDIR", "PWD", "SHLVL", "_", "OLDPWD"]
        #expect(keys.subtracting(allowed).isEmpty, "unexpected variables: \(keys.subtracting(allowed))")
        #expect(["HOME", "USER", "PATH", "LANG", "TMPDIR"].allSatisfy(keys.contains))
        let cwd = try env.lastCwd()
        #expect(cwd.contains("openhuman-agent-"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.temporaryRoot.path).isEmpty)
    }

    @Test func claudeSystemPromptGoesInATemporaryFileNotArgv() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.setFixture("stdout", "claude/stream-text.jsonl")
        _ = try await collectEvents(env.provider().run(makeRequest()))
        let arguments = try env.lastArguments()
        let index = try #require(arguments.firstIndex(of: "--system-prompt-file"))
        #expect(arguments[index + 1].hasSuffix("/system.txt"))
        #expect(!arguments.joined(separator: " ").contains("SYSTEM-MARKER"))
    }

    @Test func claudeStructuredResultBecomesStructuredEvent() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.setFixture("stdout", "claude/result-structured.json")
        let request = makeRequest(task: .classify, output: .json(schema: OutputGuard.triageSchema, maxTokens: 80))
        let (_, structured, usage) = try await collectEvents(env.provider().run(request))
        let result = try OutputGuard.triage(from: try #require(structured), nonce: request.nonce, providerID: .agentClaude).0
        #expect(result.category == .receipt)
        #expect(usage?.inputTokens == 300)
        let arguments = try env.lastArguments()
        #expect(arguments.contains("--json-schema"))
        #expect(arguments.contains("json"))
    }

    @Test func claudeStructuredFallsBackToJSONInTheResultText() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.setFixture("stdout", "claude/result-structured-as-text.json")
        let request = makeRequest(task: .classify, output: .json(schema: OutputGuard.triageSchema, maxTokens: 80))
        let (_, structured, _) = try await collectEvents(env.provider().run(request))
        #expect(try JSONValue.parse(try #require(structured))["category"]?.stringValue == "newsletter")
    }

    @Test func nonJSONAnswerToAStructuredTaskIsInvalidOutput() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.setFixture("stdout", "claude/result-not-json.json")
        let request = makeRequest(task: .classify, output: .json(schema: OutputGuard.triageSchema, maxTokens: 80))
        await #expect(throws: AIError.invalidOutput("The answer was not JSON.")) {
            _ = try await collectEvents(env.provider().run(request))
        }
    }

    @Test func aSecretInTheAnswerIsBlockedBeforeItIsShown() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.setFixture("stdout", "claude/stream-secret.jsonl")
        var shown = ""
        do {
            for try await event in env.provider().run(makeRequest()) {
                if case .textDelta(let delta) = event { shown += delta }
            }
            Issue.record("expected the answer to be blocked")
        } catch let error as AIError {
            guard case .outputBlocked = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        #expect(!shown.contains("PRIVATE KEY"))
        #expect(shown == "Here is a harmless first line.\n")
    }

    @Test func aSecretThatWasInTheEmailIsNotBlocked() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.setFixture("stdout", "claude/stream-secret.jsonl")
        let request = makeRequest(text: "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA")
        let (text, _, _) = try await collectEvents(env.provider().run(request))
        #expect(text.contains("PRIVATE KEY"))
    }

    @Test func failuresMapToUserPresentableErrors() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.setFixture("stdout", "claude/error-not-logged-in.jsonl")
        try env.set("exit", "1")
        await #expect(throws: AIError.unavailable(.notLoggedIn(name: "claude"))) {
            _ = try await collectEvents(env.provider().run(makeRequest()))
        }
        try env.setFixture("stdout", "claude/error-context.jsonl")
        let error = await aiError { _ = try await collectEvents(env.provider().run(makeRequest())) }
        guard case .contextOverflow(_, let limit)? = error else {
            Issue.record("expected contextOverflow, got \(String(describing: error))")
            return
        }
        #expect(limit == AIPolicy.agentCLIDefaultInputCap)
    }

    @Test func nonZeroExitWithStderrIsAProviderFailureThatDoesNotEchoStderr() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.set("stderr", "boom: \(emailMarker)")
        try env.set("exit", "2")
        let error = await aiError { _ = try await collectEvents(env.provider().run(makeRequest())) }
        #expect(error == .providerFailed("Claude Code failed"))
    }

    @Test func codexIsTurnedOffAndItsCLIIsNeverStarted() async throws {
        let env = try FakeCLIEnvironment(kind: .codex)
        try env.setFixture("stdout", "codex/exec-text.jsonl")
        let provider = env.provider()
        let reason = AIAvailability.UnavailableReason.other(
            "Not available: Mail can't run Codex without its tools, which can read files on this Mac")
        #expect(await provider.availability() == .unavailable(reason: reason))
        #expect(await provider.consentFingerprint() == nil)
        await #expect(throws: AIError.unavailable(reason)) {
            _ = try await collectEvents(provider.run(makeRequest()))
        }
        #expect(env.runCount == 0, "the CLI is never started")
    }

    @Test func timeoutKillsTheChildAndFailsWithTimeout() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.set("hang", "1")
        let provider = env.provider(timeout: .milliseconds(600))
        await #expect(throws: AIError.timeout) { _ = try await collectEvents(provider.run(makeRequest())) }
        #expect(!env.childIsAlive())
        #expect(try FileManager.default.contentsOfDirectory(atPath: env.temporaryRoot.path).isEmpty)
    }

    @Test func cancellingKillsTheChild() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.set("hang", "1")
        let provider = env.provider()
        let consumer = Task { try await collectEvents(provider.run(makeRequest())) }
        #expect(await waitUntil { env.recordedPID != nil })
        let pid = try #require(env.recordedPID)
        #expect(kill(pid, 0) == 0)
        consumer.cancel()
        #expect(await waitUntil(deadline: .seconds(120)) { !env.childIsAlive() })
        _ = try? await consumer.value
        #expect(await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: env.temporaryRoot.path))?.isEmpty == true })
    }

    @Test func aChildThatIgnoresSIGTERMIsKilledAfterTheGracePeriod() async throws {
        let env = try FakeCLIEnvironment(kind: .claude)
        try env.set("hang", "1")
        try env.set("ignoreterm", "1")
        let provider = env.provider(killGrace: .milliseconds(300))
        let consumer = Task { try await collectEvents(provider.run(makeRequest())) }
        #expect(await waitUntil { env.recordedPID != nil })
        consumer.cancel()
        #expect(await waitUntil(deadline: .seconds(3)) { !env.childIsAlive() })
    }

    @Test func onlyOneProcessRunsAtATime() async throws {
        let gate = SerialGate()
        try await gate.acquire()
        let second = Task { () -> Bool in
            try await gate.acquire()
            return true
        }
        for _ in 0..<200 { await Task.yield() }
        gate.release()
        #expect(try await second.value)
        gate.release()

        try await gate.acquire()
        let cancelled = Task { try await gate.acquire() }
        for _ in 0..<50 { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        gate.release()
        try await gate.acquire()
        gate.release()
    }
}
