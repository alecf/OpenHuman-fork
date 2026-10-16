import Crypto
import Foundation

public struct CloudKey: Sendable, Hashable {
    public let id: String
    public let material: Data

    public init(id: String, material: Data) {
        self.id = id
        self.material = material
    }

    public static func generate() -> CloudKey {
        let material = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let id = SymmetricKey(size: .bits128).withUnsafeBytes { CloudCanonical.hex($0) }
        return CloudKey(id: id, material: material)
    }

    public var isWellFormed: Bool {
        material.count == 32 && !id.isEmpty && id.utf8.count <= 64
            && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D }
    }
}

public enum CloudKeyStoreError: Error, Sendable, Hashable {
    case unavailable(status: Int32)
    case failed(status: Int32)

    public var code: String {
        switch self {
        case .unavailable: return "keychainUnavailable"
        case .failed: return "keychainFailed"
        }
    }

    public var status: Int32 {
        switch self {
        case .unavailable(let status), .failed(let status): return status
        }
    }
}

public protocol CloudKeyStore: Sendable {
    func loadKeys() throws -> [CloudKey]
    // Never replaces a key that already has this id
    func save(_ key: CloudKey) throws
    func deleteAll() throws
}

struct CloudKeyring {
    private let store: any CloudKeyStore
    private let makeKey: @Sendable () -> CloudKey
    private(set) var keys: [String: CloudKey] = [:]

    init(store: any CloudKeyStore, makeKey: @escaping @Sendable () -> CloudKey) {
        self.store = store
        self.makeKey = makeKey
    }

    @discardableResult
    mutating func reload() throws -> Set<String> {
        let before = Set(keys.keys)
        var loaded: [String: CloudKey] = [:]
        for key in try store.loadKeys() where key.isWellFormed && loaded[key.id] == nil {
            loaded[key.id] = key
        }
        keys = loaded
        return Set(loaded.keys).subtracting(before)
    }

    mutating func key(id: String) throws -> CloudKey? {
        if let key = keys[id] { return key }
        try reload()
        return keys[id]
    }

    // Why: every device picks the smallest id it knows, so after a creation race all devices write under one key
    mutating func writingKey() throws -> (key: CloudKey, created: Bool) {
        if keys.isEmpty { try reload() }
        if let key = keys.values.min(by: { $0.id < $1.id }) { return (key, false) }
        let key = makeKey()
        try store.save(key)
        keys[key.id] = key
        return (key, true)
    }

    mutating func deleteAll() throws {
        try store.deleteAll()
        keys = [:]
    }
}
