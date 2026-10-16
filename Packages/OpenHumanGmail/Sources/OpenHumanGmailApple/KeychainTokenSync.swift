import Foundation
import OpenHumanCore
import OpenHumanGmail
import Security

public struct KeychainSharedGrantStore: SharedGrantStore {
    public static let label = "OpenHuman Mail (Gmail sign-in, shared through iCloud Keychain)"
    public let service: String
    public let accessGroup: String?
    public let items: KeychainItems
    var backend: any KeychainBackend { items.backend }
    public var canHoldSharedCopies: Bool { items.canHoldSynchronizableItems }
    let isAppProcess: @Sendable () -> Bool
    let log: CredentialChainLog

    static let maxItemBytes = 16 * 1024

    public init(service: String = OHIdentifiers.keychainService, accessGroup: String? = nil) {
        self.init(service: service, items: .shared, isAppProcess: { KeychainTokenStore.runningInAppBundle() },
                  accessGroup: accessGroup)
    }

    init(service: String, items: KeychainItems, isAppProcess: @escaping @Sendable () -> Bool,
         accessGroup: String? = nil, log: CredentialChainLog = .shared) {
        self.service = service
        self.items = items
        self.isAppProcess = isAppProcess
        self.accessGroup = accessGroup
        self.log = log
    }

    static let cannotSync: Set<OSStatus> = [errSecMissingEntitlement, errSecNotAvailable, errSecParam,
                                            errSecInteractionNotAllowed]

    public func read(account email: String) throws -> SharedGrantRead {
        try requireAppProcess()
        let account = try KeychainTokenStore.account(email)
        guard ready() else { return .unavailable }
        return try fetch(account: account, group: accessGroup)
    }

    @discardableResult
    public func save(_ grant: SharedGrant, account email: String) throws -> SharedGrantWrite {
        try requireAppProcess()
        let account = try KeychainTokenStore.account(email)
        guard ready() else { return .unavailable }
        guard grant.isUsable, let data = try? JSONEncoder().encode(grant), data.count <= Self.maxItemBytes else {
            throw TokenStoreError.corrupt
        }
        return try write(data, account: account).written
    }

    public func delete(account email: String) throws {
        try requireAppProcess()
        let account = try KeychainTokenStore.account(email)
        guard ready() else { return }
        let status = backend.delete(baseQuery(account: account))
        items.synchronizableRefused(status)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement
                || status == errSecNotAvailable else { throw TokenStoreError.keychain(status) }
    }

    public func allAccounts() throws -> [String] {
        try requireAppProcess()
        guard ready() else { return [] }
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
        let accounts = KeychainItems.listed(result).compactMap { item -> String? in
            guard let account = item[kSecAttrAccount as String] as? String,
                  isOurs(item, account: account, group: accessGroup),
                  (try? KeychainTokenStore.account(account)) == account else { return nil }
            return account
        }
        return Array(Set(accounts)).sorted()
    }

    func baseQuery(account: String?) -> [String: Any] { baseQuery(account: account, group: accessGroup) }

