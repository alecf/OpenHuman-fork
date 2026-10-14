import Foundation
import OpenHumanCore
import OpenHumanGmail
import Security

public struct KeychainSharedGrantStore: SharedGrantStore {
    public static let label = "OpenHuman Mail (Gmail sign-in, shared through iCloud Keychain)"
    public let service: String
    public let items: KeychainItems
    var backend: any KeychainBackend { items.backend }
    public var canHoldSharedCopies: Bool { items.canHoldSynchronizableItems }
    let isAppProcess: @Sendable () -> Bool

    static let maxItemBytes = 16 * 1024

    public init(service: String = OHIdentifiers.keychainService) {
        self.init(service: service, items: .shared, isAppProcess: { KeychainTokenStore.runningInAppBundle() })
    }

    init(service: String, items: KeychainItems, isAppProcess: @escaping @Sendable () -> Bool) {
        self.service = service
        self.items = items
        self.isAppProcess = isAppProcess
    }

    static let cannotSync: Set<OSStatus> = [errSecMissingEntitlement, errSecNotAvailable, errSecParam,
                                            errSecInteractionNotAllowed]

    public func read(account email: String) throws -> SharedGrantRead {
        try requireAppProcess()
        let account = try KeychainTokenStore.account(email)
        guard items.canHoldSynchronizableItems else { return .unavailable }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = backend.copyMatching(query)
        items.synchronizableRefused(status)
        KeychainDiagnostics.shared.record(.tokenSyncedRead, status == errSecItemNotFound ? errSecSuccess : status)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: return .missing
        case errSecMissingEntitlement, errSecNotAvailable: return .unavailable
        default: throw TokenStoreError.keychain(status)
        }
        guard let item = Self.single(result), isOurs(item, account: account),
              let data = item[kSecValueData as String] as? Data, data.count <= Self.maxItemBytes,
              let grant = try? JSONDecoder().decode(SharedGrant.self, from: data), grant.isUsable else {
            throw TokenStoreError.corrupt
        }
        return .found(grant)
    }

    @discardableResult
    public func save(_ grant: SharedGrant, account email: String) throws -> SharedGrantWrite {
        try requireAppProcess()
        let account = try KeychainTokenStore.account(email)
        guard items.canHoldSynchronizableItems else { return .unavailable }
        guard grant.isUsable, let data = try? JSONEncoder().encode(grant), data.count <= Self.maxItemBytes else {
            throw TokenStoreError.corrupt
        }
        let attributes = addAttributes(account: account, data: data)
        let status = backend.add(attributes)
        items.synchronizableRefused(status)
        KeychainDiagnostics.shared.record(.tokenSyncedWrite, status == errSecDuplicateItem ? errSecSuccess : status)
        if status == errSecSuccess { return .written }
        if Self.cannotSync.contains(status) { return .unavailable }
        guard status == errSecDuplicateItem else { throw TokenStoreError.keychain(status) }
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: Self.label]
        let updated = backend.update(baseQuery(account: account), changes)
        items.synchronizableRefused(updated)
        if updated == errSecSuccess { return .written }
        guard updated == errSecUnimplemented else { throw TokenStoreError.keychain(updated) }
        let deleted = backend.delete(baseQuery(account: account))
        items.synchronizableRefused(deleted)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw TokenStoreError.keychain(deleted) }
        let again = backend.add(attributes)
        items.synchronizableRefused(again)
        guard again == errSecSuccess else { throw TokenStoreError.keychain(again) }
        return .written
    }

    public func delete(account email: String) throws {
        try requireAppProcess()
        let account = try KeychainTokenStore.account(email)
        guard items.canHoldSynchronizableItems else { return }
        let status = backend.delete(baseQuery(account: account))
        items.synchronizableRefused(status)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement
                || status == errSecNotAvailable else { throw TokenStoreError.keychain(status) }
    }

    public func allAccounts() throws -> [String] {
        try requireAppProcess()
        guard items.canHoldSynchronizableItems else { return [] }
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = backend.copyMatching(query)
        items.synchronizableRefused(status)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound, errSecMissingEntitlement, errSecNotAvailable: return []
        default: throw TokenStoreError.keychain(status)
        }
        let listed = (result as? [[String: Any]]) ?? Self.single(result).map { [$0] } ?? []
        let accounts = listed.compactMap { item -> String? in
            guard let account = item[kSecAttrAccount as String] as? String, isOurs(item, account: account),
                  (try? KeychainTokenStore.account(account)) == account else { return nil }
            return account
        }
        return Array(Set(accounts)).sorted()
    }

    func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func addAttributes(account: String, data: Data) -> [String: Any] {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = Self.label
        return attributes
    }

    func isOurs(_ item: [String: Any], account: String) -> Bool {
        if let value = item[kSecAttrService as String], (value as? String) != service { return false }
        if let value = item[kSecAttrAccount as String], (value as? String) != account { return false }
        if let value = item[kSecAttrSynchronizable as String] {
            if let flag = value as? Bool { return flag }
            if let number = value as? NSNumber { return number.boolValue }
            return false
        }
        return true
    }

    static func single(_ result: CFTypeRef?) -> [String: Any]? {
        if let item = result as? [String: Any] { return item }
        return (result as? [[String: Any]])?.first
    }

    private func requireAppProcess() throws {
        guard isAppProcess() else { throw TokenStoreError.notAppProcess }
    }
}

