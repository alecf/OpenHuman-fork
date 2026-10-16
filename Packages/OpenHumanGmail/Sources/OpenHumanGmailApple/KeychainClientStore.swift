import Foundation
import OpenHumanCore
import OpenHumanGmail
import Security

public struct KeychainClientStore: OAuthClientStore {
    public static let service = OHIdentifiers.prefix + ".oauth-client.v1"
    public static let label = "OpenHuman Mail (Google sign-in client)"

    let service: String
    public let accessGroup: String?
    public let items: KeychainItems
    var backend: any KeychainBackend { items.backend }
    let isAppProcess: @Sendable () -> Bool
    let diagnostics: KeychainDiagnostics
    let log: CredentialChainLog

    static let maxItemBytes = 8 * 1024

    public var canHoldSharedCopies: Bool { items.canHoldSynchronizableItems }

    public init(service: String = KeychainClientStore.service, accessGroup: String? = nil) {
        self.init(service: service, items: .shared, isAppProcess: { KeychainTokenStore.runningInAppBundle() },
                  accessGroup: accessGroup)
    }

    init(service: String, items: KeychainItems, isAppProcess: @escaping @Sendable () -> Bool,
         diagnostics: KeychainDiagnostics = .shared, accessGroup: String? = nil, log: CredentialChainLog = .shared) {
        self.service = service
        self.items = items
        self.isAppProcess = isAppProcess
        self.diagnostics = diagnostics
        self.accessGroup = accessGroup
        self.log = log
    }

    private struct Payload: Codable {
        var clientID: String
        var clientSecret: String?
        var isDefault: Bool
        var wantsSync: Bool?
        var shared: Bool?
    }

    private struct Found {
        var payload: Payload
        var synchronizable: Bool
        var modifiedAt: Date?
    }

    public func loadAll() throws -> [StoredOAuthClient] {
        try requireAppProcess()
        moveOnce()
        let local = read(.login)
        let synced = read(.dataProtection)
        var byKey: [String: StoredOAuthClient] = [:]
        for (key, item) in local.items {
            let syncedCopy = synced.items[key]
            let sync: OAuthClientSyncState = syncedCopy?.synchronizable == true ? .syncing
                : (item.payload.wantsSync == true ? .unavailable : .notSyncing)
            byKey[key] = StoredOAuthClient(config: Self.config(item.payload), isDefault: item.payload.isDefault,
                                           sync: sync, modifiedAt: item.modifiedAt ?? syncedCopy?.modifiedAt,
                                           wasShared: item.payload.shared == true)
        }
        for (key, item) in synced.items where byKey[key] == nil {
            byKey[key] = StoredOAuthClient(config: Self.config(item.payload), isDefault: item.payload.isDefault,
                                           sync: item.synchronizable ? .syncing : .notSyncing, modifiedAt: item.modifiedAt,
                                           isLocal: false)
        }
        if byKey.isEmpty, let failure = local.failure {
            throw OAuthClientStoreError.keychain(failure)
        }
        return byKey.sorted { $0.key < $1.key }.map(\.value)
    }

    @discardableResult
    public func save(_ client: OAuthClientConfig, isDefault: Bool, synchronizable: Bool) throws -> OAuthClientSyncState {
        try requireAppProcess()
        var payload = Payload(clientID: client.clientID, clientSecret: client.clientSecret, isDefault: isDefault,
                              wantsSync: synchronizable)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(payload), data.count <= Self.maxItemBytes else {
            throw OAuthClientStoreError.corrupt
        }
        moveOnce()
        let account = client.registryKey
        var result: OAuthClientSyncState = .notSyncing
        if synchronizable {
            let status = replace(.dataProtection, account: account, data: data)
            let subject = CredentialChainLog.subject(clientKey: account)
            if status == errSecSuccess {
                result = .syncing
                log.record(.shareClient, .ok, subject: subject)
            } else {
                diagnostics.record(.clientSyncedWrite, status)
                log.record(.shareClient, KeychainItems.outcome(status), subject: subject)
                Log(.keychain).notice("client: the iCloud Keychain copy could not be written (OSStatus \(status)); "
                                      + "this Mac's own copy is used")
                result = .unavailable
            }
        } else {
            let status = deleteShared(account: account)
            if status != errSecSuccess, status != errSecItemNotFound {
                diagnostics.record(.clientSyncedDelete, status)
            }
        }
        payload.shared = result == .syncing ? true : nil
        guard let localData = try? encoder.encode(payload), localData.count <= Self.maxItemBytes else {
            throw OAuthClientStoreError.corrupt
        }
        let local = replace(.login, account: account, data: localData)
        diagnostics.record(.clientLocalWrite, local)
        guard local == errSecSuccess else {
            Log(.keychain).error("client: this Mac's own copy could not be written (OSStatus \(local))")
            if result == .syncing { return .syncing }
            throw OAuthClientStoreError.keychain(local)
        }
        return result
    }

