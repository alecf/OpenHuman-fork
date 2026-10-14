import Foundation
import OpenHumanCore
import OpenHumanGmail
import Security
import Synchronization
import Testing
@testable import OpenHumanGmailApple

private final class SyncFakeKeychain: KeychainBackend {
    struct Item: Sendable {
        var service: String
        var account: String
        var dataProtection: Bool
        var synchronizable: Bool
        var accessible: String?
        var label: String?
        var data: Data
    }
    struct Pin: Sendable, Equatable {
        var dataProtection: Bool?
        var synchronizable: Bool?
    }
    private struct State {
        var items: [Item] = []
        var calls: [String] = []
        var pins: [Pin] = []
        var dataProtectionStatus: OSStatus = errSecSuccess
        var supportsUpdate = true
    }
    private let state = Mutex(State())

    var items: [Item] { state.withLock { $0.items } }
    var calls: [String] { state.withLock { $0.calls } }
    var pins: [Pin] { state.withLock { $0.pins } }
    func refuseDataProtection(_ status: OSStatus) { state.withLock { $0.dataProtectionStatus = status } }
    func withoutUpdate() { state.withLock { $0.supportsUpdate = false } }
    func plant(_ item: Item) { state.withLock { $0.items.append(item) } }

    private static func pin(_ query: [String: Any]) -> Pin {
        Pin(dataProtection: query[kSecUseDataProtectionKeychain as String] as? Bool,
            synchronizable: query[kSecAttrSynchronizable as String] as? Bool)
    }

    private static func matches(_ item: Item, _ query: [String: Any]) -> Bool {
        if let service = query[kSecAttrService as String] as? String, service != item.service { return false }
        if let account = query[kSecAttrAccount as String] as? String, account != item.account { return false }
        if ((query[kSecUseDataProtectionKeychain as String] as? Bool) ?? false) != item.dataProtection { return false }
        if let sync = query[kSecAttrSynchronizable as String] as? Bool, sync != item.synchronizable { return false }
        return true
    }

