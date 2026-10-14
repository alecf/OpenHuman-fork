import Foundation
import Synchronization

public final class KeychainDiagnostics: Sendable {
    public static let shared = KeychainDiagnostics()

    public enum Operation: String, Sendable, CaseIterable, Comparable {
        case clientLocalRead = "client.local.read"
        case clientLocalWrite = "client.local.write"
        case clientLocalDelete = "client.local.delete"
        case clientSyncedRead = "client.synced.read"
        case clientSyncedWrite = "client.synced.write"
        case clientSyncedDelete = "client.synced.delete"
        case tokenLocalWrite = "token.local.write"
        case tokenSyncedRead = "token.synced.read"
        case tokenSyncedWrite = "token.synced.write"
        case tokenDeviceRecord = "token.device-record"

        public static func < (lhs: Operation, rhs: Operation) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private let last = Mutex<[Operation: Int32]>([:])

    public init() {}

    public func record(_ operation: Operation, _ status: Int32) {
        last.withLock { $0[operation] = status }
    }

    public func lastStatus(_ operation: Operation) -> Int32? { last.withLock { $0[operation] } }

    public func summary() -> String {
        let all = last.withLock { $0 }.sorted { $0.key < $1.key }
        guard !all.isEmpty else { return "none yet" }
        return all.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
    }
}
