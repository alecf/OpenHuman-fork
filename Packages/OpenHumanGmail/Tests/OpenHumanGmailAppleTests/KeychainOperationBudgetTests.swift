import Foundation
import OpenHumanCore
import OpenHumanGmail
import Security
import Synchronization
import Testing
@testable import OpenHumanGmailApple

private final class CountingKeychain: KeychainBackend {
    struct Key: Hashable, Sendable {
        var dataProtection: Bool
        var service: String
        var account: String
        var synchronizable: Bool
    }

    struct Item: Sendable {
        var key: Key
        var data: Data
        var label: String
    }

    struct Op: Sendable {
        var kind: String
        var dataProtection: Bool
        var service: String?
        var account: String?
        var wantsData: Bool
        var status: OSStatus
    }

    private struct State {
        var items: [Item] = []
        var refusal: OSStatus?
        var ops: [Op] = []
    }
    private let state = Mutex(State())

    func refuseDataProtection(_ status: OSStatus?) { state.withLock { $0.refusal = status } }
    func plant(service: String, account: String, data: Data, label: String,
               dataProtection: Bool = false, synchronizable: Bool = false) {
        state.withLock { s in
            let key = Key(dataProtection: dataProtection, service: service, account: account,
                          synchronizable: synchronizable)
            s.items.removeAll { $0.key == key }
            s.items.append(Item(key: key, data: data, label: label))
        }
    }
    func mark() -> Int { state.withLock { $0.ops.count } }
    func ops(since mark: Int) -> [Op] { state.withLock { Array($0.ops.dropFirst(mark)) } }

    private static func matches(_ item: Item, _ query: [String: Any]) -> Bool {
        if let service = query[kSecAttrService as String] as? String, service != item.key.service { return false }
        if let account = query[kSecAttrAccount as String] as? String, account != item.key.account { return false }
        if ((query[kSecUseDataProtectionKeychain as String] as? Bool) ?? false) != item.key.dataProtection {
            return false
        }
        if let sync = query[kSecAttrSynchronizable as String] as? Bool {
            return sync == item.key.synchronizable
        }
        if let sync = query[kSecAttrSynchronizable as String] as? String {
            return sync == (kSecAttrSynchronizableAny as String)
        }
        return !item.key.synchronizable
    }

    private static func refusal(_ query: [String: Any], _ state: State) -> OSStatus? {
        (query[kSecUseDataProtectionKeychain as String] as? Bool) == true ? state.refusal : nil
    }