    public func delete(key: String) throws {
        try requireAppProcess()
        guard OAuthClientConfig.isRegistryKey(key) else { throw OAuthClientStoreError.corrupt }
        moveOnce()
        let local: OSStatus
        do { try items.delete(.init(service: service, account: key)); local = errSecSuccess }
        catch KeychainItemsError.status(let status) { local = status }
        catch { local = errSecDecode }
        diagnostics.record(.clientLocalDelete, local)
        guard local == errSecSuccess || local == errSecItemNotFound else {
            throw OAuthClientStoreError.keychain(local)
        }
        let synced = deleteShared(account: key)
        if synced != errSecSuccess, synced != errSecItemNotFound {
            diagnostics.record(.clientSyncedDelete, synced)
            if read(.dataProtection).items[key] != nil { throw OAuthClientStoreError.keychain(synced) }
        }
    }

    public func markShared(key: String) throws {
        try requireAppProcess()
        guard OAuthClientConfig.isRegistryKey(key) else { throw OAuthClientStoreError.corrupt }
        let entry: KeychainItems.Entry?
        do { entry = try items.read(.init(service: service, account: key)) }
        catch KeychainItemsError.status(let status) { throw OAuthClientStoreError.keychain(status) }
        catch { throw OAuthClientStoreError.corrupt }
        guard let entry else { return }
        guard entry.data.count <= Self.maxItemBytes,
              var payload = try? JSONDecoder().decode(Payload.self, from: entry.data),
              Self.config(payload).registryKey == key else { throw OAuthClientStoreError.corrupt }
        guard payload.shared != true else { return }
        payload.shared = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(payload), data.count <= Self.maxItemBytes else {
            throw OAuthClientStoreError.corrupt
        }
        let status = replace(.login, account: key, data: data)
        diagnostics.record(.clientLocalWrite, status)
        guard status == errSecSuccess else { throw OAuthClientStoreError.keychain(status) }
    }

    enum Place { case dataProtection, login }

    func baseQuery(place: Place, account: String?) -> [String: Any] {
        switch place {
        case .dataProtection: syncedQuery(account: account, group: accessGroup)
        case .login: items.query(service: service, account: account)
        }
    }

