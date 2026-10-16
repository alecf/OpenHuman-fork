import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class TemporaryDirectory: Sendable {
    public let url: URL

    public init(_ prefix: String, isDirectory: Bool = false) {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: isDirectory)
    }

    public var path: String { url.path }

    public func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    // Why: a suite or harness that stores one removes the folder when the test releases it
    deinit { cleanup() }
}

extension TemporaryDirectory {
    // Why: a folder that must last as long as its process is named `<prefix><pid>-<UUID>`,
    // so the next caller removes the ones whose process has exited
    public static func processScoped(_ prefix: String, in root: URL = FileManager.default.temporaryDirectory,
                                     isRunning: (pid_t) -> Bool = TemporaryDirectory.processIsRunning) -> URL {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(prefix) {
            let owner = name.dropFirst(prefix.count)
            guard let dash = owner.firstIndex(of: "-"), let pid = pid_t(owner[..<dash]), pid > 0,
                  UUID(uuidString: String(owner[owner.index(after: dash)...])) != nil, !isRunning(pid) else { continue }
            try? fm.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
        return root.appendingPathComponent("\(prefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
    }

    public static func processIsRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }
}
