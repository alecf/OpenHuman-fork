import Foundation

public enum TailscaleLocator {
    public static func candidatePaths(home: String) -> [String] {
        ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", home + "/.local/bin/tailscale",
         "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
    }

    public static func find(home: String = NSHomeDirectory(),
                            isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        candidatePaths(home: home).first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}

public struct TailscaleDevice: Sendable, Hashable, Identifiable {
    public let target: String
    public let displayName: String
    public let os: String

    public var id: String { target }

    public init(target: String, displayName: String, os: String) {
        self.target = target
        self.displayName = displayName
        self.os = os
    }
}

public enum TailscaleStatusParser {
    public enum Failure: Error, Equatable {
        case notJSON
        case notRunning(String)
        case noSelf
    }

    private struct Status: Decodable {
        var BackendState: String?
        var me: Node?
        var Peer: [String: Node]?
        enum CodingKeys: String, CodingKey { case BackendState, me = "Self", Peer }
    }

    struct Node: Decodable {
        var HostName: String?
        var DNSName: String?
        var OS: String?
        var Online: Bool?
        var UserID: Int?
    }

    public static func devices(from data: Data) throws -> [TailscaleDevice] {
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { throw Failure.notJSON }
        if let state = status.BackendState, state != "Running" { throw Failure.notRunning(TaildropArguments.codeLike(state)) }
        guard let me = status.me, let myUser = me.UserID else { throw Failure.noSelf }
        var seen = Set<String>()
        var devices: [TailscaleDevice] = []
        for node in (status.Peer ?? [:]).values {
            guard node.UserID == myUser, node.Online == true else { continue }
            let os = node.OS ?? ""
            guard os.lowercased() != "ios", os.lowercased() != "ipados" else { continue }
            guard let target = target(for: node), seen.insert(target).inserted else { continue }
            devices.append(TailscaleDevice(target: target, displayName: display(for: node, fallback: target),
                                           os: TaildropArguments.codeLike(os)))
        }
        return devices.sorted { ($0.displayName.lowercased(), $0.target) < ($1.displayName.lowercased(), $1.target) }
    }

    static func target(for node: Node) -> String? {
        if let dns = node.DNSName, let first = dns.split(separator: ".").first.map(String.init),
           TaildropArguments.isValidTarget(first) { return first }
        if let host = node.HostName, TaildropArguments.isValidTarget(host) { return host }
        return nil
    }

    static func display(for node: Node, fallback: String) -> String {
        let cleaned = (node.HostName ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? fallback : String(text.prefix(60))
    }
}

public enum TaildropArguments {
    public enum Invalid: Error, Equatable { case unknownDevice, badName, badPath }

    public static let statusArguments = ["status", "--json"]

    public static func isValidTarget(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard (1...63).contains(scalars.count), name.utf8.count == scalars.count else { return false }
        func alnum(_ s: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
        }
        guard let first = scalars.first, let last = scalars.last, alnum(first), alnum(last) else { return false }
        return scalars.allSatisfy { alnum($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    public static func copy(file: URL, to device: String, among devices: [TailscaleDevice]) throws -> [String] {
        guard isValidTarget(device) else { throw Invalid.badName }
        guard devices.contains(where: { $0.target == device }) else { throw Invalid.unknownDevice }
        let path = file.path
        guard file.isFileURL, path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw Invalid.badPath }
        return ["file", "cp", "--update-interval=0", path, device + ":"]
    }

    static func codeLike(_ value: String) -> String {
        let ok = value.count <= 32 && !value.isEmpty
            && value.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "_" || $0 == "." || $0 == "-" }
        return ok ? value : "unknown"
    }
}

public struct TailscaleRunResult: Sendable, Equatable {
    public var exitCode: Int32
    public var output: Data
    public var errorText: String

    public init(exitCode: Int32, output: Data = Data(), errorText: String = "") {
        self.exitCode = exitCode
        self.output = output
        self.errorText = errorText
    }
}

public enum TailscaleRunError: Error, Equatable {
    case timedOut
    case launchFailed
}

public protocol TailscaleRunning: Sendable {
    func run(arguments: [String], timeout: Duration) async throws -> TailscaleRunResult
}

protocol TailscaleRunClock: Sendable {
    func schedule(_ deadline: TailscaleRunDeadline, after delay: Duration,
                  _ fire: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

enum TailscaleRunDeadline: Sendable, Equatable {
    case timeout
    case kill
    case abandon
    case drain
}

struct DispatchRunClock: TailscaleRunClock {
    private final class Cancelled: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    func schedule(_ deadline: TailscaleRunDeadline, after delay: Duration,
                  _ fire: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let cancelled = Cancelled()
        let parts = delay.components
        let seconds = min(max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18), 86_400)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if !cancelled.isSet { fire() }
        }
        return { cancelled.set() }
    }
}

public struct TailscaleProcessRunner: TailscaleRunning {
    public let executable: URL
    let clock: any TailscaleRunClock
    let signal: @Sendable (pid_t, Int32) -> Void

    static let killGrace: Duration = .seconds(2)
    static let abandonGrace: Duration = .seconds(2)
    static let drainGrace: Duration = .seconds(1)

    public init(executable: URL) {
        self.init(executable: executable, clock: DispatchRunClock(), signal: { pid, signal in _ = Darwin.kill(pid, signal) })
    }

    init(executable: URL, clock: any TailscaleRunClock, signal: @escaping @Sendable (pid_t, Int32) -> Void) {
        self.executable = executable
        self.clock = clock
        self.signal = signal
    }

