import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIAgentCLI

final class FakeCLIEnvironment: @unchecked Sendable {
    let directory: URL
    let temporaryRoot: URL
    let kind: AgentCLIKind

    var binary: URL { directory.appendingPathComponent(kind.executableName) }

    init(kind: AgentCLIKind, version: String? = nil, versionFixture: String? = nil) throws {
        self.kind = kind
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fake-cli-\(UUID().uuidString)")
        directory = root.appendingPathComponent("bin")
        temporaryRoot = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.url("bin/fake-cli"), to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let versionText = try version ?? Fixtures.text(versionFixture ?? "\(kind.rawValue)/version.txt")
        try set("version", versionText)
    }

    deinit { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    func set(_ control: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent("\(kind.executableName).\(control)"), atomically: true, encoding: .utf8)
    }

    func setFixture(_ control: String, _ fixture: String) throws { try set(control, try Fixtures.text(fixture)) }

    func lastArguments() throws -> [String] {
        let data = try Data(contentsOf: try latestCall("argv"))
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }

    func lastStdin() throws -> String { try String(contentsOf: try latestCall("stdin"), encoding: .utf8) }
    func lastCwd() throws -> String { try String(contentsOf: try latestCall("cwd"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }

    func lastEnvironmentKeys() throws -> Set<String> {
        let text = try String(contentsOf: try latestCall("env"), encoding: .utf8)
        return Set(text.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
    }

    var runCount: Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasPrefix("\(kind.executableName).call.") && $0.hasSuffix(".argv") }.count
    }

    var recordedPID: Int32? {
        (try? String(contentsOf: directory.appendingPathComponent("\(kind.executableName).pid"), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func latestCall(_ suffix: String) throws -> URL {
        let count = runCount
        guard count > 0 else { throw CocoaError(.fileNoSuchFile) }
        return directory.appendingPathComponent("\(kind.executableName).call.\(count).\(suffix)")
    }

    func configuration(timeout: Duration? = nil, killGrace: Duration = .seconds(3)) -> AgentCLIConfiguration {
        AgentCLIConfiguration(
            overridePath: binary.path, homeDirectory: directory.path, temporaryRoot: temporaryRoot,
            probeTimeout: .seconds(20), killGrace: killGrace, timeoutOverride: timeout)
    }

    func provider(timeout: Duration? = nil, killGrace: Duration = .seconds(3)) -> AgentCLIProvider {
        AgentCLIProvider(kind: kind, configuration: configuration(timeout: timeout, killGrace: killGrace))
    }

    func childIsAlive() -> Bool {
        guard let pid = recordedPID else { return false }
        return kill(pid, 0) == 0
    }
}

enum Fixtures {
    static var root: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    static func text(_ path: String) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }
}

func waitUntil(deadline: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + deadline
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

let emailMarker = "ZEBRA-MARKER-7731 launch review notes"

func makeRequest(
    task: AITask = .summarize, output: OutputSpec = .text(maxTokens: 200), text: String = emailMarker
) -> AIRequest {
    AIRequest(
        task: task, promptID: PromptID("summarize.thread", version: 1), system: "You summarize email. SYSTEM-MARKER.",
        trusted: [], untrusted: [UntrustedPart(kind: .emailBody, id: "m1", text: text)], output: output,
        nonce: "Ab12Cd34Ef56")
}

func collectEvents(_ stream: AsyncThrowingStream<AIEvent, Error>) async throws -> (text: String, structured: Data?, usage: AIUsage?) {
    var text = ""
    var structured: Data?
    var usage: AIUsage?
    for try await event in stream {
        switch event {
        case .started: break
        case .textDelta(let delta): text += delta
        case .structured(let data): structured = data
        case .finished(let value): usage = value
        }
    }
    return (text, structured, usage)
}

func aiError(_ body: () async throws -> Void) async -> AIError? {
    do {
        try await body()
        return nil
    } catch let error as AIError {
        return error
    } catch {
        return .providerFailed("non-AIError \(error)")
    }
}
