import Foundation
import Testing
@testable import MailFeatures

struct TailscaleLocatorTests {
    @Test func searchesInTheDocumentedOrder() {
        #expect(TailscaleLocator.candidatePaths(home: "/Users/x") == [
            "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Users/x/.local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"])
    }

    @Test func takesTheFirstExecutableCandidate() {
        let all = Set(TailscaleLocator.candidatePaths(home: "/Users/x"))
        #expect(TailscaleLocator.find(home: "/Users/x", isExecutable: { all.contains($0) })?.path == "/usr/local/bin/tailscale")
        #expect(TailscaleLocator.find(home: "/Users/x", isExecutable: { $0 != "/usr/local/bin/tailscale" && all.contains($0) })?.path
                == "/opt/homebrew/bin/tailscale")
        #expect(TailscaleLocator.find(home: "/Users/x", isExecutable: { $0.hasSuffix("/.local/bin/tailscale") || $0.hasSuffix("MacOS/Tailscale") })?.path
                == "/Users/x/.local/bin/tailscale")
        #expect(TailscaleLocator.find(home: "/Users/x", isExecutable: { $0.hasSuffix("MacOS/Tailscale") })?.path
                == "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
    }

    @Test func nothingFoundIsNil() {
        #expect(TailscaleLocator.find(home: "/Users/x", isExecutable: { _ in false }) == nil)
    }
}

enum TailscaleFixtures {
    static func status(backend: String = "Running", selfUser: Int? = 100) -> Data {
        let me = selfUser.map { "\"UserID\": \($0)," } ?? ""
        let json = """
        {"Version": "1.0", "BackendState": "\(backend)",
         "Self": {"HostName": "Laptop", "DNSName": "laptop.tail1234.ts.net.", "OS": "macOS", \(me) "Online": true},
         "Peer": {
          "nodekey:a": {"HostName": "Mac mini", "DNSName": "mac-mini.tail1234.ts.net.", "OS": "macOS", "UserID": 100, "Online": true},
          "nodekey:b": {"HostName": "Phone", "DNSName": "phone.tail1234.ts.net.", "OS": "iOS", "UserID": 100, "Online": true},
          "nodekey:c": {"HostName": "Old desktop", "DNSName": "old-desktop.tail1234.ts.net.", "OS": "linux", "UserID": 100, "Online": false},
          "nodekey:d": {"HostName": "Friend", "DNSName": "friend.other.ts.net.", "OS": "macOS", "UserID": 200, "Online": true},
          "nodekey:e": {"HostName": "Michael's \\"Studio\\"; rm -rf", "DNSName": "studio.tail1234.ts.net.", "OS": "macOS", "UserID": 100, "Online": true},
          "nodekey:f": {"HostName": "-x", "DNSName": "-x.tail1234.ts.net.", "OS": "linux", "UserID": 100, "Online": true},
          "nodekey:g": {"HostName": "a b", "DNSName": "a b.tail1234.ts.net.", "OS": "linux", "UserID": 100, "Online": true},
          "nodekey:h": {"HostName": "Tablet", "DNSName": "tablet.tail1234.ts.net.", "OS": "iOS", "UserID": 100, "Online": true},
          "nodekey:i": {"HostName": "No online field", "DNSName": "nofield.tail1234.ts.net.", "OS": "linux", "UserID": 100}
         }}
        """
        return Data(json.utf8)
    }
}

struct TailscaleStatusParserTests {
    @Test func listsOnlyOwnOnlineNonIOSDevices() throws {
        let devices = try TailscaleStatusParser.devices(from: TailscaleFixtures.status())
        #expect(devices.map(\.target) == ["mac-mini", "studio"])
        #expect(devices.first?.displayName == "Mac mini")
        #expect(devices.first?.os == "macOS")
    }

    @Test func quotesAndShellCharactersNeverReachTheTarget() throws {
        let devices = try TailscaleStatusParser.devices(from: TailscaleFixtures.status())
        for device in devices { #expect(TaildropArguments.isValidTarget(device.target)) }
        let studio = try #require(devices.first { $0.target == "studio" })
        #expect(studio.displayName.contains("Studio"))
    }

    @Test func fallsBackToAnSafeHostNameWithoutDNSName() throws {
        let json = #"{"BackendState":"Running","Self":{"UserID":1},"Peer":{"k":{"HostName":"nas-01","OS":"linux","UserID":1,"Online":true}}}"#
        #expect(try TailscaleStatusParser.devices(from: Data(json.utf8)).map(\.target) == ["nas-01"])
    }

    @Test func notRunningIsAnError() {
        #expect(throws: TailscaleStatusParser.Failure.notRunning("Stopped")) {
            try TailscaleStatusParser.devices(from: TailscaleFixtures.status(backend: "Stopped"))
        }
        #expect(throws: TailscaleStatusParser.Failure.notRunning("unknown")) {
            try TailscaleStatusParser.devices(from: TailscaleFixtures.status(backend: "bad state; $(x)"))
        }
    }

    @Test func missingSelfOrBrokenJSON() {
        #expect(throws: TailscaleStatusParser.Failure.noSelf) {
            try TailscaleStatusParser.devices(from: TailscaleFixtures.status(selfUser: nil))
        }
        #expect(throws: TailscaleStatusParser.Failure.notJSON) { try TailscaleStatusParser.devices(from: Data("nope".utf8)) }
        #expect(throws: TailscaleStatusParser.Failure.notJSON) { try TailscaleStatusParser.devices(from: Data()) }
    }
}

