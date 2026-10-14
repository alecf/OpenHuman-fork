import Foundation

public struct ProcessIdentity: Hashable, Sendable {
    public let writerID: String
    public let pid: Int32
    public let host: String

    public init(writerID: String, pid: Int32, host: String) {
        self.writerID = writerID
        self.pid = pid
        self.host = host
    }

    public static let current = ProcessIdentity(
        writerID: UUID().uuidString.lowercased(),
        pid: ProcessInfo.processInfo.processIdentifier,
        host: localHostName
    )

    public static var localHostName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return ProcessInfo.processInfo.hostName }
        return String(cString: buffer)
    }
}