    private static func record(_ kind: String, _ query: [String: Any], _ status: OSStatus, _ state: inout State) {
        state.ops.append(Op(kind: kind,
                            dataProtection: (query[kSecUseDataProtectionKeychain as String] as? Bool) ?? false,
                            service: query[kSecAttrService as String] as? String,
                            account: query[kSecAttrAccount as String] as? String,
                            wantsData: (query[kSecReturnData as String] as? Bool) == true, status: status))
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        state.withLock { s in
            var status = errSecSuccess
            defer { Self.record("add", attributes, status, &s) }
            if let refused = Self.refusal(attributes, s) { status = refused; return status }
            guard let service = attributes[kSecAttrService as String] as? String,
                  let account = attributes[kSecAttrAccount as String] as? String,
                  let data = attributes[kSecValueData as String] as? Data else {
                status = errSecParam
                return status
            }
            let key = Key(dataProtection: (attributes[kSecUseDataProtectionKeychain as String] as? Bool) ?? false,
                          service: service, account: account,
                          synchronizable: (attributes[kSecAttrSynchronizable as String] as? Bool) ?? false)
            if s.items.contains(where: { $0.key == key }) { status = errSecDuplicateItem; return status }
            s.items.append(Item(key: key, data: data, label: attributes[kSecAttrLabel as String] as? String ?? ""))
            return status
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        state.withLock { s in
            var status = errSecSuccess
            defer { Self.record("copy", query, status, &s) }
            if let refused = Self.refusal(query, s) { status = refused; return (status, nil) }
            let wantsData = (query[kSecReturnData as String] as? Bool) == true
            if wantsData, (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String) {
                // Password items cannot return all matching values in one call
                status = errSecParam
                return (status, nil)
            }
            let found = s.items.filter { Self.matches($0, query) }
            guard !found.isEmpty else { status = errSecItemNotFound; return (status, nil) }
            let entries = found.map { item -> NSDictionary in
                var entry: [String: Any] = [
                    kSecAttrService as String: item.key.service,
                    kSecAttrAccount as String: item.key.account,
                    kSecAttrSynchronizable as String: item.key.synchronizable,
                    kSecAttrModificationDate as String: Date(timeIntervalSince1970: 1_790_000_000),
                    kSecAttrLabel as String: item.label,
                ]
                if wantsData { entry[kSecValueData as String] = item.data }
                return entry as NSDictionary
            }
            if (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitOne as String) {
                return (status, entries[0])
            }
            return (status, entries as NSArray)
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        state.withLock { s in
            var status = errSecSuccess
            defer { Self.record("update", query, status, &s) }
            if let refused = Self.refusal(query, s) ?? Self.refusal(attributes, s) {
                status = refused
                return status
            }
            guard let index = s.items.firstIndex(where: { Self.matches($0, query) }) else {
                status = errSecItemNotFound
                return status
            }
            if let data = attributes[kSecValueData as String] as? Data { s.items[index].data = data }
            if let label = attributes[kSecAttrLabel as String] as? String { s.items[index].label = label }
            return status
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        state.withLock { s in
            var status = errSecSuccess
            defer { Self.record("delete", query, status, &s) }
            if let refused = Self.refusal(query, s) { status = refused; return status }
            let before = s.items.count
            s.items.removeAll { Self.matches($0, query) }
            if before == s.items.count { status = errSecItemNotFound }
            return status
        }
    }
}

private struct LoginItem: Hashable, Sendable {
    var service: String
    var account: String
}

private struct Budget {
    let ops: [CountingKeychain.Op]
    var total: Int { ops.count }
    var dataProtection: Int { ops.filter(\.dataProtection).count }
    var loginOps: Int { ops.filter { !$0.dataProtection }.count }
    var loginWrites: Int { ops.filter { !$0.dataProtection && $0.kind != "copy" }.count }
    var dataProtectionWrites: Int { ops.filter { $0.dataProtection && $0.kind != "copy" }.count }
    var dataReads: [LoginItem: Int] {
        var counts: [LoginItem: Int] = [:]
        for op in ops where !op.dataProtection && op.kind == "copy" && op.wantsData {
            if let service = op.service, let account = op.account {
                counts[LoginItem(service: service, account: account), default: 0] += 1
            }
        }
        return counts
    }
    var successfulReads: Set<LoginItem> {
        Set(ops.compactMap { op in
            guard !op.dataProtection, op.kind == "copy", op.wantsData, op.status == errSecSuccess,
                  let service = op.service, let account = op.account else { return nil }
            return LoginItem(service: service, account: account)
        })
    }
    var summary: String {
        let reads = dataReads.map { "\($0.key.service)/\($0.key.account)=\($0.value)" }.sorted().joined(separator: ", ")
        let log = ops.enumerated().map { index, op in
            "\(index + 1) \(op.kind) dp=\(op.dataProtection) \(op.service ?? "*")/\(op.account ?? "list") "
                + "data=\(op.wantsData) status=\(op.status)"
        }.joined(separator: "\n")
        return "total=\(total), dataProtection=\(dataProtection), loginWrites=\(loginWrites), loginOps=\(loginOps), "
            + "dataProtectionWrites=\(dataProtectionWrites), reads=[\(reads)]\n\(log)"
    }
}

private final class FakeTokenEndpoint: HTTPTransport {
    private let count = Mutex(0)
    var requestCount: Int { count.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.method == "POST" else { throw TransportError.other("synthetic-unexpected-method") }
        let number = count.withLock { $0 += 1; return $0 }
        let body = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-access-\(number)", "expires_in": 3600,
            "token_type": "Bearer", "scope": GmailScope.readonly,
        ])
        return HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: body)
    }
}