    func baseQuery(account: String?, group: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: true,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
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

    func isOurs(_ item: [String: Any], account: String, group: String? = nil) -> Bool {
        if let value = item[kSecAttrService as String], (value as? String) != service { return false }
        if let value = item[kSecAttrAccount as String], (value as? String) != account { return false }
        if let group, let value = item[kSecAttrAccessGroup as String], (value as? String) != group { return false }
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

    private func ready() -> Bool {
        guard items.canHoldSynchronizableItems else { return false }
        if let accessGroup {
            items.once("shared-grant|\(service)|\(accessGroup)") { _ = moveFromDefaultGroup(into: accessGroup) }
        }
        return items.canHoldSynchronizableItems
    }

    private func fetch(account: String, group: String?) throws -> SharedGrantRead {
        var query = baseQuery(account: account, group: group)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = backend.copyMatching(query)
        items.synchronizableRefused(status)
        KeychainDiagnostics.shared.record(.tokenSyncedRead, status == errSecItemNotFound ? errSecSuccess : status)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: return .missing
        case errSecMissingEntitlement, errSecNotAvailable:
            log.record(.entitlement, .noEntitlement)
            return .unavailable
        default:
            log.record(.readSignIn, .keychain(status: status), subject: CredentialChainLog.subject(account: account))
            throw TokenStoreError.keychain(status)
        }
        guard let item = Self.single(result), isOurs(item, account: account, group: group),
              let data = item[kSecValueData as String] as? Data, data.count <= Self.maxItemBytes,
              let grant = try? JSONDecoder().decode(SharedGrant.self, from: data), grant.isUsable else {
            log.record(.readSignIn, .unreadable, subject: CredentialChainLog.subject(account: account))
            throw TokenStoreError.corrupt
        }
        return .found(grant)
    }

    private func write(_ data: Data, account: String) throws -> (written: SharedGrantWrite, status: OSStatus) {
        let subject = CredentialChainLog.subject(account: account)
        func done(_ status: OSStatus) -> (written: SharedGrantWrite, status: OSStatus) {
            log.record(.shareSignIn, status == errSecSuccess ? .ok : KeychainItems.outcome(status), subject: subject)
            return (status == errSecSuccess ? .written : .unavailable, status)
        }
        func failed(_ status: OSStatus) -> TokenStoreError {
            log.record(.shareSignIn, KeychainItems.outcome(status), subject: subject)
            return TokenStoreError.keychain(status)
        }
        let attributes = addAttributes(account: account, data: data)
        let status = backend.add(attributes)
        items.synchronizableRefused(status)
        KeychainDiagnostics.shared.record(.tokenSyncedWrite, status == errSecDuplicateItem ? errSecSuccess : status)
        if status == errSecSuccess || Self.cannotSync.contains(status) { return done(status) }
        guard status == errSecDuplicateItem else { throw failed(status) }
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: Self.label]
        let updated = backend.update(baseQuery(account: account), changes)
        items.synchronizableRefused(updated)
        if updated == errSecSuccess { return done(updated) }
        guard updated == errSecUnimplemented else { throw failed(updated) }
        let deleted = backend.delete(baseQuery(account: account))
        items.synchronizableRefused(deleted)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw failed(deleted) }
        let again = backend.add(attributes)
        items.synchronizableRefused(again)
        guard again == errSecSuccess else { throw failed(again) }
        return done(again)
    }

    // Why: copies written before the shared group existed are invisible to the other app until they move into it
    @discardableResult
    func moveFromDefaultGroup(into group: String) -> Int {
        var list = baseQuery(account: nil, group: nil)
        list[kSecReturnAttributes as String] = true
        list[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = backend.copyMatching(list)
        items.synchronizableRefused(status)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound { log.record(.groupMove, KeychainItems.outcome(status)) }
            return 0
        }
        var moved = 0
        var seen = Set<String>()
        for item in KeychainItems.listed(result) {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let from = item[kSecAttrAccessGroup as String] as? String, from != group,
                  seen.insert(from + "\n" + account).inserted,
                  (try? KeychainTokenStore.account(account)) == account,
                  isOurs(item, account: account) else { continue }
            let outcome = move(account: account, from: from, into: group)
            log.record(.groupMove, outcome, subject: CredentialChainLog.subject(account: account))
            if outcome == .ok { moved += 1 }
        }
        return moved
    }

    // Why: the old copy is deleted only after the shared group holds this grant or a newer one
    private func move(account: String, from old: String, into group: String) -> CredentialOutcome {
        do {
            guard case .found(let grant) = try fetch(account: account, group: old) else { return .noItem }
            switch try fetch(account: account, group: group) {
            case .found(let kept) where kept.version >= grant.version:
                break
            case .unavailable:
                return .noEntitlement
            case .found, .missing:
                guard let data = try? JSONEncoder().encode(grant), data.count <= Self.maxItemBytes else {
                    return .unreadable
                }
                let written = try write(data, account: account)
                guard written.written == .written else { return KeychainItems.outcome(written.status) }
            }
            guard case .found(let now) = try fetch(account: account, group: group), now.version >= grant.version else {
                return .unreadable
            }
        } catch TokenStoreError.keychain(let status) {
            return KeychainItems.outcome(status)
        } catch {
            return .unreadable
        }
        let deleted = backend.delete(baseQuery(account: account, group: old))
        items.synchronizableRefused(deleted)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return KeychainItems.outcome(deleted) }
        return .ok
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
