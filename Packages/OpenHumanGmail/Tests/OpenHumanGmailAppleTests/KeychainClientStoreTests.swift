import Foundation
import OpenHumanCore
import OpenHumanGmail
import Security
import Synchronization
import Testing
@testable import OpenHumanGmailApple

private final class ClientFakeKeychain: KeychainBackend {
    struct Item: Sendable {
        var service: String
        var account: String
        var dataProtection: Bool
        var synchronizable: Bool
        var data: Data
    }
    private struct State {
        var items: [Item] = []
        var dataProtectionStatus: OSStatus = errSecSuccess
        var everythingStatus: OSStatus = errSecSuccess
    }
    private let state = Mutex(State())

    var items: [Item] { state.withLock { $0.items } }
    func refuseDataProtection(_ status: OSStatus) { state.withLock { $0.dataProtectionStatus = status } }
    func refuseEverything(_ status: OSStatus) { state.withLock { $0.everythingStatus = status } }
    func deliver(_ item: Item) { state.withLock { $0.items.append(item) } }

    private func refusal(_ query: [String: Any]) -> OSStatus? {
        let (dp, all) = state.withLock { ($0.dataProtectionStatus, $0.everythingStatus) }
        if all != errSecSuccess { return all }
        if (query[kSecUseDataProtectionKeychain as String] as? Bool) == true, dp != errSecSuccess { return dp }
        return nil
    }

