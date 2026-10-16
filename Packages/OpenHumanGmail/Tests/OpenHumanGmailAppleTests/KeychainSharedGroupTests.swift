import Foundation
import OpenHumanCore
import OpenHumanGmail
import Security
import Synchronization
import Testing
@testable import OpenHumanGmailApple

private final class GroupKeychain: KeychainBackend {
    struct Item: Sendable, Equatable {
        var service: String
        var account: String
        var dataProtection: Bool
        var synchronizable: Bool
        var group: String?
        var accessible: String?
        var data: Data
    }

    struct Op: Sendable {
        var kind: String
        var service: String?
        var dataProtection: Bool?
        var synchronizable: String
        var group: String?
        var wantsData: Bool
    }

    private struct State {
        var items: [Item] = []
        var ops: [Op] = []
        var refusedGroups: Set<String> = []
    }
    private let state = Mutex(State())
    let defaultGroup: String

    init(defaultGroup: String) { self.defaultGroup = defaultGroup }

    var items: [Item] { state.withLock { $0.items } }
    var ops: [Op] { state.withLock { $0.ops } }
    func mark() -> Int { state.withLock { $0.ops.count } }
    func ops(since mark: Int) -> [Op] { state.withLock { Array($0.ops.dropFirst(mark)) } }
    func plant(_ item: Item) { state.withLock { $0.items.append(item) } }
    func refuse(group: String) { state.withLock { _ = $0.refusedGroups.insert(group) } }

    private static func sync(_ query: [String: Any]) -> String {
        guard let value = query[kSecAttrSynchronizable as String] else { return "unset" }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        if let text = value as? String, text == (kSecAttrSynchronizableAny as String) { return "any" }
        return "other"
    }

    private func record(_ kind: String, _ query: [String: Any]) -> OSStatus? {
        let group = query[kSecAttrAccessGroup as String] as? String
        return state.withLock { s in
            s.ops.append(Op(kind: kind, service: query[kSecAttrService as String] as? String,
                            dataProtection: query[kSecUseDataProtectionKeychain as String] as? Bool,
                            synchronizable: Self.sync(query), group: group,
                            wantsData: (query[kSecReturnData as String] as? Bool) == true))
            guard let group, s.refusedGroups.contains(group) else { return nil }
            return errSecMissingEntitlement
        }
    }

