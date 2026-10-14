import Foundation
import Security

public final class KeychainItems: @unchecked Sendable {
    public static let shared = KeychainItems(backend: SecItemBackend(),
                                             canHoldSynchronizableItems: entitledForSynchronizableItems())

    struct Item: Hashable, Sendable { var service: String; var account: String }

    struct Entry: Sendable, Equatable { var data: Data; var modifiedAt: Date? }

    private enum Cached { case absent; case present(Entry) }

    private let lock = NSRecursiveLock()

    let backend: any KeychainBackend

    private var canSync: Bool

    private var entries: [Item: Cached] = [:]

    private var lists: [String: Set<String>] = [:]

    private var values: [Item: any Sendable] = [:]

    init(backend: any KeychainBackend, canHoldSynchronizableItems: Bool = true) {
        self.backend = backend
        canSync = canHoldSynchronizableItems
    }

    public var canHoldSynchronizableItems: Bool { exclusively { canSync } }

    func synchronizableRefused(_ status: OSStatus) {
        exclusively {
            if status == errSecMissingEntitlement || status == errSecNotAvailable { canSync = false }
        }
    }

    func exclusively<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func memory<T: Sendable>(_ item: Item, as type: T.Type) -> T? { exclusively { values[item] as? T } }

    func setMemory(_ item: Item, _ value: (any Sendable)?) { exclusively { values[item] = value } }

    func query(service: String, account: String? = nil) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: false]
        if let account { result[kSecAttrAccount as String] = account }
        return result
    }

    func addAttributes(_ item: Item, data: Data, label: String) -> [String: Any] {
        var attributes = query(service: item.service, account: item.account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = label
        return attributes
    }

    private func ours(_ attributes: [String: Any], service: String, account: String) -> Bool {
        if let value = attributes[kSecAttrService as String], value as? String != service { return false }
        if let value = attributes[kSecAttrAccount as String], value as? String != account { return false }
        if let value = attributes[kSecAttrSynchronizable as String] {
            if let flag = value as? Bool { return !flag }
            if let number = value as? NSNumber { return !number.boolValue }
            if let string = value as? String { return string == "0" }
            return false
        }
        return true
    }

    func read(_ item: Item) throws -> Entry? {
        try exclusively {
            if let cached = entries[item] {
                switch cached { case .absent: return nil; case .present(let entry): return entry }
            }
            var request = query(service: item.service, account: item.account)
            request[kSecReturnData as String] = true
            request[kSecReturnAttributes as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = backend.copyMatching(request)
            if status == errSecItemNotFound { entries[item] = .absent; return nil }
            guard status == errSecSuccess else { throw KeychainItemsError.status(status) }
            guard let attributes = KeychainSharedGrantStore.single(result),
                  ours(attributes, service: item.service, account: item.account),
                  let data = attributes[kSecValueData as String] as? Data else { throw KeychainItemsError.notOurs }
            let entry = Entry(data: data, modifiedAt: attributes[kSecAttrModificationDate as String] as? Date)
            entries[item] = .present(entry)
            return entry
        }
    }

    func write(_ item: Item, data: Data, label: String) throws {
        try exclusively {
            if case .present(let entry) = entries[item], entry.data == data { return }
            let request = query(service: item.service, account: item.account)
            let attributes = addAttributes(item, data: data, label: label)
            do {
                if case .present = entries[item] {
                    let status = backend.delete(request)
                    guard status == errSecSuccess || status == errSecItemNotFound else {
                        throw KeychainItemsError.status(status)
                    }
                }
                var status = backend.add(attributes)
                if status == errSecDuplicateItem {
                    let deleted = backend.delete(request)
                    guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
                        throw KeychainItemsError.status(deleted)
                    }
                    status = backend.add(attributes)
                }
                guard status == errSecSuccess else { throw KeychainItemsError.status(status) }
                entries[item] = .present(Entry(data: data, modifiedAt: Date()))
                if lists[item.service] != nil { lists[item.service]?.insert(item.account) }
            } catch { entries[item] = nil; throw error }
        }
    }

    func delete(_ item: Item) throws {
        try exclusively {
            let status = backend.delete(query(service: item.service, account: item.account))
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainItemsError.status(status)
            }
            entries[item] = .absent
            values[item] = nil
            lists[item.service]?.remove(item.account)
        }
    }

    func accounts(service: String) throws -> [String] {
        try exclusively {
            if let cached = lists[service] { return cached.sorted() }
            var request = query(service: service)
            request[kSecReturnAttributes as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitAll
            let (status, result) = backend.copyMatching(request)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainItemsError.status(status)
            }
            let attributes = (result as? [[String: Any]]) ?? KeychainSharedGrantStore.single(result).map { [$0] } ?? []
            let accounts = Set(attributes.compactMap { attributes -> String? in
                guard let account = attributes[kSecAttrAccount as String] as? String,
                      ours(attributes, service: service, account: account) else { return nil }
                return account
            })
            lists[service] = accounts
            return accounts.sorted()
        }
    }

    static func entitledForSynchronizableItems() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
            || SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil
        #else
        return true
        #endif
    }
}

enum KeychainItemsError: Error, Equatable { case status(OSStatus); case notOurs }
