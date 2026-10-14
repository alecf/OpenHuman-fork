import Foundation
import OpenHumanAI
import Synchronization

public final class AgentCLIProvider: AIProvider {
    public let kind: AgentCLIKind
    public let configuration: AgentCLIConfiguration
    public var id: AIProviderID { kind.providerID }
    public var displayName: String { kind.displayName }

    private struct Probe {
        var path: URL?
        var version: CLIVersion?
        var availability: AIAvailability
    }

    private let probeCache = Mutex<Probe?>(nil)
    private let gate = SerialGate()

    public init(kind: AgentCLIKind, configuration: AgentCLIConfiguration = AgentCLIConfiguration()) {
        self.kind = kind
        self.configuration = configuration
    }

    public func capabilities() async -> AICapabilities {
        AICapabilities(
            contextTokens: nil, policyInputCap: configuration.policyInputCap, tokenCounting: .heuristic,
            streaming: kind == .claude, structuredOutput: .native, dataLocation: .thirdParty(vendor: kind.vendor),
            typicalLatency: .slow)
    }

    public func availability() async -> AIAvailability { await probe().availability }

    public func countTokens(_ text: String) async -> Int { TokenHeuristic.count(text) }

    public func modelVersion() async -> String? {
        let probe = await probe()
        guard let version = probe.version else { return nil }
        return "\(kind.executableName)-\(version)|\(configuration.model ?? "default")"
    }

    public func consentFingerprint() async -> String? { await probe().path?.path }

    public func refresh() { probeCache.withLock { $0 = nil } }

    private func probe() async -> Probe {
        if let cached = probeCache.withLock({ $0 }) { return cached }
        let fresh = await runProbe()
        probeCache.withLock { $0 = fresh }
        return fresh
    }