    public func run(arguments: [String], timeout: Duration) async throws -> TailscaleRunResult {
        #if os(macOS)
        try Task.checkCancellation()
        let run = TailscaleProcessRun(executable: executable, arguments: arguments, clock: clock, signal: signal)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            run.cancel()
        }
        #else
        throw TailscaleRunError.launchFailed
        #endif
    }
}

#if os(macOS)
final class TailscaleProcessRun: @unchecked Sendable {
    private enum Stop { case timedOut, cancelled }

    private let lock = NSLock()
    private let process = Process()
    private let clock: any TailscaleRunClock
    private let signal: @Sendable (pid_t, Int32) -> Void
    private var continuation: CheckedContinuation<TailscaleRunResult, Error>?
    private var cancelRequested = false
    private var launched = false
    private var exited = false
    private var abandoned = false
    private var finished = false
    private var stop: Stop?
    private var openStreams = 0
    private var readers: [DispatchIO] = []
    private var output = Data()
    private var errorOutput = Data()
    private var pendingDeadlines: [@Sendable () -> Void] = []

    init(executable: URL, arguments: [String], clock: any TailscaleRunClock, signal: @escaping @Sendable (pid_t, Int32) -> Void) {
        self.clock = clock
        self.signal = signal
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
    }

    func start(timeout: Duration, continuation: CheckedContinuation<TailscaleRunResult, Error>) {
        lock.lock()
        guard !cancelRequested else {
            finished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.terminationHandler = { [self] _ in processExited() }
        do {
            try process.run()
        } catch {
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: TailscaleRunError.launchFailed)
            return
        }
        launched = true
        for (pipe, isOutput) in [(out, true), (err, false)] {
            if let reader = read(pipe, isOutput: isOutput) {
                readers.append(reader)
                openStreams += 1
            }
        }
        lock.unlock()
        schedule(.timeout, after: timeout) { [self] in requestStop(.timedOut) }
    }

    func cancel() {
        let started = lock.withLock { () -> Bool in
            cancelRequested = true
            return launched
        }
        if started { requestStop(.cancelled) }
    }

    private func read(_ pipe: Pipe, isOutput: Bool) -> DispatchIO? {
        let descriptor = dup(pipe.fileHandleForReading.fileDescriptor)
        try? pipe.fileHandleForReading.close()
        guard descriptor >= 0 else { return nil }
        let io = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: .global(), cleanupHandler: { _ in close(descriptor) })
        io.setLimit(lowWater: 1)
        io.read(offset: 0, length: Int.max, queue: .global()) { [self] done, data, _ in
            if let data, !data.isEmpty {
                lock.withLock {
                    data.enumerateBytes { bytes, _, _ in
                        if isOutput { output.append(bytes) } else { errorOutput.append(bytes) }
                    }
                }
            }
            if done {
                io.close()
                streamEnded()
            }
        }
        return io
    }

    private func schedule(_ deadline: TailscaleRunDeadline, after delay: Duration, _ fire: @escaping @Sendable () -> Void) {
        let cancel = clock.schedule(deadline, after: delay, fire)
        let alreadyFinished = lock.withLock { () -> Bool in
            if finished { return true }
            pendingDeadlines.append(cancel)
            return false
        }
        if alreadyFinished { cancel() }
    }

    private func requestStop(_ reason: Stop) {
        enum Action { case none, stopReading, terminate(pid_t) }
        let action = lock.withLock { () -> Action in
            guard !finished else { return .none }
            if exited {
                if reason == .cancelled { stop = .cancelled }
                return .stopReading
            }
            guard stop == nil else { return .none }
            stop = reason
            return .terminate(process.processIdentifier)
        }
        switch action {
        case .none: break
        case .stopReading: stopReading()
        case .terminate(let pid):
            signal(pid, SIGTERM)
            schedule(.kill, after: TailscaleProcessRunner.killGrace) { [self] in forceKill() }
        }
    }

    private func forceKill() {
        let pid = lock.withLock { () -> pid_t? in finished || exited ? nil : process.processIdentifier }
        guard let pid else { return }
        signal(pid, SIGKILL)
        schedule(.abandon, after: TailscaleProcessRunner.abandonGrace) { [self] in
            lock.withLock { abandoned = true }
            stopReading()
            finishIfDone()
        }
    }

    private func processExited() {
        let draining = lock.withLock { () -> Bool in
            exited = true
            return openStreams > 0 && !finished
        }
        if draining { schedule(.drain, after: TailscaleProcessRunner.drainGrace) { [self] in stopReading() } }
        finishIfDone()
    }

    private func stopReading() {
        for io in lock.withLock({ readers }) { io.close(flags: .stop) }
    }

    private func streamEnded() {
        lock.withLock { openStreams -= 1 }
        finishIfDone()
    }

    private func finishIfDone() {
        let outcome = lock.withLock { () -> (CheckedContinuation<TailscaleRunResult, Error>, Result<TailscaleRunResult, Error>,
                                            [@Sendable () -> Void])? in
            guard !finished, exited || abandoned, openStreams == 0, let continuation else { return nil }
            finished = true
            self.continuation = nil
            let result: Result<TailscaleRunResult, Error>
            switch stop {
            case .timedOut: result = .failure(TailscaleRunError.timedOut)
            case .cancelled: result = .failure(CancellationError())
            case nil: result = .success(TailscaleRunResult(exitCode: process.terminationStatus, output: output,
                                                           errorText: String(decoding: errorOutput.prefix(8_192), as: UTF8.self)))
            }
            defer { pendingDeadlines = [] }
            return (continuation, result, pendingDeadlines)
        }
        guard let outcome else { return }
        for cancel in outcome.2 { cancel() }
        outcome.0.resume(with: outcome.1)
    }
}
#endif
