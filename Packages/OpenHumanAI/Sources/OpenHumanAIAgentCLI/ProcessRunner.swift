import Foundation
import OpenHumanAI
import Synchronization

public struct ProcessSpec: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var stdin: Data
    public var environment: [String: String]
    public var workingDirectory: URL
    public var timeout: Duration
    public var maxStdoutBytes: Int
    public var maxStderrBytes: Int
    public var killGrace: Duration

    public init(
        executable: URL, arguments: [String], stdin: Data = Data(), environment: [String: String] = [:],
        workingDirectory: URL, timeout: Duration, maxStdoutBytes: Int = AIPolicy.outputByteCap,
        maxStderrBytes: Int = 64 * 1024, killGrace: Duration = .seconds(3)
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.maxStdoutBytes = maxStdoutBytes
        self.maxStderrBytes = maxStderrBytes
        self.killGrace = killGrace
    }
}

public struct ProcessResult: Sendable, Hashable {
    public var exitCode: Int32
    public var stderr: String
}

public enum ProcessEvent: Sendable, Hashable {
    case stdoutLine(String)
    case exited(ProcessResult)
}

public enum ProcessRunner {
    public static func run(_ spec: ProcessSpec) -> AsyncThrowingStream<ProcessEvent, Error> {
        ignoreSIGPIPE()
        let session = ProcessSession(spec: spec)
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in session.cancel() }
            session.start(continuation)
        }
    }

    public static func collect(_ spec: ProcessSpec) async throws -> (lines: [String], result: ProcessResult) {
        var lines: [String] = []
        var result: ProcessResult?
        for try await event in run(spec) {
            switch event {
            case .stdoutLine(let line): lines.append(line)
            case .exited(let exit): result = exit
            }
        }
        guard let result else { throw AIError.providerFailed("process ended without an exit status") }
        return (lines, result)
    }

    private static let sigpipeOnce: Void = { signal(SIGPIPE, SIG_IGN) }()
    private static func ignoreSIGPIPE() { _ = sigpipeOnce }
}

private final class ProcessSession: @unchecked Sendable {
    struct State {
        var started = false
        var stdoutBuffer = Data()
        var stdoutBytes = 0
        var stderr = Data()
        var stdoutEnded = false
        var stderrEnded = false
        var exited = false
        var exitCode: Int32 = 0
        var finished = false
        var failure: AIError?
        var continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation?
        var helpers: [Task<Void, Never>] = []
    }

    private let spec: ProcessSpec
    private let process = Process()
    private let state = Mutex(State())

    init(spec: ProcessSpec) { self.spec = spec }

    func start(_ continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation) {
        state.withLock { $0.continuation = continuation }
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.workingDirectory
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutDidEnd()
            } else {
                stdoutDidReceive(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                state.withLock { $0.stderrEnded = true }
                finishIfDone()
            } else {
                state.withLock { state in
                    let room = spec.maxStderrBytes - state.stderr.count
                    if room > 0 { state.stderr.append(data.prefix(room)) }
                }
            }
        }
        process.terminationHandler = { [self] process in processDidExit(process.terminationStatus) }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            fail(.providerFailed("could not start the process"))
            return
        }
        state.withLock { $0.started = true }

        let payload = spec.stdin
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: payload)
            try? writer.close()
        }
        let timeout = Task { [self] in
            try? await Task.sleep(for: spec.timeout)
            guard !Task.isCancelled else { return }
            terminate(reason: .timeout)
        }
        state.withLock { $0.helpers.append(timeout) }
    }

    func cancel() { terminate(reason: .cancelled) }

    private func stdoutDidReceive(_ data: Data) {
        var lines: [String] = []
        var overflow = false
        let continuation: AsyncThrowingStream<ProcessEvent, Error>.Continuation? = state.withLock { state in
            state.stdoutBytes += data.count
            if state.stdoutBytes > spec.maxStdoutBytes {
                overflow = true
                return state.continuation
            }
            state.stdoutBuffer.append(data)
            while let newline = state.stdoutBuffer.firstIndex(of: 0x0A) {
                let line = state.stdoutBuffer[state.stdoutBuffer.startIndex..<newline]
                lines.append(String(decoding: line, as: UTF8.self))
                state.stdoutBuffer.removeSubrange(state.stdoutBuffer.startIndex...newline)
            }
            return state.continuation
        }
        if overflow {
            terminate(reason: .invalidOutput("The output was larger than the allowed limit."))
            return
        }
        for line in lines { continuation?.yield(.stdoutLine(line)) }
    }

    private func stdoutDidEnd() {
        let (continuation, rest): (AsyncThrowingStream<ProcessEvent, Error>.Continuation?, String?) = state.withLock { state in
            state.stdoutEnded = true
            guard !state.stdoutBuffer.isEmpty, state.failure == nil else { return (state.continuation, nil) }
            let rest = String(decoding: state.stdoutBuffer, as: UTF8.self)
            state.stdoutBuffer = Data()
            return (state.continuation, rest)
        }
        if let rest { continuation?.yield(.stdoutLine(rest)) }
        finishIfDone()
    }

    private func processDidExit(_ status: Int32) {
        state.withLock { state in
            state.exited = true
            state.exitCode = status
        }
        finishIfDone()
        let straggler = Task { [self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            forceFinish()
        }
        state.withLock { $0.helpers.append(straggler) }
    }

    private func finishIfDone() {
        let done = state.withLock { $0.exited && $0.stdoutEnded && $0.stderrEnded && !$0.finished }
        if done { complete() }
    }

    private func forceFinish() {
        let exited = state.withLock { $0.exited && !$0.finished }
        if exited { complete() }
    }

    private func complete() {
        let outcome: (AsyncThrowingStream<ProcessEvent, Error>.Continuation?, AIError?, ProcessResult, [Task<Void, Never>])? =
            state.withLock { state in
                guard !state.finished else { return nil }
                state.finished = true
                let result = ProcessResult(exitCode: state.exitCode, stderr: String(decoding: state.stderr, as: UTF8.self))
                defer { state.continuation = nil }
                return (state.continuation, state.failure, result, state.helpers)
            }
        guard let (continuation, failure, result, helpers) = outcome else { return }
        for helper in helpers { helper.cancel() }
        closePipes()
        if let failure {
            continuation?.finish(throwing: failure)
        } else {
            continuation?.yield(.exited(result))
            continuation?.finish()
        }
    }

    private func closePipes() {
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? (process.standardOutput as? Pipe)?.fileHandleForReading.close()
        try? (process.standardError as? Pipe)?.fileHandleForReading.close()
    }

    private func fail(_ error: AIError) {
        let continuation = state.withLock { state -> AsyncThrowingStream<ProcessEvent, Error>.Continuation? in
            guard !state.finished else { return nil }
            state.finished = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.finish(throwing: error)
    }

    private func terminate(reason: AIError) {
        let shouldKill: Bool = state.withLock { state in
            guard state.started, !state.exited, !state.finished else { return false }
            if state.failure == nil { state.failure = reason }
            return true
        }
        guard shouldKill else {
            state.withLock { if $0.failure == nil, !$0.finished { $0.failure = reason } }
            return
        }
        process.terminate()
        let pid = process.processIdentifier
        let grace = spec.killGrace
        let hardKill = Task { [self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            let stillRunning = state.withLock { !$0.exited }
            if stillRunning { _ = Foundation.kill(pid, SIGKILL) }
        }
        state.withLock { $0.helpers.append(hardKill) }
    }
}