struct TaildropArgumentsTests {
    let devices = [TailscaleDevice(target: "mac-mini", displayName: "Mac mini", os: "macOS")]
    let file = URL(fileURLWithPath: "/tmp/OpenHuman-feedback-x/OpenHuman-feedback-20261012-101500.zip")

    @Test func buildsAFixedArray() throws {
        let args = try TaildropArguments.copy(file: file, to: "mac-mini", among: devices)
        #expect(args == ["file", "cp", "--update-interval=0", file.path, "mac-mini:"])
        #expect(TaildropArguments.statusArguments == ["status", "--json"])
    }

    @Test(arguments: ["", "-x", "--help", "a b", "a;b", "a$(b)", "a`b`", "a\"b", "a'b", "a:b", "a/b", "a\nb", "../x", "é", "mac-mini ",
                      String(repeating: "a", count: 64), ".hidden", "trailing-"])
    func rejectsUnsafeNames(_ name: String) {
        #expect(!TaildropArguments.isValidTarget(name))
        #expect(throws: TaildropArguments.Invalid.badName) { try TaildropArguments.copy(file: file, to: name, among: devices) }
    }

    @Test func acceptsOrdinaryNames() {
        for name in ["mac-mini", "Mac_mini2", "a", "host.tail1234", String(repeating: "a", count: 63)] {
            #expect(TaildropArguments.isValidTarget(name), "\(name)")
        }
    }

    @Test func aValidNameStillMustBeOnTheStatusList() {
        #expect(throws: TaildropArguments.Invalid.unknownDevice) { try TaildropArguments.copy(file: file, to: "other-host", among: devices) }
        #expect(throws: TaildropArguments.Invalid.unknownDevice) { try TaildropArguments.copy(file: file, to: "mac-mini", among: []) }
    }

    @Test func theFileMustBeAnAbsoluteFilePathWithoutControlCharacters() {
        #expect(throws: TaildropArguments.Invalid.badPath) {
            try TaildropArguments.copy(file: URL(fileURLWithPath: "/tmp/a\nb.zip"), to: "mac-mini", among: devices)
        }
        #expect(throws: TaildropArguments.Invalid.badPath) {
            try TaildropArguments.copy(file: URL(string: "https://example.com/a.zip")!, to: "mac-mini", among: devices)
        }
    }
}

#if os(macOS)
final class ManualRunClock: TailscaleRunClock, @unchecked Sendable {
    final class Entry: @unchecked Sendable {
        let deadline: TailscaleRunDeadline
        let delay: Duration
        private let lock = NSLock()
        private let fire: @Sendable () -> Void
        private var cancelled = false

        init(deadline: TailscaleRunDeadline, delay: Duration, fire: @escaping @Sendable () -> Void) {
            self.deadline = deadline
            self.delay = delay
            self.fire = fire
        }

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
        func pass() { if !isCancelled { fire() } }
    }

    let entries: AsyncStream<Entry>
    private let continuation: AsyncStream<Entry>.Continuation

    init() { (entries, continuation) = AsyncStream.makeStream() }

    func schedule(_ deadline: TailscaleRunDeadline, after delay: Duration,
                  _ fire: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let entry = Entry(deadline: deadline, delay: delay, fire: fire)
        continuation.yield(entry)
        return { entry.cancel() }
    }
}

final class SignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Int32] = []
    var sent: [Int32] { lock.withLock { log } }

    func send(_ pid: pid_t, _ signal: Int32) {
        lock.withLock { log.append(signal) }
        kill(pid, signal)
    }
}

struct TailscaleProcessRunnerTests {
    private func script(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oh-ts-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tailscale")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func readyPipe(beside script: URL) throws -> URL {
        let url = script.deletingLastPathComponent().appendingPathComponent("ready")
        guard mkfifo(url.path, 0o600) == 0 else { throw POSIXError(.EEXIST) }
        return url
    }

    private func contents(of pipe: URL) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = FileHandle(forReadingAtPath: pipe.path)?.readDataToEndOfFile() ?? Data()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    private func next(_ deadline: TailscaleRunDeadline,
                      _ scheduled: inout AsyncStream<ManualRunClock.Entry>.Iterator) async throws -> ManualRunClock.Entry {
        while let entry = await scheduled.next() {
            if entry.deadline == deadline { return entry }
        }
        throw CancellationError()
    }

    private func runner(_ url: URL, _ clock: ManualRunClock, _ signals: SignalLog = SignalLog()) -> TailscaleProcessRunner {
        TailscaleProcessRunner(executable: url, clock: clock, signal: { signals.send($0, $1) })
    }