    private func matches(_ item: Item, _ query: [String: Any]) -> Bool {
        if let service = query[kSecAttrService as String] as? String, service != item.service { return false }
        if let account = query[kSecAttrAccount as String] as? String, account != item.account { return false }
        if let sync = query[kSecAttrSynchronizable as String] as? Bool, sync != item.synchronizable { return false }
        return (query[kSecUseDataProtectionKeychain as String] as? Bool) == item.dataProtection
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        if let refused = refusal(attributes) { return refused }
        guard let data = attributes[kSecValueData as String] as? Data,
              let service = attributes[kSecAttrService as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String else { return errSecParam }
        let dp = (attributes[kSecUseDataProtectionKeychain as String] as? Bool) == true
        let sync = (attributes[kSecAttrSynchronizable as String] as? Bool) == true
        return state.withLock { s in
            if s.items.contains(where: { $0.service == service && $0.account == account && $0.dataProtection == dp }) {
                return errSecDuplicateItem
            }
            s.items.append(Item(service: service, account: account, dataProtection: dp, synchronizable: sync, data: data))
            return errSecSuccess
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        if let refused = refusal(query) { return (refused, nil) }
        let all = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
        let wantsData = (query[kSecReturnData as String] as? Bool) == true
        if all, wantsData { return (errSecParam, nil) }
        let found = state.withLock { $0.items }.filter { matches($0, query) }
        if found.isEmpty { return (errSecItemNotFound, nil) }
        let dictionaries = found.map { item -> NSDictionary in
            var entry: [String: Any] = [kSecAttrService as String: item.service, kSecAttrAccount as String: item.account,
                                        kSecAttrSynchronizable as String: item.synchronizable,
                                        kSecAttrModificationDate as String: Date(timeIntervalSince1970: 1_790_000_000)]
            if wantsData { entry[kSecValueData as String] = item.data }
            return entry as NSDictionary
        }
        return all ? (errSecSuccess, dictionaries as NSArray) : (errSecSuccess, dictionaries[0])
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        if let refused = refusal(query) { return refused }
        return state.withLock { s in
            let before = s.items.count
            s.items.removeAll { matches($0, query) }
            return s.items.count < before ? errSecSuccess : errSecItemNotFound
        }
    }
}

@Suite struct KeychainClientStoreTests {
    private let work = OAuthClientConfig.google(clientID: "555555555555-keychainwork11.apps.example", clientSecret: "SYNTHETIC-A")
    private let other = OAuthClientConfig.google(clientID: "666666666666-keychainother2.apps.example", clientSecret: "SYNTHETIC-B")

    private func store(_ keychain: ClientFakeKeychain, app: Bool = true) -> KeychainClientStore {
        KeychainClientStore(service: KeychainClientStore.service, items: KeychainItems(backend: keychain),
                            isAppProcess: { app })
    }

    @Test func aClientIsSynchronizableByDefaultAndRoundTrips() throws {
        let keychain = ClientFakeKeychain()
        let clients = store(keychain)
        #expect(try clients.save(work, isDefault: true, synchronizable: true) == .syncing)
        #expect(keychain.items.count == 2)
        let item = try #require(keychain.items.first { $0.dataProtection })
        #expect(item.synchronizable)
        #expect(keychain.items.contains { !$0.dataProtection && !$0.synchronizable && $0.account == work.registryKey })
        #expect(item.service == "dev.openhuman.mail.oauth-client.v1" && item.account == work.registryKey,
                "named by the hash, never the id")
        #expect(String(data: item.data, encoding: .utf8)?.contains("SYNTHETIC-A") == true, "the value holds the secret")
        let loaded = try #require(try clients.loadAll().first)
        #expect(loaded.config.clientID == work.clientID && loaded.config.clientSecret == "SYNTHETIC-A")
        #expect(loaded.isDefault && loaded.sync == .syncing && loaded.modifiedAt != nil)
    }

    @Test func dontSyncKeepsTheItemOnThisMacAndSwitchingBackMovesIt() throws {
        let keychain = ClientFakeKeychain()
        let clients = store(keychain)
        #expect(try clients.save(work, isDefault: false, synchronizable: false) == .notSyncing)
        #expect(keychain.items.count == 1 && !keychain.items[0].dataProtection && !keychain.items[0].synchronizable)
        #expect(try clients.loadAll().first?.sync == .notSyncing)
        #expect(try clients.save(work, isDefault: false, synchronizable: true) == .syncing)
        #expect(keychain.items.count == 2)
        #expect(keychain.items.filter { $0.dataProtection && $0.synchronizable }.count == 1)
        #expect(try clients.save(work, isDefault: false, synchronizable: false) == .notSyncing)
        #expect(keychain.items.count == 1 && !keychain.items[0].dataProtection, "Don't sync removes the iCloud copy")
    }

    @Test func aBuildNotSignedForICloudKeychainKeepsTheClientLocallyAndSaysSo() throws {
        let keychain = ClientFakeKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clients = store(keychain)
        #expect(try clients.save(work, isDefault: true, synchronizable: true) == .unavailable)
        #expect(keychain.items.count == 1 && !keychain.items[0].dataProtection && !keychain.items[0].synchronizable)
        let loaded = try #require(try clients.loadAll().first)
        #expect(loaded.sync == .unavailable && loaded.config.clientID == work.clientID)
    }

    @Test func deleteRemovesOnlyThatClientsItem() throws {
        let keychain = ClientFakeKeychain()
        let clients = store(keychain)
        try clients.save(work, isDefault: true, synchronizable: true)
        try clients.save(other, isDefault: false, synchronizable: false)
        try clients.delete(key: work.registryKey)
        #expect(try clients.loadAll().map(\.config.clientID) == [other.clientID])
        try clients.delete(key: work.registryKey)
        #expect(throws: OAuthClientStoreError.self) { try clients.delete(key: "../x") }
    }

    @Test func itemsThatAreNotExactlyOursAreIgnored() throws {
        let keychain = ClientFakeKeychain()
        let clients = store(keychain)
        let payload = Data(#"{"clientID":"\#(work.clientID)","clientSecret":"x","isDefault":false}"#.utf8)
        for (service, account, data) in [(KeychainClientStore.service, other.registryKey, payload),
                                         (KeychainClientStore.service, work.registryKey, Data("nope".utf8)),
                                         ("com.example.other", work.registryKey, payload)] {
            _ = keychain.add([kSecAttrService as String: service, kSecAttrAccount as String: account,
                              kSecValueData as String: data, kSecUseDataProtectionKeychain as String: true,
                              kSecAttrSynchronizable as String: true])
        }
        #expect(try clients.loadAll().isEmpty)
    }

    @Test func aStoredClientReadsBackOnABuildWithoutTheEntitlement() throws {
        let keychain = ClientFakeKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clients = store(keychain)
        #expect(try clients.save(work, isDefault: true, synchronizable: true) == .unavailable)
        let loaded = try clients.loadAll()
        #expect(loaded.map(\.config.clientID) == [work.clientID])
        #expect(loaded.first?.sync == .unavailable && loaded.first?.isLocal == true && loaded.first?.isDefault == true)
    }

    @Test func anyDataProtectionFailureFallsBackToThisMacsOwnItem() throws {
        for status in [errSecMissingEntitlement, errSecNotAvailable, errSecParam, errSecInteractionNotAllowed,
                       errSecAuthFailed, OSStatus(-67671)] {
            let keychain = ClientFakeKeychain()
            keychain.refuseDataProtection(status)
            let diagnostics = KeychainDiagnostics()
            let clients = KeychainClientStore(service: KeychainClientStore.service,
                                              items: KeychainItems(backend: keychain),
                                              isAppProcess: { true }, diagnostics: diagnostics)
            #expect(try clients.save(work, isDefault: true, synchronizable: true) == .unavailable, "status \(status)")
            #expect(try clients.loadAll().map(\.config.clientID) == [work.clientID], "status \(status)")
            #expect(keychain.items.count == 1 && !keychain.items[0].dataProtection)
            #expect(diagnostics.lastStatus(.clientSyncedWrite) == status && diagnostics.lastStatus(.clientLocalWrite) == 0)
            try clients.delete(key: work.registryKey)
            #expect(try clients.loadAll().isEmpty, "status \(status)")
        }
    }

    @Test func whenEverythingFailsTheSaveSaysSoWithTheCode() {
        let keychain = ClientFakeKeychain()
        keychain.refuseEverything(errSecAuthFailed)
        let clients = store(keychain)
        #expect(throws: OAuthClientStoreError.keychain(errSecAuthFailed)) {
            try clients.save(work, isDefault: true, synchronizable: true)
        }
        #expect(throws: OAuthClientStoreError.keychain(errSecAuthFailed)) { try clients.loadAll() }
    }

    @Test func aClientSetUpOnAnotherDeviceIsReadFromTheSynchronizableCopy() throws {
        let keychain = ClientFakeKeychain()
        let payload = Data(#"{"clientID":"\#(other.clientID)","clientSecret":"SYNTHETIC-B","isDefault":true}"#.utf8)
        keychain.deliver(.init(service: KeychainClientStore.service, account: other.registryKey, dataProtection: true,
                               synchronizable: true, data: payload))
        let clients = store(keychain)
        let loaded = try #require(try clients.loadAll().first)
        #expect(loaded.config.clientID == other.clientID && loaded.sync == .syncing && !loaded.isLocal)
        try clients.save(other, isDefault: false, synchronizable: true)
        let again = try #require(try clients.loadAll().first)
        #expect(again.isLocal && again.sync == .syncing && !again.isDefault)
    }

    @Test func listingNeverAsksForTheDataOfAllItemsAtOnce() throws {
        let keychain = ClientFakeKeychain()
        let clients = store(keychain)
        try clients.save(work, isDefault: true, synchronizable: false)
        try clients.save(other, isDefault: false, synchronizable: true)
        #expect(try clients.loadAll().map(\.config.registryKey) == [work.registryKey, other.registryKey].sorted())
    }

    @Test func nothingRunsOutsideAnAppBundle() {
        let clients = store(ClientFakeKeychain(), app: false)
        #expect(throws: OAuthClientStoreError.notAppProcess) { try clients.loadAll() }
        #expect(throws: OAuthClientStoreError.notAppProcess) { try clients.save(work, isDefault: true, synchronizable: true) }
    }
}
