import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIAgentCLI

@Suite struct ProcessRunnerTests {
    private func spec(
        _ executable: String, _ arguments: [String], stdin: String = "", timeout: Duration = .seconds(10),
        maxStdoutBytes: Int = 1_000_000
    ) -> ProcessSpec {
        ProcessSpec(
            executable: URL(fileURLWithPath: executable), arguments: arguments, stdin: Data(stdin.utf8),
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: FileManager.default.temporaryDirectory,
            timeout: timeout, maxStdoutBytes: maxStdoutBytes, killGrace: .milliseconds(300))
    }

    @Test func argumentsAreNeverInterpretedByAShell() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("runner-shell-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let hostile = ["; touch \(marker.path)", "$(touch \(marker.path))", "`touch \(marker.path)`", "a | b", "*"]
        let (lines, result) = try await ProcessRunner.collect(spec("/bin/echo", hostile))
        #expect(result.exitCode == 0)
        #expect(lines == [hostile.joined(separator: " ")])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func stdinReachesTheChildAndLinesStreamInOrder() async throws {
        let (lines, result) = try await ProcessRunner.collect(spec("/bin/cat", [], stdin: "one\ntwo\nthree"))
        #expect(lines == ["one", "two", "three"])
        #expect(result.exitCode == 0)
    }

    @Test func largeStdinDoesNotDeadlock() async throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let input = String(repeating: line, count: 20_000)
        let (lines, _) = try await ProcessRunner.collect(spec("/bin/cat", [], stdin: input, maxStdoutBytes: 5_000_000))
        #expect(lines.count == 20_000)
    }

    @Test func exitCodeAndStderrAreReported() async throws {
        let (_, result) = try await ProcessRunner.collect(spec("/bin/sh", ["-c", "echo oops >&2; exit 3"]))
        #expect(result.exitCode == 3)
        #expect(result.stderr == "oops\n")
    }

    @Test func stderrIsCapped() async throws {
        var capped = spec("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\0' 'e' >&2"])
        capped.maxStderrBytes = 1_000
        let (_, result) = try await ProcessRunner.collect(capped)
        #expect(result.stderr.count == 1_000)
    }

    @Test func outputOverTheCapKillsTheChild() async throws {
        let error = await aiError { _ = try await ProcessRunner.collect(spec("/usr/bin/yes", [], maxStdoutBytes: 4_096)) }
        #expect(error == .invalidOutput("The output was larger than the allowed limit."))
    }

    @Test func aMissingExecutableFailsCleanly() async {
        let error = await aiError { _ = try await ProcessRunner.collect(spec("/nonexistent/binary", [])) }
        #expect(error == .providerFailed("could not start the process"))
    }

    @Test func aWriteToAChildThatNeverReadsDoesNotKillTheApp() async throws {
        let input = String(repeating: "x", count: 2_000_000)
        let (_, result) = try await ProcessRunner.collect(spec("/usr/bin/true", [], stdin: input))
        #expect(result.exitCode == 0)
    }
}
