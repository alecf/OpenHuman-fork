import Foundation
import OpenHumanCore
import OpenHumanStore
#if canImport(Darwin)
import Darwin
#endif

public protocol OutputSink: Sendable {
    func write(_ text: String)
}

public struct FileSink: OutputSink {
    let descriptor: Int32
    public init(descriptor: Int32) { self.descriptor = descriptor }
    public func write(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            bytes = bytes.dropFirst(n)
        }
    }
}

public final class BufferSink: OutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    public init() {}
    public func write(_ text: String) { lock.lock(); storage += text; lock.unlock() }
    public var text: String { lock.lock(); defer { lock.unlock() }; return storage }
}

public struct CLIEnvironment: Sendable {
    public var variables: [String: String]
    public var stdout: any OutputSink
    public var stderr: any OutputSink
    public var stdoutIsTTY: Bool
    public var stdinIsTTY: Bool
    public var clock: any OHClock
    public var timeZone: TimeZone
    public var nonce: @Sendable () -> String
    public var readStdin: @Sendable () -> String
    public var readLine: @Sendable () -> String?
    public var openURL: @Sendable (URL) throws -> Void
    public var storeProvider: (@Sendable (Bool) throws -> MailStore)?
    public var appVersion: String

    public init(variables: [String: String], stdout: any OutputSink, stderr: any OutputSink, stdoutIsTTY: Bool,
                stdinIsTTY: Bool, clock: any OHClock = SystemClock(), timeZone: TimeZone = .current,
                nonce: @escaping @Sendable () -> String = UntrustedWrapper.makeNonce,
                readStdin: @escaping @Sendable () -> String = { "" },
                readLine: @escaping @Sendable () -> String? = { nil },
                openURL: @escaping @Sendable (URL) throws -> Void = { _ in },
                storeProvider: (@Sendable (Bool) throws -> MailStore)? = nil, appVersion: String = OpenHumanCLIVersion.current) {
        self.variables = variables
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutIsTTY = stdoutIsTTY
        self.stdinIsTTY = stdinIsTTY
        self.clock = clock
        self.timeZone = timeZone
        self.nonce = nonce
        self.readStdin = readStdin
        self.readLine = readLine
        self.openURL = openURL
        self.storeProvider = storeProvider
        self.appVersion = appVersion
    }

    public static let live = CLIEnvironment(
        variables: ProcessInfo.processInfo.environment,
        stdout: FileSink(descriptor: STDOUT_FILENO), stderr: FileSink(descriptor: STDERR_FILENO),
        stdoutIsTTY: isatty(STDOUT_FILENO) != 0, stdinIsTTY: isatty(STDIN_FILENO) != 0,
        readStdin: { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) },
        readLine: { Swift.readLine() },
        openURL: { url in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url.absoluteString]
            try process.run()
        })

    @TaskLocal public static var current: CLIEnvironment = .live
}

public enum OpenHumanCLIVersion {
    public static let current = "0.1.0"
}