    private static func matches(_ item: Item, _ query: [String: Any]) -> Bool {
        if let service = query[kSecAttrService as String] as? String, service != item.service { return false }
        if let account = query[kSecAttrAccount as String] as? String, account != item.account { return false }
        if ((query[kSecUseDataProtectionKeychain as String] as? Bool) ?? false) != item.dataProtection { return false }
        switch sync(query) {
        case "true": if !item.synchronizable { return false }
        case "any": break
        default: if item.synchronizable { return false }
        }
        if let group = query[kSecAttrAccessGroup as String] as? String, group != item.group { return false }
        return true
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        if let refused = record("add", attributes) { return refused }
        guard let service = attributes[kSecAttrService as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        let dataProtection = (attributes[kSecUseDataProtectionKeychain as String] as? Bool) == true
        let named = attributes[kSecAttrAccessGroup as String] as? String
        let item = Item(service: service, account: account, dataProtection: dataProtection,
                        synchronizable: (attributes[kSecAttrSynchronizable as String] as? Bool) == true,
                        group: dataProtection ? (named ?? defaultGroup) : nil,
                        accessible: attributes[kSecAttrAccessible as String] as? String, data: data)
        return state.withLock { s in
            if s.items.contains(where: { $0.service == item.service && $0.account == item.account
                && $0.dataProtection == item.dataProtection && $0.synchronizable == item.synchronizable
                && $0.group == item.group }) { return errSecDuplicateItem }
            s.items.append(item)
            return errSecSuccess
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        if let refused = record("copy", query) { return (refused, nil) }
        let wantsData = (query[kSecReturnData as String] as? Bool) == true
        let all = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
        if all, wantsData { return (errSecParam, nil) }
        let found = state.withLock { $0.items }.filter { Self.matches($0, query) }
        if found.isEmpty { return (errSecItemNotFound, nil) }
        let entries = found.map { item -> NSDictionary in
            var entry: [String: Any] = [kSecAttrService as String: item.service, kSecAttrAccount as String: item.account,
                                        kSecAttrSynchronizable as String: item.synchronizable]
            if let group = item.group { entry[kSecAttrAccessGroup as String] = group }
            if wantsData { entry[kSecValueData as String] = item.data }
            return entry as NSDictionary
        }
        return all ? (errSecSuccess, entries as NSArray) : (errSecSuccess, entries[0])
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        if let refused = record("update", query) { return refused }
        return state.withLock { s in
            guard let index = s.items.firstIndex(where: { Self.matches($0, query) }) else { return errSecItemNotFound }
            if let data = attributes[kSecValueData as String] as? Data { s.items[index].data = data }
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        if let refused = record("delete", query) { return refused }
        return state.withLock { s in
            let before = s.items.count
            s.items.removeAll { Self.matches($0, query) }
            return s.items.count < before ? errSecSuccess : errSecItemNotFound
        }
    }
}

private enum Fixture {
    static let team = "ABCDE12345"
    static let group = team + "." + KeychainSharing.groupName
    static let defaultGroup = team + ".dev.example.default"
    static let tokenService = OHIdentifiers.keychainService + ".group-test"
    static let clientService = KeychainClientStore.service + ".group-test"
    static let a = "a@example.com"
    static let b = "b@example.com"
    static let clientID = "333333333333-groupclienta1.apps.googleusercontent.com"
    static let client = OAuthClientConfig.google(clientID: clientID, clientSecret: "SYNTHETIC-GROUP")
    static let clientJSON = Data(#"{"installed":{"client_id":"\#(clientID)","client_secret":"SYNTHETIC-GROUP"}}"#.utf8)
    static let afterFirstUnlock = kSecAttrAccessibleAfterFirstUnlock as String

    static func grant(_ refresh: String, version: Int) -> SharedGrant {
        SharedGrant(refreshToken: refresh, clientID: clientID, grantedScopes: [GmailScope.readonly], version: version)
    }

    static func token(_ refresh: String) -> StoredToken {
        StoredToken(refreshToken: refresh, grantedScopes: [GmailScope.readonly], clientID: clientID)
    }

    static func sharedItem(_ account: String, _ grant: SharedGrant, group: String) throws -> GroupKeychain.Item {
        GroupKeychain.Item(service: tokenService, account: account, dataProtection: true, synchronizable: true,
                           group: group, accessible: afterFirstUnlock, data: try JSONEncoder().encode(grant))
    }

    static func clientItem(group: String) throws -> GroupKeychain.Item {
        let payload = try JSONSerialization.data(withJSONObject: [
            "clientID": clientID, "clientSecret": "SYNTHETIC-GROUP", "isDefault": true, "wantsSync": true,
        ])
        return GroupKeychain.Item(service: clientService, account: client.registryKey, dataProtection: true,
                                  synchronizable: true, group: group, accessible: afterFirstUnlock, data: payload)
    }
}

private struct Install {
    let items: KeychainItems
    let local: KeychainTokenStore
    let shared: KeychainSharedGrantStore
    let device: KeychainTokenDeviceStore
    let synced: SyncedTokenStore
    let clients: KeychainClientStore
    let vault: OAuthClientVault
    let log: CredentialChainLog

    init(_ keychain: GroupKeychain, style: KeychainItems.QueryStyle, group: String?, canSync: Bool = true) {
        log = CredentialChainLog(clock: TestClock())
        items = KeychainItems(backend: keychain, canHoldSynchronizableItems: canSync, style: style)
        local = KeychainTokenStore(service: Fixture.tokenService, items: items, isAppProcess: { true })
        shared = KeychainSharedGrantStore(service: Fixture.tokenService, items: items, isAppProcess: { true },
                                          accessGroup: group, log: log)
        device = KeychainTokenDeviceStore(tokenService: Fixture.tokenService, items: items, isAppProcess: { true })
        synced = SyncedTokenStore(local: local, shared: shared, device: device, log: log)
        clients = KeychainClientStore(service: Fixture.clientService, items: items, isAppProcess: { true },
                                      diagnostics: KeychainDiagnostics(), accessGroup: group, log: log)
        vault = OAuthClientVault(store: clients, log: log)
    }

    func exercise() throws {
        try synced.save(Fixture.token("synthetic-refresh-a"), account: Fixture.a)
        _ = try synced.load(account: Fixture.a)
        try synced.setSyncEnabled(false, account: Fixture.a)
        try synced.setSyncEnabled(true, account: Fixture.a)
        synced.migrateLocalSignIns()
        _ = try synced.sharedSignIns()
        try synced.setSource(.shared, account: Fixture.a)
        let client = try vault.importClient(Fixture.clientJSON)
        try vault.setSynchronizable(key: client.registryKey, false)
        try vault.setSynchronizable(key: client.registryKey, true)
        vault.migrateSyncWanted()
        _ = vault.stored()
        try synced.deleteEverywhere(account: Fixture.a)
        try vault.remove(key: client.registryKey)
    }
}

@Suite struct KeychainSharedGroupTests {
    @Test(arguments: [KeychainItems.QueryStyle.macLegacy, .dataProtection])
    func everySynchronizableQueryCarriesTheGroupAndNoLocalOneDoes(_ style: KeychainItems.QueryStyle) throws {
        let keychain = GroupKeychain(defaultGroup: Fixture.defaultGroup)
        let install = Install(keychain, style: style, group: Fixture.group)
        _ = try install.shared.allAccounts()
        _ = try install.clients.loadAll()
        let firstUse = keychain.ops
        let mark = keychain.mark()
        try install.exercise()
        let ops = keychain.ops(since: mark)
        let synced = ops.filter { $0.synchronizable == "true" || $0.synchronizable == "any" }
        let local = ops.filter { $0.synchronizable == "false" }
        #expect(!synced.isEmpty && !local.isEmpty, "synced=\(synced.count) local=\(local.count)")
        #expect(synced.allSatisfy { $0.group == Fixture.group },
                "\(synced.filter { $0.group != Fixture.group }.map { "\($0.kind) \($0.service ?? "*")" })")
        #expect(local.allSatisfy { $0.group == nil }, "this device's own items never name a group")
        #expect(ops.allSatisfy { $0.synchronizable != "unset" }, "every query says which kind of item it wants")
        if style == .dataProtection {
            #expect(keychain.ops.allSatisfy { $0.dataProtection == true }, "never the legacy keychain")
        }
        let looking = firstUse.filter { $0.group == nil && $0.synchronizable == "true" }
        #expect(looking.count == 2 && looking.allSatisfy { $0.kind == "copy" && !$0.wantsData },
                "the only queries without the group are the one-time listings that look for older copies")
        #expect(keychain.items.isEmpty, "items=\(keychain.items.count)")
    }

    @Test func copiesInTheDefaultGroupMoveOnceAndTheOldOnesAreDeletedOnce() throws {
        let keychain = GroupKeychain(defaultGroup: Fixture.defaultGroup)
        keychain.plant(try Fixture.sharedItem(Fixture.a, Fixture.grant("synthetic-refresh-a", version: 3),
                                              group: Fixture.defaultGroup))
        keychain.plant(try Fixture.clientItem(group: Fixture.defaultGroup))
        for launch in 1...2 {
            let install = Install(keychain, style: .macLegacy, group: Fixture.group)
            #expect(try install.shared.read(account: Fixture.a) == .found(Fixture.grant("synthetic-refresh-a", version: 3)),
                    "launch \(launch)")
            #expect(try install.shared.allAccounts() == [Fixture.a], "launch \(launch)")
            let loaded = try install.clients.loadAll()
            #expect(loaded.map(\.config.clientID) == [Fixture.clientID] && loaded.first?.sync == .syncing,
                    "launch \(launch)")
            if launch == 1 {
                #expect(install.log.events().filter { $0.step == .groupMove }.map(\.outcome) == [.ok, .ok])
            }
        }
        #expect(!keychain.items.contains { $0.group == Fixture.defaultGroup }, "no copy is left in the default group")
        #expect(keychain.items.filter { $0.group == Fixture.group }.count == 2)
        let ops = keychain.ops
        let adds = ops.filter { $0.kind == "add" }
        #expect(adds.count == 2 && adds.allSatisfy { $0.group == Fixture.group }, "one write each, into the shared group")
        #expect(ops.filter { $0.kind == "delete" && $0.group == Fixture.defaultGroup }.count == 2,
                "each old copy is deleted exactly once")
        #expect(!ops.contains { $0.kind == "delete" && $0.group != Fixture.defaultGroup },
                "nothing else is deleted")
    }

    @Test func theNewerSignInWinsWhenBothGroupsHoldOne() throws {
        let keychain = GroupKeychain(defaultGroup: Fixture.defaultGroup)
        keychain.plant(try Fixture.sharedItem(Fixture.a, Fixture.grant("synthetic-old-a", version: 2),
                                              group: Fixture.defaultGroup))
        keychain.plant(try Fixture.sharedItem(Fixture.a, Fixture.grant("synthetic-new-a", version: 5),
                                              group: Fixture.group))
        keychain.plant(try Fixture.sharedItem(Fixture.b, Fixture.grant("synthetic-new-b", version: 4),
                                              group: Fixture.defaultGroup))
        keychain.plant(try Fixture.sharedItem(Fixture.b, Fixture.grant("synthetic-old-b", version: 1),
                                              group: Fixture.group))
        let install = Install(keychain, style: .macLegacy, group: Fixture.group)
        #expect(try install.shared.read(account: Fixture.a) == .found(Fixture.grant("synthetic-new-a", version: 5)))
        #expect(try install.shared.read(account: Fixture.b) == .found(Fixture.grant("synthetic-new-b", version: 4)))
        #expect(keychain.items.count == 2 && keychain.items.allSatisfy { $0.group == Fixture.group })
        let ops = keychain.ops
        #expect(ops.filter { $0.kind == "update" }.count == 1, "only the older shared copy is rewritten, in place")
        #expect(ops.filter { $0.kind == "delete" }.count == 2, "each old copy is deleted once")
        #expect(!ops.contains { $0.kind == "delete" && $0.group == Fixture.group }, "no shared copy is deleted")
    }

    @Test func aMoveThatCannotWriteNeverDeletesTheOldCopy() throws {
        let keychain = GroupKeychain(defaultGroup: Fixture.defaultGroup)
        let old = try Fixture.sharedItem(Fixture.a, Fixture.grant("synthetic-refresh-a", version: 1),
                                         group: Fixture.defaultGroup)
        keychain.plant(old)
        keychain.refuse(group: Fixture.group)
        let install = Install(keychain, style: .macLegacy, group: Fixture.group)
        #expect(try install.shared.read(account: Fixture.a) == .unavailable)
        #expect(keychain.items == [old])
        #expect(!keychain.ops.contains { $0.kind == "delete" })
        #expect(install.log.latest(.groupMove)?.outcome == .noEntitlement)
        #expect(!install.shared.canHoldSharedCopies, "a build without the group is told so, not retried")
    }

    @Test func anUnreadableOldCopyIsLeftWhereItIs() throws {
        let keychain = GroupKeychain(defaultGroup: Fixture.defaultGroup)
        let old = GroupKeychain.Item(service: Fixture.tokenService, account: Fixture.a, dataProtection: true,
                                     synchronizable: true, group: Fixture.defaultGroup, data: Data("not json".utf8))
        keychain.plant(old)
        let install = Install(keychain, style: .macLegacy, group: Fixture.group)
        #expect(try install.shared.read(account: Fixture.a) == .missing)
        #expect(keychain.items == [old])
        #expect(install.log.latest(.groupMove)?.outcome == .unreadable)
        #expect(install.log.latest(.groupMove)?.subject == CredentialChainLog.subject(account: Fixture.a))
    }

    @Test func withoutAGroupNothingMovesAndNoQueryNamesOne() throws {
        let keychain = GroupKeychain(defaultGroup: Fixture.defaultGroup)
        keychain.plant(try Fixture.sharedItem(Fixture.a, Fixture.grant("synthetic-refresh-a", version: 1),
                                              group: Fixture.defaultGroup))
        let install = Install(keychain, style: .macLegacy, group: nil)
        #expect(try install.shared.read(account: Fixture.a) == .found(Fixture.grant("synthetic-refresh-a", version: 1)))
        try install.exercise()
        #expect(keychain.ops.allSatisfy { $0.group == nil })
        #expect(install.log.events().allSatisfy { $0.step != .groupMove })
    }

    @Test func aClientSavedOnABuildThatCouldNotSyncIsSharedAtTheFirstLaunchThatCan() throws {
        let keychain = GroupKeychain(defaultGroup: Fixture.defaultGroup)
        let before = Install(keychain, style: .macLegacy, group: Fixture.group, canSync: false)
        let client = try before.vault.importClient(Fixture.clientJSON)
        #expect(before.vault.stored().first?.sync == .unavailable)
        #expect(before.vault.migrateSyncWanted() == OAuthClientShareReport())
        #expect(keychain.items.count == 1 && !keychain.items[0].dataProtection)

        let after = Install(keychain, style: .macLegacy, group: Fixture.group)
        var shared = OAuthClientShareReport()
        shared.shared = 1
        #expect(after.vault.migrateSyncWanted() == shared)
        #expect(after.vault.stored().first?.sync == .syncing)
        let copy = try #require(keychain.items.first { $0.dataProtection })
        #expect(copy.synchronizable && copy.group == Fixture.group && copy.account == client.registryKey)
        #expect(String(decoding: copy.data, as: UTF8.self).contains("SYNTHETIC-GROUP"), "the other device gets the secret")
        #expect(after.log.latest(.shareClient)?.outcome == .ok)

        let mark = keychain.mark()
        let next = Install(keychain, style: .macLegacy, group: Fixture.group)
        var again = OAuthClientShareReport()
        again.alreadyShared = 1
        #expect(next.vault.migrateSyncWanted() == again)
        #expect(keychain.ops(since: mark).allSatisfy { $0.kind == "copy" }, "a later launch writes nothing")
    }

    @Test func aClientRemovedOnAnotherDeviceIsNotSharedAgain() throws {
        let keychain = GroupKeychain(defaultGroup: Fixture.defaultGroup)
        let first = Install(keychain, style: .macLegacy, group: Fixture.group)
        let client = try first.vault.importClient(Fixture.clientJSON)
        #expect(first.vault.stored().first?.sync == .syncing)
        #expect(keychain.delete([kSecClass as String: kSecClassGenericPassword,
                                 kSecAttrService as String: Fixture.clientService,
                                 kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: true,
                                 kSecAttrAccessGroup as String: Fixture.group]) == errSecSuccess,
                "another device removes the shared copy")
        let mark = keychain.mark()
        let relaunched = Install(keychain, style: .macLegacy, group: Fixture.group)
        var expected = OAuthClientShareReport()
        expected.removedElsewhere = 1
        #expect(relaunched.vault.migrateSyncWanted() == expected)
        #expect(!keychain.ops(since: mark).contains { $0.kind == "add" }, "the removal on the other device stands")
        #expect(relaunched.vault.entry(key: client.registryKey)?.sync == .unavailable)
        #expect(relaunched.log.latest(.shareClient)?.outcome == .removedElsewhere)
    }

    @Test func aClientSharedByAnOlderBuildIsRememberedWithoutRewritingItsSharedCopy() throws {
        let keychain = GroupKeychain(defaultGroup: Fixture.defaultGroup)
        let payload = try JSONSerialization.data(withJSONObject: [
            "clientID": Fixture.clientID, "clientSecret": "SYNTHETIC-GROUP", "isDefault": true, "wantsSync": true,
        ])
        keychain.plant(.init(service: Fixture.clientService, account: Fixture.client.registryKey, dataProtection: false,
                             synchronizable: false, data: payload))
        keychain.plant(try Fixture.clientItem(group: Fixture.group))
        let install = Install(keychain, style: .macLegacy, group: Fixture.group)
        let mark = keychain.mark()
        var already = OAuthClientShareReport()
        already.alreadyShared = 1
        #expect(install.vault.migrateSyncWanted() == already)
        #expect(!keychain.ops(since: mark).contains { $0.dataProtection == true && $0.kind != "copy" },
                "the shared copy is left as it is")
        #expect(install.vault.stored().first?.wasShared == true)

        #expect(keychain.delete([kSecClass as String: kSecClassGenericPassword,
                                 kSecAttrService as String: Fixture.clientService,
                                 kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: true,
                                 kSecAttrAccessGroup as String: Fixture.group]) == errSecSuccess)
        let relaunched = Install(keychain, style: .macLegacy, group: Fixture.group)
        var removed = OAuthClientShareReport()
        removed.removedElsewhere = 1
        #expect(relaunched.vault.migrateSyncWanted() == removed)
        #expect(!keychain.items.contains { $0.dataProtection }, "a removal on another device stands")
    }

    @Test func theDataProtectionStyleNeverAsksForTheLegacyKeychain() throws {
        let keychain = GroupKeychain(defaultGroup: Fixture.defaultGroup)
        let install = Install(keychain, style: .dataProtection, group: Fixture.group)
        try install.synced.save(Fixture.token("synthetic-refresh-a"), account: Fixture.a)
        let client = try install.vault.importClient(Fixture.clientJSON)
        try install.vault.setSynchronizable(key: client.registryKey, true)
        let kinds = keychain.items.map { "\($0.service == Fixture.tokenService ? "token" : "client")|\($0.synchronizable)" }
        #expect(kinds.sorted() == ["client|false", "client|true", "token|false", "token|true"], "\(kinds)")
        #expect(keychain.items.allSatisfy { $0.dataProtection && $0.accessible == Fixture.afterFirstUnlock },
                "readable by a background refresh once the phone was unlocked")
        #expect(keychain.items.filter(\.synchronizable).allSatisfy { $0.group == Fixture.group })

        try install.synced.delete(account: Fixture.a)
        #expect(keychain.items.filter { $0.service == Fixture.tokenService }.map(\.synchronizable) == [true],
                "signing out here keeps only the shared copy")
        try install.vault.setSynchronizable(key: client.registryKey, false)
        #expect(keychain.items.filter { $0.service == Fixture.clientService }.map(\.synchronizable) == [false],
                "Don't sync removes only the shared copy")
        #expect(install.vault.stored().first?.sync == .notSyncing)
        #expect(keychain.ops.allSatisfy { $0.dataProtection == true }, "no query ever asks for the legacy keychain")

        let query = install.items.query(service: Fixture.tokenService, account: Fixture.a)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        let mac = KeychainItems(backend: keychain, style: .macLegacy).query(service: Fixture.tokenService)
        #expect(mac[kSecUseDataProtectionKeychain as String] as? Bool == false, "the Mac keeps its login keychain items")
    }

    @Test func theDeviceRecordKeepsItsSourceAcrossLaunches() throws {
        let keychain = GroupKeychain(defaultGroup: Fixture.defaultGroup)
        let install = Install(keychain, style: .dataProtection, group: Fixture.group)
        try install.device.save(TokenDeviceRecord(wrote: "synthetic-fingerprint", source: .shared), account: Fixture.a)
        let relaunched = Install(keychain, style: .dataProtection, group: Fixture.group)
        #expect(try relaunched.device.load(account: Fixture.a)?.source == .shared)
        #expect(keychain.items.allSatisfy { !$0.synchronizable && $0.group == Fixture.defaultGroup },
                "the device record never leaves this device")
    }

    @Test func theAccessGroupComesFromTheBuildSettingAndAnUnsetOneMeansNone() {
        let key = KeychainSharing.infoKey
        #expect(KeychainSharing.configuredAccessGroup([key: Fixture.group]) == Fixture.group)
        #expect(KeychainSharing.configuredAccessGroup([key: " \(Fixture.group)\n"]) == Fixture.group)
        for bad in ["", "$(AppIdentifierPrefix)" + KeychainSharing.groupName, KeychainSharing.groupName,
                    Fixture.team.lowercased() + "." + KeychainSharing.groupName, Fixture.team + ".",
                    Fixture.team + ".a b", Fixture.team + "." + KeychainSharing.groupName + "."] {
            #expect(KeychainSharing.configuredAccessGroup([key: bad]) == nil, "\(bad)")
        }
        #expect(KeychainSharing.configuredAccessGroup([key: 7]) == nil)
        #expect(KeychainSharing.configuredAccessGroup([:]) == nil)
        #expect(KeychainSharing.configuredAccessGroup(nil) == nil)
    }
}
