import Crypto
import Foundation
import OpenHumanCore
import Synchronization

public struct SharedGrant: Codable, Sendable, Equatable {
    public var refreshToken: String
    public var clientID: String
    public var grantedScopes: [String]
    public var version: Int

    public init(refreshToken: String, clientID: String, grantedScopes: [String], version: Int) {
        self.refreshToken = refreshToken
        self.clientID = clientID
        self.grantedScopes = grantedScopes
        self.version = version
    }

    public var isUsable: Bool { !refreshToken.isEmpty && !clientID.isEmpty && version > 0 }
}

public enum SharedGrantRead: Sendable, Equatable {
    case found(SharedGrant)
    case missing
    case unavailable
}

public enum SharedGrantWrite: Sendable, Equatable {
    case written
    case unavailable
}

public protocol SharedGrantStore: Sendable {
    var canHoldSharedCopies: Bool { get }
    func read(account email: String) throws -> SharedGrantRead
    @discardableResult
    func save(_ grant: SharedGrant, account email: String) throws -> SharedGrantWrite
    func delete(account email: String) throws
    func allAccounts() throws -> [String]
}

extension SharedGrantStore {
    public var canHoldSharedCopies: Bool { true }
}

public struct TokenDeviceRecord: Codable, Sendable, Equatable {
    public enum Choice: String, Codable, Sendable {
        case dontSync
        case ownSignIn
    }

    public var choice: Choice?
    public var cannotSync: Bool?
    public var accessToken: String?
    public var accessTokenExpiry: Date?
    public var accessFor: String?
    public var wrote: String?
    public var refused: String?

    public init(choice: Choice? = nil, cannotSync: Bool? = nil, accessToken: String? = nil, accessTokenExpiry: Date? = nil,
                accessFor: String? = nil, wrote: String? = nil, refused: String? = nil) {
        self.choice = choice
        self.cannotSync = cannotSync
        self.accessToken = accessToken
        self.accessTokenExpiry = accessTokenExpiry
        self.accessFor = accessFor
        self.wrote = wrote
        self.refused = refused
    }
}

public protocol TokenDeviceRecordStore: Sendable {
    func load(account email: String) throws -> TokenDeviceRecord?
    func save(_ record: TokenDeviceRecord, account email: String) throws
    func delete(account email: String) throws
}

public final class InMemorySharedGrantStore: SharedGrantStore {
    private struct State {
        var items: [String: SharedGrant] = [:]
        var available: Bool
        var failWrites = false
        var failReads = false
        var writes = 0
    }
    private let state: Mutex<State>

    public var canHoldSharedCopies: Bool { state.withLock { $0.available } }

    public init(available: Bool = true) { state = Mutex(State(available: available)) }

    public func setAvailable(_ available: Bool) { state.withLock { $0.available = available } }
    public func failWrites(_ fail: Bool) { state.withLock { $0.failWrites = fail } }
    public func failReads(_ fail: Bool) { state.withLock { $0.failReads = fail } }
    public var writeCount: Int { state.withLock { $0.writes } }
    public func peek(_ email: String) -> SharedGrant? { state.withLock { $0.items[email.lowercased()] } }
    public func deliver(_ grant: SharedGrant?, account email: String) {
        state.withLock { $0.items[email.lowercased()] = grant }
    }

    public func read(account email: String) throws -> SharedGrantRead {
        let key = try normalizedAccount(email)
        return try state.withLock { s in
            if s.failReads { throw TokenStoreError.keychain(-34018) }
            guard s.available else { return .unavailable }
            return s.items[key].map { .found($0) } ?? .missing
        }
    }

    @discardableResult
    public func save(_ grant: SharedGrant, account email: String) throws -> SharedGrantWrite {
        let key = try normalizedAccount(email)
        return try state.withLock { s in
            if s.failWrites { throw TokenStoreError.keychain(-25308) }
            guard s.available else { return .unavailable }
            s.writes += 1
            s.items[key] = grant
            return .written
        }
    }

    public func delete(account email: String) throws {
        let key = try normalizedAccount(email)
        _ = state.withLock { $0.items.removeValue(forKey: key) }
    }

    public func allAccounts() throws -> [String] {
        state.withLock { s in s.available ? s.items.keys.sorted() : [] }
    }
}

public final class InMemoryTokenDeviceStore: TokenDeviceRecordStore {
    private let records = Mutex<[String: TokenDeviceRecord]>([:])

    public init() {}

    public func load(account email: String) throws -> TokenDeviceRecord? {
        let key = try normalizedAccount(email)
        return records.withLock { $0[key] }
    }

    public func save(_ record: TokenDeviceRecord, account email: String) throws {
        let key = try normalizedAccount(email)
        records.withLock { $0[key] = record }
    }

    public func delete(account email: String) throws {
        let key = try normalizedAccount(email)
        _ = records.withLock { $0.removeValue(forKey: key) }
    }
}

func tokenFingerprint(_ refreshToken: String) -> String {
    SHA256.hash(data: Data(("openhuman.token-sync.v1:" + refreshToken).utf8)).prefix(16)
        .map { String(format: "%02x", $0) }.joined()
}