    private func runProbe() async -> Probe {
        if let reason = kind.turnedOffReason {
            return Probe(path: nil, version: nil, availability: .unavailable(reason: .other(reason)))
        }
        guard let path = await AgentCLIDiscovery.locate(kind, configuration: configuration) else {
            return Probe(path: nil, version: nil, availability: .unavailable(reason: .binaryNotFound(name: kind.executableName)))
        }
        let directory: URL
        do { directory = try makeTemporaryDirectory() } catch {
            return Probe(path: path, version: nil, availability: .unavailable(reason: .other("No temporary directory")))
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        func command(_ arguments: [String]) -> ProcessSpec {
            ProcessSpec(
                executable: path, arguments: arguments, environment: environment(workingDirectory: directory, binary: path),
                workingDirectory: directory, timeout: configuration.probeTimeout, maxStdoutBytes: 64 * 1024,
                killGrace: configuration.killGrace)
        }

        guard let (lines, result) = try? await ProcessRunner.collect(command(["--version"])), result.exitCode == 0,
            let version = CLIVersion(parsing: lines.joined(separator: " "))
        else {
            return Probe(path: path, version: nil, availability: .unavailable(reason: .other("\(kind.displayName) did not report a version")))
        }
        if let minimum = kind.minimumVersion, version < minimum {
            return Probe(
                path: path, version: version,
                availability: .unavailable(reason: .unsupportedVersion(found: version.description, minimum: minimum.description)))
        }
        if kind == .claude {
            let status = try? await ProcessRunner.collect(command(["auth", "status"]))
            if status?.result.exitCode != 0 {
                return Probe(path: path, version: version, availability: .unavailable(reason: .notLoggedIn(name: kind.executableName)))
            }
        }
        return Probe(path: path, version: version, availability: .available)
    }

    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await execute(request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AIError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(_ request: AIRequest, into continuation: AsyncThrowingStream<AIEvent, Error>.Continuation) async throws {
        let probe = await probe()
        guard probe.availability.isAvailable, let binary = probe.path else {
            throw AIError.unavailable(probe.availability.unavailableReason ?? .other("Unavailable"))
        }
        try await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingDirectory = directory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let schema = request.output.schema
        let input = request.renderedInput()
        let arguments: [String]
        let stdin: String
        let lastMessage = directory.appendingPathComponent("last.txt")
        switch kind {
        case .claude:
            let systemFile = directory.appendingPathComponent("system.txt")
            try write(request.system, to: systemFile)
            arguments = AgentCLIArguments.claude(
                structuredSchema: schema?.jsonString, systemPromptFile: systemFile.path, model: configuration.model)
            stdin = input
        case .codex:
            var schemaFile: String?
            if let schema {
                let file = directory.appendingPathComponent("schema.json")
                try write(schema.jsonString, to: file)
                schemaFile = file.path
            }
            arguments = AgentCLIArguments.codex(
                workingDirectory: workingDirectory.path, lastMessageFile: lastMessage.path, schemaFile: schemaFile,
                model: configuration.model)
            stdin = AgentCLIArguments.codexStdin(system: request.system, input: input)
        }

        let spec = ProcessSpec(
            executable: binary, arguments: arguments, stdin: Data(stdin.utf8),
            environment: environment(workingDirectory: workingDirectory, binary: binary),
            workingDirectory: workingDirectory, timeout: configuration.timeoutOverride ?? kind.timeout(for: request.task), killGrace: configuration.killGrace)

        continuation.yield(.started(providerID: id, model: configuration.model))

        var gateForText = LineSecretGate(request: request)
        var claude = ClaudeOutputParser()
        var codex = CodexOutputParser()
        var documentLines: [String] = []
        var failureMessages: [String] = []
        var usage: AIUsage?
        var structuredAnswer: Data?
        var finalText: String?
        var exit: ProcessResult?

        func handle(_ events: [ParsedCLIEvent]) throws {
            for event in events {
                switch event {
                case .model: break
                case .textDelta(let delta):
                    let released = try gateForText.feed(delta)
                    if !released.isEmpty { continuation.yield(.textDelta(released)) }
                case .finalText(let text): finalText = text
                case .structured(let data): structuredAnswer = data
                case .usage(let value): usage = value
                case .failure(let message): failureMessages.append(message)
                }
            }
        }

        for try await event in ProcessRunner.run(spec) {
            switch event {
            case .stdoutLine(let line):
                switch kind {
                case .claude:
                    if schema != nil { documentLines.append(line) } else { try handle(claude.parse(line: line)) }
                case .codex:
                    try handle(codex.parse(line: line))
                }
            case .exited(let result):
                exit = result
            }
        }
        guard let exit else { throw AIError.providerFailed("\(kind.displayName) ended without an exit status") }

        if kind == .claude, schema != nil { try handle(claude.parse(document: documentLines.joined(separator: "\n"))) }
        if kind == .codex {
            let fromFile = (try? String(contentsOf: lastMessage, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
            finalText = fromFile ?? codex.lastMessage
        }

        if exit.exitCode != 0 || !failureMessages.isEmpty {
            let evidence = (failureMessages + [exit.stderr]).joined(separator: "\n")
            throw CLIFailureClassifier.classify(
                evidence, kind: kind, inputTokens: TokenHeuristic.count(input), limit: configuration.policyInputCap)
        }

        if schema != nil {
            guard let data = structuredAnswer ?? finalText.flatMap(OutputGuard.extractJSON(from:)) else {
                throw AIError.invalidOutput("The answer was not JSON.")
            }
            try OutputGuard.requireNoSecrets(String(decoding: data, as: UTF8.self), request: request)
            continuation.yield(.structured(data))
        } else {
            if claude.sawDeltas {
                let rest = try gateForText.finish()
                if !rest.isEmpty { continuation.yield(.textDelta(rest)) }
            } else if let text = finalText {
                let released = try gateForText.feed(text)
                if !released.isEmpty { continuation.yield(.textDelta(released)) }
                let rest = try gateForText.finish()
                if !rest.isEmpty { continuation.yield(.textDelta(rest)) }
            } else {
                throw AIError.invalidOutput("The answer was empty.")
            }
        }
        continuation.yield(.finished(usage: usage))
    }

    private func environment(workingDirectory: URL, binary: URL) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var directories = configuration.extraPathDirectories
        directories.append(binary.deletingLastPathComponent().path)
        directories += (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        let path = directories.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return [
            "HOME": configuration.homeDirectory,
            "USER": inherited["USER"] ?? NSUserName(),
            "PATH": path,
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": workingDirectory.path + "/",
        ]
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = configuration.temporaryRoot.appendingPathComponent("openhuman-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func write(_ text: String, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        else { throw AIError.providerFailed("could not write a temporary file") }
    }
}

struct LineSecretGate {
    private let request: AIRequest
    private var pending = ""

    init(request: AIRequest) { self.request = request }

    mutating func feed(_ delta: String) throws -> String {
        pending += delta
        guard let lastNewline = pending.lastIndex(of: "\n") else { return "" }
        let ready = String(pending[...lastNewline])
        pending = String(pending[pending.index(after: lastNewline)...])
        try OutputGuard.requireNoSecrets(ready, request: request)
        return ready
    }

    mutating func finish() throws -> String {
        let rest = pending
        pending = ""
        try OutputGuard.requireNoSecrets(rest, request: request)
        return rest
    }
}