    @Test func passesArgumentsExactlyWithoutAShell() async throws {
        let url = try script(#"for a in "$@"; do printf '%s\n' "$a"; done"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = try await runner(url, ManualRunClock()).run(arguments: ["a b", "$(echo hi)", ";x"], timeout: .seconds(10))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.output, as: UTF8.self) == "a b\n$(echo hi)\n;x\n")
    }

    @Test func reportsExitCodeAndErrorText() async throws {
        let url = try script("echo oops >&2; exit 3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = try await runner(url, ManualRunClock()).run(arguments: [], timeout: .seconds(10))
        #expect(result.exitCode == 3)
        #expect(result.errorText.contains("oops"))
    }

    @Test func atTheTimeoutTheProgramIsAskedToStop() async throws {
        let url = try script("echo ready > \"$1\"\nexec sleep 600")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ready = try readyPipe(beside: url)
        let clock = ManualRunClock(), signals = SignalLog()
        let run = Task { [runner = runner(url, clock, signals)] in try await runner.run(arguments: [ready.path], timeout: .seconds(5)) }
        #expect(await contents(of: ready) == "ready\n")
        var scheduled = clock.entries.makeAsyncIterator()
        let timeout = try await next(.timeout, &scheduled)
        #expect(timeout.delay == .seconds(5))
        timeout.pass()
        let forced = try await next(.kill, &scheduled)
        await #expect(throws: TailscaleRunError.timedOut) { try await run.value }
        #expect(signals.sent == [SIGTERM] && forced.isCancelled)
    }

    @Test func aProgramThatIgnoresTerminateIsKilledAfterTheGrace() async throws {
        let url = try script("trap '' TERM\necho ready > \"$1\"\nexec sleep 600")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ready = try readyPipe(beside: url)
        let clock = ManualRunClock(), signals = SignalLog()
        let run = Task { [runner = runner(url, clock, signals)] in try await runner.run(arguments: [ready.path], timeout: .seconds(5)) }
        #expect(await contents(of: ready) == "ready\n")
        var scheduled = clock.entries.makeAsyncIterator()
        try await next(.timeout, &scheduled).pass()
        let forced = try await next(.kill, &scheduled)
        #expect(forced.delay == TailscaleProcessRunner.killGrace)
        #expect(signals.sent == [SIGTERM])
        forced.pass()
        await #expect(throws: TailscaleRunError.timedOut) { try await run.value }
        #expect(signals.sent == [SIGTERM, SIGKILL])
    }

    @Test func cancellingTheRunStopsTheProgram() async throws {
        let url = try script("trap '' TERM\necho ready > \"$1\"\nexec sleep 600")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ready = try readyPipe(beside: url)
        let clock = ManualRunClock(), signals = SignalLog()
        let run = Task { [runner = runner(url, clock, signals)] in try await runner.run(arguments: [ready.path], timeout: .seconds(5)) }
        #expect(await contents(of: ready) == "ready\n")
        var scheduled = clock.entries.makeAsyncIterator()
        let timeout = try await next(.timeout, &scheduled)
        run.cancel()
        let forced = try await next(.kill, &scheduled)
        #expect(signals.sent == [SIGTERM])
        forced.pass()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(signals.sent == [SIGTERM, SIGKILL] && timeout.isCancelled)
    }

    @Test func aRunCancelledBeforeItStartsLaunchesNothing() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("oh-ts-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let url = try script("touch \"$1\"")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = ManualRunClock(), signals = SignalLog()
        let run = Task { [runner = runner(url, clock, signals)] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(arguments: [marker.path], timeout: .seconds(5))
        }
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path) && signals.sent.isEmpty)
    }

    @Test func outputHeldOpenByALeftoverChildStopsBeingReadAfterTheDrain() async throws {
        let url = try script("sleep 600 &\necho $! > \"$1\"\necho done")
        let pidFile = url.deletingLastPathComponent().appendingPathComponent("child.pid")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = ManualRunClock(), signals = SignalLog()
        let run = Task { [runner = runner(url, clock, signals)] in try await runner.run(arguments: [pidFile.path], timeout: .seconds(5)) }
        var scheduled = clock.entries.makeAsyncIterator()
        let drain = try await next(.drain, &scheduled)
        #expect(drain.delay == TailscaleProcessRunner.drainGrace)
        drain.pass()
        let result = try await run.value
        #expect(result.exitCode == 0 && signals.sent.isEmpty)
        let child = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid = pid_t(child) { kill(pid, SIGKILL) }
    }

    @Test func aMissingProgramFailsToLaunch() async {
        await #expect(throws: TailscaleRunError.launchFailed) {
            _ = try await TailscaleProcessRunner(executable: URL(fileURLWithPath: "/nonexistent/tailscale"), clock: ManualRunClock(),
                                                 signal: { _, _ in }).run(arguments: [], timeout: .seconds(1))
        }
    }
}
#endif