    private func refused(_ query: [String: Any]) -> OSStatus? {
        let status = state.withLock { $0.dataProtectionStatus }
        guard (query[kSecUseDataProtectionKeychain as String] as? Bool) == true, status != errSecSuccess else { return nil }
        return status
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        state.withLock { $0.calls.append("add"); $0.pins.append(Self.pin(attributes)) }
        if let status = refused(attributes) { return status }
        guard let data = attributes[kSecValueData as String] as? Data,
              let service = attributes[kSecAttrService as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String else { return errSecParam }
        let item = Item(service: service, account: account,
                        dataProtection: (attributes[kSecUseDataProtectionKeychain as String] as? Bool) == true,
                        synchronizable: (attributes[kSecAttrSynchronizable as String] as? Bool) == true,
                        accessible: attributes[kSecAttrAccessible as String] as? String,
                        label: attributes[kSecAttrLabel as String] as? String, data: data)
        return state.withLock { s in
            if s.items.contains(where: { $0.service == item.service && $0.account == item.account
                && $0.dataProtection == item.dataProtection && $0.synchronizable == item.synchronizable }) {
                return errSecDuplicateItem
            }
            s.items.append(item)
            return errSecSuccess
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        state.withLock { $0.calls.append("copy"); $0.pins.append(Self.pin(query)) }
        if let status = refused(query) { return (status, nil) }
        let found = state.withLock { s in s.items.filter { Self.matches($0, query) } }
        if found.isEmpty { return (errSecItemNotFound, nil) }
        let dictionaries = found.map { item -> NSDictionary in
            [kSecAttrService as String: item.service, kSecAttrAccount as String: item.account,
             kSecAttrSynchronizable as String: item.synchronizable, kSecValueData as String: item.data] as NSDictionary
        }
        if (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitOne as String) {
            return (errSecSuccess, dictionaries[0])
        }
        return (errSecSuccess, dictionaries as NSArray)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        state.withLock { $0.calls.append("delete"); $0.pins.append(Self.pin(query)) }
        if let status = refused(query) { return status }
        return state.withLock { s in
            let before = s.items.count
            s.items.removeAll { Self.matches($0, query) }
            return s.items.count < before ? errSecSuccess : errSecItemNotFound
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        let supported = state.withLock { s -> Bool in
            s.calls.append("update")
            s.pins.append(Self.pin(query))
            return s.supportsUpdate
        }
        guard supported else { return errSecUnimplemented }
        if let status = refused(query) { return status }
        return state.withLock { s in
            guard let index = s.items.firstIndex(where: { Self.matches($0, query) }) else { return errSecItemNotFound }
            if let data = attributes[kSecValueData as String] as? Data { s.items[index].data = data }
            if let label = attributes[kSecAttrLabel as String] as? String { s.items[index].label = label }
            return errSecSuccess
        }
    }
}

@Suite struct KeychainTokenSyncTests {
    private let service = "dev.openhuman.mail.oauth.v1.home.test"
    private let email = "someone@example.com"

    private func grant(_ refresh: String, version: Int = 1) -> SharedGrant {
        SharedGrant(refreshToken: refresh, clientID: "1234-synthetic.apps.example", grantedScopes: [GmailScope.readonly],
                    version: version)
    }

    private func shared(_ keychain: SyncFakeKeychain, app: Bool = true) -> KeychainSharedGrantStore {
        KeychainSharedGrantStore(service: service, items: KeychainItems(backend: keychain), isAppProcess: { app })
    }

    private func records(_ keychain: SyncFakeKeychain, app: Bool = true) -> KeychainTokenDeviceStore {
        KeychainTokenDeviceStore(tokenService: service, items: KeychainItems(backend: keychain),
                                 isAppProcess: { app })
    }

    @Test func theSharedCopyIsASynchronizableDataProtectionItemUpdatedInPlace() throws {
        let keychain = SyncFakeKeychain()
        let store = shared(keychain)
        #expect(try store.read(account: email) == .missing)
        #expect(try store.save(grant("refresh-1"), account: "Someone@Example.com") == .written)
        let item = try #require(keychain.items.first)
        #expect(item.dataProtection && item.synchronizable && item.service == service && item.account == email)
        #expect(item.accessible == (kSecAttrAccessibleAfterFirstUnlock as String), "the client store's accessibility")
        #expect(item.label == KeychainSharedGrantStore.label)
        #expect(try store.read(account: email) == .found(grant("refresh-1")))

        #expect(try store.save(grant("refresh-2", version: 2), account: email) == .written)
        #expect(keychain.calls.contains("update") && !keychain.calls.contains("delete"),
                "an existing copy is updated in place: the other devices never see it disappear")
        #expect(keychain.items.count == 1)
        #expect(try store.read(account: email) == .found(grant("refresh-2", version: 2)))
        #expect(try store.allAccounts() == [email])
        #expect(keychain.pins.allSatisfy { $0 == .init(dataProtection: true, synchronizable: true) },
                "every query pins the synchronizable data-protection item")

        try store.delete(account: email)
        #expect(try keychain.items.isEmpty && store.read(account: email) == .missing)
    }

    @Test func aBackendWithoutUpdatesReplacesTheCopy() throws {
        let keychain = SyncFakeKeychain()
        keychain.withoutUpdate()
        let store = shared(keychain)
        try store.save(grant("refresh-1"), account: email)
        try store.save(grant("refresh-2", version: 2), account: email)
        #expect(try keychain.items.count == 1 && store.read(account: email) == .found(grant("refresh-2", version: 2)))
    }

    @Test func aBuildThatCannotHoldSynchronizableItemsSaysUnavailable() throws {
        for status in [errSecMissingEntitlement, errSecNotAvailable] {
            let keychain = SyncFakeKeychain()
            keychain.refuseDataProtection(status)
            let store = shared(keychain)
            #expect(try store.save(grant("refresh-1"), account: email) == .unavailable)
            #expect(try store.read(account: email) == .unavailable)
            #expect(try store.allAccounts().isEmpty)
            try store.delete(account: email)
            #expect(keychain.items.isEmpty, "nothing is written anywhere else")
        }
    }

    @Test func thisDevicesOwnItemIsNeverReadAsTheSharedCopy() throws {
        let keychain = SyncFakeKeychain()
        keychain.plant(.init(service: service, account: email, dataProtection: false, synchronizable: false,
                             data: try JSONEncoder().encode(grant("own-refresh"))))
        let store = shared(keychain)
        #expect(try store.read(account: email) == .missing)
        try store.delete(account: email)
        #expect(keychain.items.count == 1, "deleting the shared copy never deletes this device's own item")
        #expect(try store.allAccounts().isEmpty)
    }

    @Test func anUnreadableSharedCopyIsRefusedNotUsed() throws {
        let keychain = SyncFakeKeychain()
        keychain.plant(.init(service: service, account: email, dataProtection: true, synchronizable: true,
                             data: Data("not json".utf8)))
        #expect(throws: TokenStoreError.corrupt) { _ = try shared(keychain).read(account: email) }
        let empty = SyncFakeKeychain()
        #expect(throws: TokenStoreError.corrupt) { _ = try shared(empty).save(grant(""), account: email) }
    }

    @Test func deviceRecordsLiveInTheAccountsTokenItem() throws {
        let keychain = SyncFakeKeychain()
        let items = KeychainItems(backend: keychain)
        let tokens = KeychainTokenStore(service: service, items: items, isAppProcess: { true })
        let store = KeychainTokenDeviceStore(tokenService: service, items: items, isAppProcess: { true })
        try tokens.save(StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.readonly],
                                    clientID: "synthetic.apps.example"), account: email)
        let record = TokenDeviceRecord(accessToken: "synthetic-access",
                                        accessTokenExpiry: Date(timeIntervalSince1970: 1),
                                       accessFor: "synthetic-fingerprint", wrote: "synthetic-fingerprint")
        try store.save(record, account: email)
        #expect(try store.load(account: email) == record)
        let item = try #require(keychain.items.first)
        #expect(keychain.items.count == 1, "items=\(keychain.items.count), \(keychain.calls)")
        #expect(item.service == service && !item.dataProtection && !item.synchronizable)
        #expect(item.label == KeychainTokenStore.defaultLabel)
        #expect(item.accessible == (kSecAttrAccessibleAfterFirstUnlock as String))
        let payload = try JSONDecoder().decode(TokenItemPayload.self, from: item.data)
        #expect(payload.device?.accessToken == nil && payload.device?.accessTokenExpiry == nil
                && payload.device?.accessFor == nil)
        #expect(payload.accessToken == nil && payload.accessTokenExpiry == nil)
        #expect(!keychain.calls.contains("update"))
        #expect(keychain.pins.allSatisfy { $0 == .init(dataProtection: false, synchronizable: false) })
        let before = keychain.calls.count
        try store.delete(account: email)
        let calls = Array(keychain.calls.dropFirst(before))
        #expect(calls == ["delete", "add", "delete"], "calls=\(calls.count), \(calls)")
        #expect(try JSONDecoder().decode(TokenItemPayload.self, from: keychain.items[0].data).device == nil)
        #expect(try tokens.load(account: email)?.refreshToken == "synthetic-refresh")
        for canSync in [true, false] {
            let empty = SyncFakeKeychain()
            let records = KeychainTokenDeviceStore(tokenService: service,
                items: KeychainItems(backend: empty, canHoldSynchronizableItems: canSync), isAppProcess: { true })
            try records.save(record, account: email)
            #expect(empty.items.count == (canSync ? 1 : 0), "items=\(empty.items.count), \(empty.calls)")
            if canSync {
                #expect(empty.items.first?.service == service + ".device")
                #expect(empty.items.first?.label == KeychainTokenDeviceStore.label)
                #expect(empty.items.first?.dataProtection == false && empty.items.first?.synchronizable == false)
            }
        }
    }

    @Test func aLegacyRecordIsFoldedIntoTheTokenItemOnce() throws {
        let keychain = SyncFakeKeychain()
        let items = KeychainItems(backend: keychain)
        let token = StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.readonly],
                                clientID: "synthetic.apps.example")
        keychain.plant(.init(service: service, account: email, dataProtection: false, synchronizable: false,
                             data: try JSONEncoder().encode(token)))
        keychain.plant(.init(service: service + ".device", account: email,
                             dataProtection: false, synchronizable: false,
                             data: try JSONEncoder().encode(TokenDeviceRecord(choice: .dontSync))))
        let store = KeychainTokenDeviceStore(tokenService: service, items: items, isAppProcess: { true })
        #expect(try store.load(account: email)?.choice == .dontSync)
        try store.save(TokenDeviceRecord(), account: email)
        #expect(!keychain.items.contains { $0.service == service + ".device" })
        let item = try #require(keychain.items.first { $0.service == service })
        let json = try #require(try JSONSerialization.jsonObject(with: item.data) as? [String: Any])
        #expect(json["device"] == nil)
        #expect(try store.load(account: email) == nil)
        let relaunched = KeychainTokenDeviceStore(tokenService: service, items: KeychainItems(backend: keychain),
                                                  isAppProcess: { true })
        #expect(try relaunched.load(account: email) == nil)
    }

    @Test func neitherStoreRunsOutsideAnAppBundle() throws {
        let keychain = SyncFakeKeychain()
        let sharedStore = shared(keychain, app: false)
        let recordStore = records(keychain, app: false)
        #expect(throws: TokenStoreError.notAppProcess) { _ = try sharedStore.read(account: email) }
        #expect(throws: TokenStoreError.notAppProcess) { _ = try sharedStore.save(grant("r"), account: email) }
        #expect(throws: TokenStoreError.notAppProcess) { try sharedStore.delete(account: email) }
        #expect(throws: TokenStoreError.notAppProcess) { _ = try sharedStore.allAccounts() }
        #expect(throws: TokenStoreError.notAppProcess) { _ = try recordStore.load(account: email) }
        #expect(throws: TokenStoreError.notAppProcess) { try recordStore.save(TokenDeviceRecord(), account: email) }
        #expect(throws: TokenStoreError.notAppProcess) { try recordStore.delete(account: email) }
        #expect(keychain.calls.isEmpty)
    }

    @Test func theSyncedStoreOverBothKeepsTheOwnItemUnchangedAndSharesTheSignIn() throws {
        let keychain = SyncFakeKeychain()
        let items = KeychainItems(backend: keychain)
        let own = KeychainTokenStore(service: service, items: items, isAppProcess: { true })
        let store = SyncedTokenStore(local: own,
            shared: KeychainSharedGrantStore(service: service, items: items, isAppProcess: { true }),
            device: KeychainTokenDeviceStore(tokenService: service, items: items, isAppProcess: { true }))
        let token = StoredToken(refreshToken: "synthetic-refresh", grantedScopes: [GmailScope.readonly],
                                clientID: "1234-synthetic.apps.example")
        try store.save(token, account: email)
        let kinds = keychain.items.map { "\($0.service)|\($0.dataProtection)|\($0.synchronizable)" }.sorted()
        #expect(kinds == ["\(service)|false|false", "\(service)|true|true"],
                "items=\(kinds.count), \(kinds), calls=\(keychain.calls)")
        #expect(try own.load(account: email) == token, "this device's own item is today's item, unchanged")
        #expect(try store.load(account: email)?.refreshToken == "synthetic-refresh")
        try store.delete(account: email)
        #expect(keychain.items.map { "\($0.service)|\($0.dataProtection)|\($0.synchronizable)" }
            == ["\(service)|true|true"], "signing out here keeps only the shared copy")
        try store.deleteEverywhere(account: email)
        #expect(keychain.items.isEmpty, "removing the shared sign-in removes it too")
    }
}