public struct KeychainTokenDeviceStore: TokenDeviceRecordStore {
    public static let label = "OpenHuman Mail (Gmail sign-in, this device)"
    public static let serviceSuffix = ".device"
    public let tokenService: String
    public var legacyService: String { tokenService + Self.serviceSuffix }
    public let items: KeychainItems
    let isAppProcess: @Sendable () -> Bool
    static let maxItemBytes = 16 * 1024

    public init(tokenService: String = OHIdentifiers.keychainService) {
        self.init(tokenService: tokenService, items: .shared,
                  isAppProcess: { KeychainTokenStore.runningInAppBundle() })
    }

    init(tokenService: String, items: KeychainItems, isAppProcess: @escaping @Sendable () -> Bool) {
        self.tokenService = tokenService
        self.items = items
        self.isAppProcess = isAppProcess
    }

    private func tokenKey(_ account: String) -> KeychainItems.Item { .init(service: tokenService, account: account) }

    private func memoryKey(_ account: String) -> KeychainItems.Item { .init(service: legacyService, account: account) }

    private func payload(_ account: String) throws -> TokenItemPayload? {
        guard let entry = try items.read(tokenKey(account)), entry.data.count <= Self.maxItemBytes else { return nil }
        return try? JSONDecoder().decode(TokenItemPayload.self, from: entry.data)
    }

    public func load(account email: String) throws -> TokenDeviceRecord? {
        try requireAppProcess()
        let account = try KeychainTokenStore.account(email)
        return try tokenErrors {
            try items.exclusively {
                var record = (try? payload(account))?.device
                if record == nil, items.canHoldSynchronizableItems,
                   let entry = try items.read(memoryKey(account)) {
                    guard entry.data.count <= Self.maxItemBytes else { throw TokenStoreError.corrupt }
                    record = try? JSONDecoder().decode(TokenDeviceRecord.self, from: entry.data)
                }
                let memory = items.memory(memoryKey(account), as: TokenDeviceRecord.self)
                guard record != nil || memory != nil else { return nil }
                var result = record ?? TokenDeviceRecord()
                if let memory {
                    result.accessToken = memory.accessToken
                    result.accessTokenExpiry = memory.accessTokenExpiry
                    result.accessFor = memory.accessFor
                    if !items.canHoldSynchronizableItems { result.cannotSync = memory.cannotSync }
                }
                return result
            }
        }
    }

    public func save(_ record: TokenDeviceRecord, account email: String) throws {
        try requireAppProcess()
        let account = try KeychainTokenStore.account(email)
        guard let validation = try? JSONEncoder().encode(record), validation.count <= Self.maxItemBytes else {
            throw TokenStoreError.corrupt
        }
        try tokenErrors {
            try items.exclusively {
                let memory: TokenDeviceRecord? = record == TokenDeviceRecord() ? nil : record
                items.setMemory(memoryKey(account), memory)
                var persisted = record
                persisted.accessToken = nil
                persisted.accessTokenExpiry = nil
                persisted.accessFor = nil
                if !items.canHoldSynchronizableItems { persisted.cannotSync = nil }
                let section: TokenDeviceRecord? = persisted == TokenDeviceRecord() ? nil : persisted
                if var current = try payload(account) {
                    let hadSection = current.device != nil
                    if current.device != section {
                        current.device = section
                        let data = try current.encoded()
                        guard data.count <= Self.maxItemBytes else { throw TokenStoreError.corrupt }
                        try items.write(tokenKey(account), data: data, label: KeychainTokenStore.defaultLabel)
                    }
                    if !hadSection, items.canHoldSynchronizableItems, (try? items.read(memoryKey(account))) != nil {
                        try items.delete(memoryKey(account))
                        items.setMemory(memoryKey(account), memory)
                    }
                } else if let section, items.canHoldSynchronizableItems {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .sortedKeys
                    try items.write(memoryKey(account), data: encoder.encode(section), label: Self.label)
                }
            }
        }
    }

    public func delete(account email: String) throws {
        try requireAppProcess()
        let account = try KeychainTokenStore.account(email)
        try tokenErrors {
            try items.exclusively {
                if var current = try payload(account), current.device != nil {
                    current.device = nil
                    try items.write(tokenKey(account), data: current.encoded(), label: KeychainTokenStore.defaultLabel)
                }
                try items.delete(memoryKey(account))
                items.setMemory(memoryKey(account), nil)
            }
        }
    }

    private func requireAppProcess() throws {
        guard isAppProcess() else { throw TokenStoreError.notAppProcess }
    }
}