    // Why: in the data-protection style this device's own copy lives in the same keychain, so only true excludes it
    func syncedQuery(account: String?, group: String?, synchronizableOnly: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if synchronizableOnly || items.style == .dataProtection {
            query[kSecAttrSynchronizable as String] = true
        } else {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        if let group { query[kSecAttrAccessGroup as String] = group }
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    func addAttributes(place: Place, account: String, data: Data) -> [String: Any] {
        var attributes = baseQuery(place: place, account: account)
        attributes[kSecAttrSynchronizable as String] = place == .dataProtection
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = Self.label
        return attributes
    }

    private func replace(_ place: Place, account: String, data: Data) -> OSStatus {
        if place == .login {
            do {
                try items.write(.init(service: service, account: account), data: data, label: Self.label)
                return errSecSuccess
            } catch KeychainItemsError.status(let status) { return status }
            catch { return errSecDecode }
        }
        guard items.canHoldSynchronizableItems else { return errSecMissingEntitlement }
        let deleted = backend.delete(baseQuery(place: place, account: account))
        items.synchronizableRefused(deleted)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return deleted }
        let status = backend.add(addAttributes(place: place, account: account, data: data))
        items.synchronizableRefused(status)
        return status
    }

    // Why: reading the data of all password items in one query is not supported, so attributes are listed first
    private func read(_ place: Place) -> (items: [String: Found], failure: OSStatus?) {
        if place == .login { return readLocal() }
        guard items.canHoldSynchronizableItems else { return ([:], nil) }
        var list = baseQuery(place: place, account: nil)
        list[kSecReturnAttributes as String] = true
        list[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = backend.copyMatching(list)
        items.synchronizableRefused(status)
        let operation: KeychainDiagnostics.Operation = place == .login ? .clientLocalRead : .clientSyncedRead
        if status == errSecItemNotFound {
            diagnostics.record(operation, errSecSuccess)
            return ([:], nil)
        }
        guard status == errSecSuccess else {
            diagnostics.record(operation, status)
            log.record(.readClient, KeychainItems.outcome(status))
            if place == .login {
                Log(.keychain).error("client: this Mac's own copies could not be listed (OSStatus \(status))")
            } else {
                Log(.keychain).notice("client: the iCloud Keychain copies could not be listed (OSStatus \(status))")
            }
            return ([:], status)
        }
        diagnostics.record(operation, errSecSuccess)
        let listed = KeychainItems.listed(result)
        var foundItems: [String: Found] = [:]
        for attributes in listed {
            guard let account = attributes[kSecAttrAccount as String] as? String, OAuthClientConfig.isRegistryKey(account),
                  (attributes[kSecAttrService as String] as? String).map({ $0 == service }) ?? true,
                  foundItems[account] == nil else { continue }
            guard self.items.canHoldSynchronizableItems else { break }
            var one = baseQuery(place: place, account: account)
            if place == .dataProtection, attributes[kSecAttrSynchronizable as String] != nil {
                one[kSecAttrSynchronizable as String] = Self.flag(attributes[kSecAttrSynchronizable as String])
            }
            one[kSecReturnData as String] = true
            one[kSecReturnAttributes as String] = true
            one[kSecMatchLimit as String] = kSecMatchLimitOne
            let (got, value) = backend.copyMatching(one)
            self.items.synchronizableRefused(got)
            guard got == errSecSuccess, let item = KeychainSharedGrantStore.single(value) else {
                if got != errSecItemNotFound {
                    diagnostics.record(operation, got)
                    Log(.keychain).error("client: a stored client could not be read (OSStatus \(got))")
                }
                continue
            }
            guard let found = decode(item, account: account, place: place) else { continue }
            foundItems[account] = found
        }
        return (foundItems, nil)
    }

    private func deleteShared(account: String) -> OSStatus {
        guard items.canHoldSynchronizableItems else { return errSecMissingEntitlement }
        let status = backend.delete(baseQuery(place: .dataProtection, account: account))
        items.synchronizableRefused(status)
        return status
    }

    private func readLocal() -> (items: [String: Found], failure: OSStatus?) {
        var found: [String: Found] = [:]
        do {
            let accounts = try items.accounts(service: service)
            diagnostics.record(.clientLocalRead, errSecSuccess)
            for account in accounts where OAuthClientConfig.isRegistryKey(account) {
                do {
                    guard let entry = try items.read(.init(service: service, account: account)) else { continue }
                    diagnostics.record(.clientLocalRead, errSecSuccess)
                    var attributes: [String: Any] = [kSecAttrService as String: service,
                        kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
                        kSecValueData as String: entry.data]
                    if let date = entry.modifiedAt { attributes[kSecAttrModificationDate as String] = date }
                    if let value = decode(attributes, account: account, place: .login) { found[account] = value }
                } catch KeychainItemsError.status(let status) {
                    diagnostics.record(.clientLocalRead, status)
                    Log(.keychain).error("client: a stored client could not be read (OSStatus \(status))")
                }
                catch { continue }
            }
            return (found, nil)
        } catch KeychainItemsError.status(let status) {
            diagnostics.record(.clientLocalRead, status)
            Log(.keychain).error("client: this Mac's own copies could not be listed (OSStatus \(status))")
            return ([:], status)
        } catch { return ([:], nil) }
    }

    private func decode(_ item: [String: Any], account: String, place: Place) -> Found? {
        guard (item[kSecAttrAccount as String] as? String).map({ $0 == account }) ?? true,
              (item[kSecAttrService as String] as? String).map({ $0 == service }) ?? true,
              let data = item[kSecValueData as String] as? Data, data.count <= Self.maxItemBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard Self.config(payload).registryKey == account else { return nil }
        let synchronizable = place == .dataProtection && Self.flag(item[kSecAttrSynchronizable as String])
        return Found(payload: payload, synchronizable: synchronizable,
                     modifiedAt: item[kSecAttrModificationDate as String] as? Date)
    }

    private func moveOnce() {
        guard let accessGroup, items.canHoldSynchronizableItems else { return }
        items.once("oauth-client|\(service)|\(accessGroup)") { _ = moveFromDefaultGroup(into: accessGroup) }
    }

    // Why: copies written before the shared group existed are invisible to the other app until they move into it
    @discardableResult
    func moveFromDefaultGroup(into group: String) -> Int {
        var list = syncedQuery(account: nil, group: nil, synchronizableOnly: true)
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
        for attributes in KeychainItems.listed(result) {
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  OAuthClientConfig.isRegistryKey(account),
                  let from = attributes[kSecAttrAccessGroup as String] as? String, from != group,
                  seen.insert(from + "\n" + account).inserted,
                  (attributes[kSecAttrService as String] as? String).map({ $0 == service }) ?? true else { continue }
            let outcome = move(account: account, from: from, into: group)
            log.record(.groupMove, outcome, subject: CredentialChainLog.subject(clientKey: account))
            if outcome == .ok { moved += 1 }
        }
        return moved
    }

    // Why: the old copy is deleted only after the shared group holds this client
    private func move(account: String, from old: String, into group: String) -> CredentialOutcome {
        var source = syncedQuery(account: account, group: old, synchronizableOnly: true)
        source[kSecReturnData as String] = true
        source[kSecReturnAttributes as String] = true
        source[kSecMatchLimit as String] = kSecMatchLimitOne
        let (got, value) = backend.copyMatching(source)
        items.synchronizableRefused(got)
        guard got == errSecSuccess else { return KeychainItems.outcome(got) }
        guard let item = KeychainSharedGrantStore.single(value), let data = item[kSecValueData as String] as? Data,
              (item[kSecAttrAccessGroup as String] as? String).map({ $0 == old }) ?? true,
              decode(item, account: account, place: .dataProtection) != nil else { return .unreadable }
        var target = syncedQuery(account: account, group: group, synchronizableOnly: true)
        target[kSecReturnAttributes as String] = true
        target[kSecMatchLimit as String] = kSecMatchLimitOne
        let (present, _) = backend.copyMatching(target)
        items.synchronizableRefused(present)
        if present == errSecItemNotFound {
            let added = backend.add(addAttributes(place: .dataProtection, account: account, data: data))
            items.synchronizableRefused(added)
            guard added == errSecSuccess || added == errSecDuplicateItem else { return KeychainItems.outcome(added) }
            let (check, _) = backend.copyMatching(target)
            items.synchronizableRefused(check)
            guard check == errSecSuccess else {
                return check == errSecItemNotFound ? .unreadable : KeychainItems.outcome(check)
            }
        } else if present != errSecSuccess {
            return KeychainItems.outcome(present)
        }
        let deleted = backend.delete(syncedQuery(account: account, group: old, synchronizableOnly: true))
        items.synchronizableRefused(deleted)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return KeychainItems.outcome(deleted) }
        return .ok
    }

    private static func config(_ payload: Payload) -> OAuthClientConfig {
        OAuthClientConfig.google(clientID: payload.clientID, clientSecret: payload.clientSecret)
    }

    private static func flag(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return string != "0" }
        return false
    }

    private func requireAppProcess() throws {
        guard isAppProcess() else { throw OAuthClientStoreError.notAppProcess }
    }
}