private enum Fixture {
    static let tokenService = "dev.openhuman.mail.oauth.v1.home.budget"
    static let calendarService = GoogleCalendarAuth.keychainService + ".home.budget"
    static let clientService = KeychainClientStore.service + ".home.budget"
    static let client = OAuthClientConfig.google(clientID: "123456789012-budget.apps.example",
                                                clientSecret: "SYNTHETIC-SECRET")
    static let existing = "a@example.com"
    static let signingIn = "b@example.com"

    static func plantExistingInstall(_ keychain: CountingKeychain, _ clock: TestClock) throws {
        let token = StoredToken(refreshToken: "synthetic-refresh-a", accessToken: "synthetic-old-access",
                                accessTokenExpiry: clock.now.addingTimeInterval(-60),
                                grantedScopes: [GmailScope.readonly], clientID: client.clientID)
        keychain.plant(service: tokenService, account: existing, data: try JSONEncoder().encode(token),
                       label: KeychainTokenStore.defaultLabel)
        keychain.plant(service: tokenService + ".device", account: existing,
                       data: try JSONEncoder().encode(TokenDeviceRecord(cannotSync: true)),
                       label: KeychainTokenDeviceStore.label)
        let payload = try JSONSerialization.data(withJSONObject: [
            "clientID": client.clientID, "clientSecret": "SYNTHETIC-SECRET", "isDefault": true, "wantsSync": true,
        ])
        keychain.plant(service: clientService, account: client.registryKey, data: payload,
                       label: KeychainClientStore.label)
    }
}

private struct Install {
    let synced: SyncedTokenStore
    let calendar: KeychainTokenStore
    let vault: OAuthClientVault

    static func launch(keychain: CountingKeychain, canSync: Bool) -> Install {
        let items = KeychainItems(backend: keychain, canHoldSynchronizableItems: canSync)
        let local = KeychainTokenStore(service: Fixture.tokenService, items: items, isAppProcess: { true })
        let shared = KeychainSharedGrantStore(service: Fixture.tokenService, items: items, isAppProcess: { true })
        let device = KeychainTokenDeviceStore(tokenService: Fixture.tokenService,
                                             items: items, isAppProcess: { true })
        let calendar = KeychainTokenStore(service: Fixture.calendarService, items: items, isAppProcess: { true },
                                          label: GoogleCalendarAuth.keychainLabel)
        let clients = KeychainClientStore(service: Fixture.clientService, items: items, isAppProcess: { true })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Install(synced: SyncedTokenStore(local: local, shared: shared, device: device), calendar: calendar,
                       vault: OAuthClientVault(store: clients, storeDirectory: directory))
    }
}

private func runLaunch(_ install: Install, _ endpoint: FakeTokenEndpoint,
                       _ clock: TestClock) async throws -> AccountCredentials {
    install.vault.migrateLegacyFiles()
    install.synced.migrateLocalSignIns()
    _ = try install.synced.load(account: Fixture.existing)
    let known = install.vault.available(environment: [:])
    _ = try install.synced.load(account: Fixture.existing)
    _ = try install.calendar.load(account: Fixture.existing)
    let client = try #require(known.first)
    let credentials = AccountCredentials(store: install.synced, client: client, knownClients: { known },
                                         transport: endpoint, clock: clock)
    _ = try credentials.grantedScopes(for: Fixture.existing)
    _ = try await credentials.tokenManager(for: Fixture.existing).accessToken()
    return credentials
}

