import Foundation
import MailModel
import OpenHumanCore
import Security

public struct KeychainSecretStore: SecretStoring {
    public static let service = OHIdentifiers.prefix + ".secrets.v1"

    let backend: any SecretKeychainBackend

    public init() {
        self.init(backend: SecItemSecretBackend())
    }

    init(backend: any SecretKeychainBackend) {
        self.backend = backend
    }

    public func setSecret(_ value: String, for name: String) throws {
        let attributes = addAttributes(name, data: Data(value.utf8))
        var status = backend.add(attributes)
        if status == errSecDuplicateItem {
            // Delete and re-add instead of updating, so the new item gets this app's own ACL and accessibility
            let deleted = backend.delete(baseQuery(name))
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
                throw KeychainError(status: deleted)
            }
            status = backend.add(attributes)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func hasSecret(for name: String) -> Bool {
        var query = baseQuery(name)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = backend.copyMatching(query)
        guard status == errSecSuccess, let item = result as? [String: Any] else { return false }
        return isOurs(item, name: name)
    }

    public func removeSecret(for name: String) throws {
        let status = backend.delete(baseQuery(name))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    func baseQuery(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: name, kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: false]
    }

    func addAttributes(_ name: String, data: Data) -> [String: Any] {
        var attributes = baseQuery(name)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "OpenHuman Mail (AI provider key)"
        return attributes
    }

    func isOurs(_ item: [String: Any], name: String) -> Bool {
        if let value = item[kSecAttrService as String], (value as? String) != Self.service { return false }
        if let value = item[kSecAttrAccount as String], (value as? String) != name { return false }
        if let value = item[kSecAttrSynchronizable as String] {
            if let flag = value as? Bool, flag { return false }
            if let number = value as? NSNumber, number.boolValue { return false }
            if let string = value as? String, string != "0" { return false }
        }
        return true
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status)" }
}

protocol SecretKeychainBackend: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SecItemSecretBackend: SecretKeychainBackend {
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
