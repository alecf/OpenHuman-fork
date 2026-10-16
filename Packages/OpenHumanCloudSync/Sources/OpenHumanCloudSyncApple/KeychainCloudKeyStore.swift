#if canImport(Security)
import Foundation
import OpenHumanCloudSync
import Security

protocol CloudKeychainBackend: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SecItemCloudKeychainBackend: CloudKeychainBackend {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

// Why: synchronizable items travel end to end through iCloud Keychain; a delete reaches every device
public struct KeychainCloudKeyStore: CloudKeyStore {
    public static let defaultService = "dev.openhuman.mail.cloud-key.v1"
    public static let label = "OpenHuman Mail (iCloud data key)"

    public let service: String
    public let accessGroup: String?
    let backend: any CloudKeychainBackend

    public init(service: String = KeychainCloudKeyStore.defaultService, accessGroup: String? = nil) {
        self.init(service: service, accessGroup: accessGroup, backend: SecItemCloudKeychainBackend())
    }

    init(service: String, accessGroup: String?, backend: any CloudKeychainBackend) {
        self.service = service
        self.accessGroup = accessGroup
        self.backend = backend
    }

    public func loadKeys() throws -> [CloudKey] {
        var keys: [CloudKey] = []
        for account in try accounts() {
            var query = baseQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = backend.copyMatching(query)
            if status == errSecItemNotFound { continue }
            try Self.check(status)
            guard let material = result as? Data else { continue }
            let key = CloudKey(id: account, material: material)
            if key.isWellFormed { keys.append(key) }
        }
        return keys
    }

    public func save(_ key: CloudKey) throws {
        var attributes = baseQuery(account: key.id)
        attributes[kSecValueData as String] = key.material
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = Self.label
        let status = backend.add(attributes)
        if status == errSecDuplicateItem { return }
        try Self.check(status)
    }

    public func deleteAll() throws {
        for account in try accounts() {
            let status = backend.delete(baseQuery(account: account))
            if status == errSecItemNotFound { continue }
            try Self.check(status)
        }
    }

    func accounts() throws -> [String] {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = backend.copyMatching(query)
        if status == errSecItemNotFound { return [] }
        try Self.check(status)
        let items = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String }).sorted()
    }

    func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    static func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        if status == errSecMissingEntitlement || status == errSecNotAvailable || status == errSecInteractionNotAllowed {
            throw CloudKeyStoreError.unavailable(status: status)
        }
        throw CloudKeyStoreError.failed(status: status)
    }
}
#endif