@Suite struct KeychainOperationBudgetTests {
    private func expectLaunchBudget(_ budget: Budget) {
        #expect(budget.total <= 4, "\(budget.summary)")
        #expect(budget.dataProtection == 0, "\(budget.summary)")
        #expect(budget.loginWrites == 0, "\(budget.summary)")
        #expect(budget.dataReads.values.allSatisfy { $0 <= 1 }, "\(budget.summary)")
        let expected: Set<LoginItem> = [LoginItem(service: Fixture.tokenService, account: Fixture.existing),
                                       LoginItem(service: Fixture.clientService, account: Fixture.client.registryKey)]
        #expect(budget.successfulReads == expected,
                "successfulReads=\(budget.successfulReads.count), \(budget.summary)")
    }

    @Test func aLaunchReadsEachItemOnceAndWritesNothing() async throws {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        let mark = keychain.mark()
        let install = Install.launch(keychain: keychain, canSync: false)
        let endpoint = FakeTokenEndpoint()
        let credentials = try await runLaunch(install, endpoint, clock)
        let budget = Budget(ops: keychain.ops(since: mark))
        expectLaunchBudget(budget)
        #expect(endpoint.requestCount == 1, "requests=\(endpoint.requestCount), \(budget.summary)")
        let access = try await credentials.tokenManager(for: Fixture.existing).accessToken()
        #expect(access == "synthetic-access-1")
    }

    @Test func aRefreshTouchesNoKeychainItem() async throws {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        let install = Install.launch(keychain: keychain, canSync: false)
        let endpoint = FakeTokenEndpoint()
        let credentials = try await runLaunch(install, endpoint, clock)
        let mark = keychain.mark()
        clock.advance(by: .seconds(3600))
        _ = try await credentials.tokenManager(for: Fixture.existing).accessToken()
        _ = try await credentials.tokenManager(for: Fixture.existing).accessToken(forceRefresh: true)
        let budget = Budget(ops: keychain.ops(since: mark))
        #expect(budget.total == 0, "\(budget.summary)")
        #expect(endpoint.requestCount == 3, "requests=\(endpoint.requestCount), \(budget.summary)")
    }

    @Test func theICloudSyncProbeTouchesNoKeychainItemOnABuildThatCannotSync() async throws {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        let install = Install.launch(keychain: keychain, canSync: false)
        _ = try await runLaunch(install, FakeTokenEndpoint(), clock)
        let mark = keychain.mark()
        #expect(!install.synced.syncsThroughICloudKeychain())
        #expect(!install.vault.stored().contains { $0.sync == .syncing })
        let budget = Budget(ops: keychain.ops(since: mark))
        #expect(budget.total == 0, "\(budget.summary)")
    }

    @Test func aSignInWritesOneItem() async throws {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        let install = Install.launch(keychain: keychain, canSync: false)
        let endpoint = FakeTokenEndpoint()
        let credentials = try await runLaunch(install, endpoint, clock)
        let mark = keychain.mark()
        try install.synced.save(StoredToken(refreshToken: "synthetic-refresh-b", accessToken: "synthetic-access-b",
                                           accessTokenExpiry: clock.now.addingTimeInterval(3600),
                                           grantedScopes: [GmailScope.readonly], clientID: Fixture.client.clientID),
                                account: Fixture.signingIn)
        _ = try install.synced.load(account: Fixture.signingIn)
        let access = try await credentials.tokenManager(for: Fixture.signingIn).accessToken()
        let budget = Budget(ops: keychain.ops(since: mark))
        #expect(budget.total <= 2, "\(budget.summary)")
        #expect(budget.dataProtection == 0, "\(budget.summary)")
        #expect(budget.loginWrites <= 1, "\(budget.summary)")
        #expect(access == "synthetic-access-b")
        #expect(endpoint.requestCount == 1, "requests=\(endpoint.requestCount), \(budget.summary)")
    }

    @Test func aSecondLaunchOfTheSameInstallReadsTheSameItems() async throws {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        let install = Install.launch(keychain: keychain, canSync: false)
        let endpoint = FakeTokenEndpoint()
        let credentials = try await runLaunch(install, endpoint, clock)
        clock.advance(by: .seconds(3600))
        _ = try await credentials.tokenManager(for: Fixture.existing).accessToken()
        let mark = keychain.mark()
        let relaunched = Install.launch(keychain: keychain, canSync: false)
        let nextEndpoint = FakeTokenEndpoint()
        _ = try await runLaunch(relaunched, nextEndpoint, clock)
        let budget = Budget(ops: keychain.ops(since: mark))
        expectLaunchBudget(budget)
        #expect(nextEndpoint.requestCount == 1, "requests=\(nextEndpoint.requestCount), \(budget.summary)")
    }

    @Test func aSyncingBuildReadsEachLoginItemOnce() async throws {
        let keychain = CountingKeychain()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        let mark = keychain.mark()
        let install = Install.launch(keychain: keychain, canSync: true)
        let endpoint = FakeTokenEndpoint()
        let credentials = try await runLaunch(install, endpoint, clock)
        let launch = Budget(ops: keychain.ops(since: mark))
        #expect(launch.dataReads.values.allSatisfy { $0 <= 1 }, "\(launch.summary)")
        #expect(launch.total <= 21, "\(launch.summary)")
        #expect(launch.loginOps <= 9, "\(launch.summary)")
        #expect(launch.loginWrites <= 3, "\(launch.summary)")
        #expect(launch.dataProtection <= 12, "\(launch.summary)")
        let refreshMark = keychain.mark()
        clock.advance(by: .seconds(3600))
        _ = try await credentials.tokenManager(for: Fixture.existing).accessToken()
        let refresh = Budget(ops: keychain.ops(since: refreshMark))
        #expect(refresh.loginOps == 0, "\(refresh.summary)")
        #expect(refresh.dataProtectionWrites == 0, "\(refresh.summary)")
        #expect(refresh.total <= 3, "\(refresh.summary)")
        let relaunchMark = keychain.mark()
        _ = try await runLaunch(Install.launch(keychain: keychain, canSync: true), FakeTokenEndpoint(), clock)
        let relaunch = Budget(ops: keychain.ops(since: relaunchMark))
        #expect(relaunch.loginOps <= 5, "\(relaunch.summary)")
        #expect(relaunch.dataProtection <= 10, "\(relaunch.summary)")
        #expect(relaunch.loginWrites == 0, "\(relaunch.summary)")
        #expect(relaunch.dataReads.values.allSatisfy { $0 <= 1 }, "\(relaunch.summary)")
    }

    private func exerciseRefusingBuild(canSync: Bool) async throws -> Budget {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        let mark = keychain.mark()
        let install = Install.launch(keychain: keychain, canSync: canSync)
        let credentials = try await runLaunch(install, FakeTokenEndpoint(), clock)
        clock.advance(by: .seconds(3600))
        _ = try await credentials.tokenManager(for: Fixture.existing).accessToken()
        try install.synced.save(StoredToken(refreshToken: "synthetic-refresh-b",
                                           grantedScopes: [GmailScope.readonly], clientID: Fixture.client.clientID),
                                account: Fixture.signingIn)
        _ = try install.synced.load(account: Fixture.signingIn)
        return Budget(ops: keychain.ops(since: mark))
    }

    @Test func aBuildThatCannotHoldSynchronizableItemsNeverProbesThem() async throws {
        let budget = try await exerciseRefusingBuild(canSync: false)
        #expect(budget.total <= 6, "\(budget.summary)")
        #expect(budget.dataProtection == 0, "\(budget.summary)")
    }

    @Test func aRefusedProbeIsNotRepeated() async throws {
        let budget = try await exerciseRefusingBuild(canSync: true)
        #expect(budget.total <= 9, "\(budget.summary)")
        #expect(budget.dataProtection <= 1, "\(budget.summary)")
    }
}
