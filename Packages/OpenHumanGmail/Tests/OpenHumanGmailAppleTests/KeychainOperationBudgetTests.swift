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
        var generic: Data?
    }

    struct Op: Sendable {
        var kind: String
        var dataProtection: Bool
        var service: String?
        var account: String?
        var wantsData: Bool
        var status: OSStatus
        var skipsDialogs = false
    }

    struct Named: Hashable, Sendable {
        var service: String
        var account: String
    }

    private struct State {
        var items: [Item] = []
        var refusal: OSStatus?
        var refusedItems: [Named: OSStatus] = [:]
        var refusedLists: OSStatus?
        var suspended: [Named: Suspension] = [:]
        var ops: [Op] = []
    }
    private let state = Mutex(State())

    func refuseDataProtection(_ status: OSStatus?) { state.withLock { $0.refusal = status } }
    func refuse(service: String, account: String, with status: OSStatus?) {
        state.withLock { $0.refusedItems[Named(service: service, account: account)] = status }
    }
    func refuseLists(_ status: OSStatus?) { state.withLock { $0.refusedLists = status } }
    func suspend(service: String, account: String) -> Suspension {
        let suspension = Suspension()
        state.withLock { $0.suspended[Named(service: service, account: account)] = suspension }
        return suspension
    }
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
                            wantsData: (query[kSecReturnData as String] as? Bool) == true, status: status,
                            skipsDialogs: (query[kSecUseAuthenticationUI as String] as? String)
                                == (kSecUseAuthenticationUISkip as String)))
    }

    private func waitIfSuspended(_ query: [String: Any]) {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String,
              let suspension = state.withLock({ $0.suspended.removeValue(forKey: Named(service: service, account: account)) })
        else { return }
        suspension.hold()
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
            s.items.append(Item(key: key, data: data, label: attributes[kSecAttrLabel as String] as? String ?? "",
                                generic: attributes[kSecAttrGeneric as String] as? Data))
            return status
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        waitIfSuspended(query)
        return state.withLock { s in
            var status = errSecSuccess
            defer { Self.record("copy", query, status, &s) }
            if let refused = Self.refusal(query, s) { status = refused; return (status, nil) }
            let wantsData = (query[kSecReturnData as String] as? Bool) == true
            let login = (query[kSecUseDataProtectionKeychain as String] as? Bool) != true
            if login, wantsData, let service = query[kSecAttrService as String] as? String,
               let account = query[kSecAttrAccount as String] as? String,
               let refused = s.refusedItems[Named(service: service, account: account)] {
                status = refused
                return (status, nil)
            }
            if login, !wantsData, (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String),
               let refused = s.refusedLists {
                status = refused
                return (status, nil)
            }
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
                if let generic = item.generic { entry[kSecAttrGeneric as String] = generic }
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
            if let generic = attributes[kSecAttrGeneric as String] as? Data { s.items[index].generic = generic }
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

private final class Suspension: @unchecked Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let arrivals: AsyncStream<Void>
    private let arrived: AsyncStream<Void>.Continuation

    init() { (arrivals, arrived) = AsyncStream<Void>.makeStream() }

    func hold() {
        arrived.yield()
        release.wait()
    }

    func entered() async {
        var iterator = arrivals.makeAsyncIterator()
        _ = await iterator.next()
    }

    func resume() { release.signal() }
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
    let known = install.vault.available(clientFile: nil)
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

@Suite struct ClientShareLaunchBudgetTests {
    @Test func theClientShareAtLaunchTouchesNoKeychainItemOnABuildThatCannotSync() async throws {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        let install = Install.launch(keychain: keychain, canSync: false)
        _ = try await runLaunch(install, FakeTokenEndpoint(), clock)
        let mark = keychain.mark()
        #expect(install.vault.migrateSyncWanted() == OAuthClientShareReport())
        let budget = Budget(ops: keychain.ops(since: mark))
        #expect(budget.total == 0, "\(budget.summary)")
    }

    @Test func theClientShareAtLaunchWritesOnceAndThenNothing() async throws {
        let keychain = CountingKeychain()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        let install = Install.launch(keychain: keychain, canSync: true)
        _ = try await runLaunch(install, FakeTokenEndpoint(), clock)
        let mark = keychain.mark()
        var shared = OAuthClientShareReport()
        shared.shared = 1
        #expect(install.vault.migrateSyncWanted() == shared)
        let first = Budget(ops: keychain.ops(since: mark))
        #expect(first.dataProtectionWrites <= 2, "\(first.summary)")
        #expect(first.loginWrites <= 2, "\(first.summary)")
        #expect(first.dataReads.isEmpty, "the launch already read the client: \(first.summary)")

        let relaunchMark = keychain.mark()
        let relaunched = Install.launch(keychain: keychain, canSync: true)
        _ = try await runLaunch(relaunched, FakeTokenEndpoint(), clock)
        var again = OAuthClientShareReport()
        again.alreadyShared = 1
        #expect(relaunched.vault.migrateSyncWanted() == again)
        let relaunch = Budget(ops: keychain.ops(since: relaunchMark).filter { $0.service == Fixture.clientService })
        #expect(relaunch.loginWrites == 0 && relaunch.dataProtectionWrites == 0, "\(relaunch.summary)")
        #expect(relaunch.dataReads.values.allSatisfy { $0 <= 1 }, "\(relaunch.summary)")
    }
}

private func refusedStatus(_ error: any Error) -> OSStatus? {
    switch error {
    case TokenStoreError.keychain(let status): status
    case OAuthClientStoreError.keychain(let status): status
    default: nil
    }
}

@Suite struct KeychainRefusalBudgetTests {
    static let refusals: [OSStatus] = [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed,
                                               errSecInteractionRequired]
    private static let tokenItem = LoginItem(service: Fixture.tokenService, account: Fixture.existing)
    private static let clientItem = LoginItem(service: Fixture.clientService, account: Fixture.client.registryKey)

    private func everyLaunchPathReadsTheSignIn(_ install: Install, _ clock: TestClock) async {
        install.vault.migrateLegacyFiles()
        install.synced.migrateLocalSignIns()
        for _ in 0..<3 { _ = try? install.synced.load(account: Fixture.existing) }
        _ = try? install.synced.syncState(account: Fixture.existing)
        _ = try? install.synced.local.load(account: Fixture.existing)
        let credentials = AccountCredentials(store: install.synced, client: Fixture.client, knownClients: { [Fixture.client] },
                                             transport: FakeTokenEndpoint(), clock: clock)
        _ = try? credentials.grantedScopes(for: Fixture.existing)
        _ = credentials.client(for: Fixture.existing)
        _ = try? await credentials.tokenManager(for: Fixture.existing).accessToken()
        _ = try? install.calendar.load(account: Fixture.existing)
    }

    private func everyLaunchPathReadsTheClients(_ install: Install) {
        install.vault.migrateLegacyFiles()
        install.vault.migrateSyncWanted()
        _ = install.vault.available(clientFile: nil)
        _ = install.vault.stored()
        _ = install.vault.defaultStored()
        _ = try? install.vault.loadDefault(clientFile: nil)
        _ = install.vault.source(clientFile: nil)
        _ = install.vault.entry(key: Fixture.client.registryKey)
        _ = install.vault.available(clientFile: nil)
    }

    @Test(arguments: refusals)
    func aRefusedSignInIsAskedAtMostOncePerLaunch(_ refusal: OSStatus) async throws {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        keychain.refuse(service: Fixture.tokenService, account: Fixture.existing, with: refusal)
        let mark = keychain.mark()
        let install = Install.launch(keychain: keychain, canSync: false)
        #expect(throws: TokenStoreError.keychain(refusal)) { _ = try install.synced.load(account: Fixture.existing) }
        await everyLaunchPathReadsTheSignIn(install, clock)
        let budget = Budget(ops: keychain.ops(since: mark))
        #expect(budget.dataReads[Self.tokenItem] == 1, "\(budget.summary)")
        #expect(budget.loginWrites == 0 && budget.dataProtection == 0, "\(budget.summary)")
    }

    @Test(arguments: refusals)
    func aRefusedClientIsAskedAtMostOncePerLaunch(_ refusal: OSStatus) async throws {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        keychain.refuse(service: Fixture.clientService, account: Fixture.client.registryKey, with: refusal)
        let mark = keychain.mark()
        let install = Install.launch(keychain: keychain, canSync: false)
        everyLaunchPathReadsTheClients(install)
        #expect(install.vault.stored().isEmpty)
        let budget = Budget(ops: keychain.ops(since: mark))
        #expect(budget.dataReads[Self.clientItem] == 1, "\(budget.summary)")
        #expect(budget.loginWrites == 0, "\(budget.summary)")
    }

    @Test func aRefusalIsRememberedAndTryAgainAsksOnceMore() throws {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        keychain.refuse(service: Fixture.tokenService, account: Fixture.existing, with: errSecUserCanceled)
        let items = KeychainItems(backend: keychain, canHoldSynchronizableItems: false)
        let tokens = KeychainTokenStore(service: Fixture.tokenService, items: items, isAppProcess: { true })
        let access = KeychainCredentialAccess(items: items, services: [Fixture.tokenService])
        #expect(!access.hasRefusals)
        let mark = keychain.mark()
        for _ in 0..<3 {
            #expect(throws: TokenStoreError.keychain(errSecUserCanceled)) { _ = try tokens.load(account: Fixture.existing) }
        }
        #expect(access.hasRefusals)
        #expect(Budget(ops: keychain.ops(since: mark)).dataReads[Self.tokenItem] == 1)

        keychain.refuse(service: Fixture.tokenService, account: Fixture.existing, with: nil)
        access.forgetRefusals()
        #expect(!access.hasRefusals)
        #expect(try tokens.load(account: Fixture.existing)?.refreshToken == "synthetic-refresh-a")
        #expect(try tokens.load(account: Fixture.existing)?.refreshToken == "synthetic-refresh-a")
        #expect(Budget(ops: keychain.ops(since: mark)).dataReads[Self.tokenItem] == 2)
    }

    @Test func signingInAgainReplacesARefusedItemAndReadsNothingMore() throws {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        keychain.refuse(service: Fixture.tokenService, account: Fixture.existing, with: errSecAuthFailed)
        let install = Install.launch(keychain: keychain, canSync: false)
        #expect(throws: TokenStoreError.keychain(errSecAuthFailed)) { _ = try install.synced.load(account: Fixture.existing) }
        keychain.refuse(service: Fixture.tokenService, account: Fixture.existing, with: nil)
        let fresh = StoredToken(refreshToken: "synthetic-refresh-again", grantedScopes: [GmailScope.readonly],
                                clientID: Fixture.client.clientID)
        try install.synced.save(fresh, account: Fixture.existing)
        let mark = keychain.mark()
        #expect(try install.synced.load(account: Fixture.existing)?.refreshToken == fresh.refreshToken)
        #expect(Budget(ops: keychain.ops(since: mark)).total == 0)
    }

    private static let again = StoredToken(refreshToken: "synthetic-refresh-again", grantedScopes: [GmailScope.readonly],
                                           clientID: Fixture.client.clientID)

    private func signInAgainAfterARefusal(_ keychain: CountingKeychain) throws -> Budget {
        keychain.refuse(service: Fixture.tokenService, account: Fixture.existing, with: errSecUserCanceled)
        let install = Install.launch(keychain: keychain, canSync: true)
        #expect(throws: TokenStoreError.keychain(errSecUserCanceled)) { _ = try install.synced.load(account: Fixture.existing) }
        let mark = keychain.mark()
        try install.synced.save(Self.again, account: Fixture.existing)
        let budget = Budget(ops: keychain.ops(since: mark))
        keychain.refuse(service: Fixture.tokenService, account: Fixture.existing, with: nil)
        return budget
    }

    private func afterRelaunch(_ keychain: CountingKeychain) throws -> (state: TokenSyncState?, shared: SharedGrantRead) {
        let relaunched = Install.launch(keychain: keychain, canSync: true)
        #expect(try relaunched.synced.local.load(account: Fixture.existing)?.refreshToken == Self.again.refreshToken)
        relaunched.synced.migrateLocalSignIns()
        return (try relaunched.synced.syncState(account: Fixture.existing),
                try relaunched.synced.shared.read(account: Fixture.existing))
    }

    private func signIn(_ install: Install) throws {
        try install.synced.save(StoredToken(refreshToken: "synthetic-refresh-a", grantedScopes: [GmailScope.readonly],
                                            clientID: Fixture.client.clientID), account: Fixture.existing)
    }

    @Test func signingInAgainAfterARefusalKeepsASignInThatStaysOnThisMacLocal() throws {
        let keychain = CountingKeychain()
        let first = Install.launch(keychain: keychain, canSync: true)
        try signIn(first)
        #expect(try first.synced.setSyncEnabled(false, account: Fixture.existing) == .notSyncing)

        let budget = try signInAgainAfterARefusal(keychain)
        #expect(budget.dataReads.isEmpty, "no secret is read: \(budget.summary)")
        #expect(budget.dataProtection == 0, "nothing is shared: \(budget.summary)")
        #expect(budget.ops.allSatisfy { $0.kind != "copy" || ($0.skipsDialogs && !$0.wantsData) }, "\(budget.summary)")
        let after = try afterRelaunch(keychain)
        #expect(after.state == .notSyncing && after.shared == .missing)
    }

    @Test func signingInAgainAfterARefusalWithNoRecordedChoiceStaysOnThisMac() throws {
        let keychain = CountingKeychain()
        try Fixture.plantExistingInstall(keychain, TestClock(now: Date(timeIntervalSince1970: 1_790_000_000)))

        let budget = try signInAgainAfterARefusal(keychain)
        #expect(budget.dataReads.isEmpty, "no secret is read: \(budget.summary)")
        #expect(budget.dataProtection == 0, "nothing is shared: \(budget.summary)")
        let after = try afterRelaunch(keychain)
        #expect(after.state == .notSyncing && after.shared == .missing)
    }

    @Test func signingInAgainAfterARefusalSharesOnlyWhenThatWasTheRecordedChoice() throws {
        let keychain = CountingKeychain()
        let first = Install.launch(keychain: keychain, canSync: true)
        try signIn(first)
        #expect(try first.synced.syncState(account: Fixture.existing) == .syncing)

        for lastWrite in ["the device record", "a refresh"] {
            if lastWrite == "a refresh" {
                let running = Install.launch(keychain: keychain, canSync: true)
                try running.synced.local.save(StoredToken(refreshToken: "synthetic-refresh-rotated",
                                                          grantedScopes: [GmailScope.readonly],
                                                          clientID: Fixture.client.clientID), account: Fixture.existing)
            }
            let budget = try signInAgainAfterARefusal(keychain)
            #expect(budget.dataReads.isEmpty, "\(lastWrite): no secret is read: \(budget.summary)")
            let after = try afterRelaunch(keychain)
            #expect(after.state == .syncing, "\(lastWrite)")
            guard case .found(let grant) = after.shared else {
                Issue.record("\(lastWrite): the shared copy is gone: \(after.shared)")
                return
            }
            #expect(grant.refreshToken == Self.again.refreshToken, "\(lastWrite)")
        }
    }

    @Test func aMissingItemIsNotARefusal() throws {
        let keychain = CountingKeychain()
        let items = KeychainItems(backend: keychain, canHoldSynchronizableItems: false)
        let tokens = KeychainTokenStore(service: Fixture.tokenService, items: items, isAppProcess: { true })
        #expect(try tokens.load(account: Fixture.existing) == nil)
        #expect(try tokens.load(account: Fixture.existing) == nil)
        #expect(!KeychainCredentialAccess(items: items, services: []).hasRefusals)
        #expect(keychain.ops(since: 0).count == 1)
    }

    @Test func theRefusalsAreTheDialogAnswersAndNotNotFound() {
        #expect(CredentialOutcome.keychainRefusals == Set(Self.refusals))
        #expect(!CredentialOutcome.keychainRefusals.contains(errSecItemNotFound))
        for status in Self.refusals {
            #expect(CredentialOutcome.keychainRefusal(in: TokenStoreError.keychain(status)) == .keychain(status: status))
            #expect(CredentialOutcome.keychainRefusal(in: OAuthClientStoreError.keychain(status)) == .keychain(status: status))
        }
        #expect(CredentialOutcome.keychainRefusal(in: TokenStoreError.keychain(errSecItemNotFound)) == nil)
        #expect(CredentialOutcome.keychainRefusal(in: TokenStoreError.corrupt) == nil)
    }
}

@Suite struct KeychainPresenceTests {
    private let services = [Fixture.tokenService, Fixture.clientService, Fixture.calendarService]

    @Test func theCheckSeesStoredItemsWithoutAskingForTheirData() throws {
        let keychain = CountingKeychain()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        let access = KeychainCredentialAccess(items: KeychainItems(backend: keychain, style: .macLegacy),
                                              services: services)
        #expect(access.storedItemPresence() == .present)
        let ops = keychain.ops(since: 0)
        #expect(!ops.isEmpty && ops.allSatisfy { $0.kind == "copy" && !$0.wantsData && $0.skipsDialogs && !$0.dataProtection })
    }

    @Test func aFreshMacHasNothingToAskAbout() {
        let keychain = CountingKeychain()
        let access = KeychainCredentialAccess(items: KeychainItems(backend: keychain, style: .macLegacy),
                                              services: services)
        #expect(access.storedItemPresence() == .absent)
        #expect(keychain.ops(since: 0).count == services.count)
    }

    @Test func aCheckThatFailsSaysItDoesNotKnow() throws {
        let keychain = CountingKeychain()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        keychain.refuseLists(errSecInteractionNotAllowed)
        let access = KeychainCredentialAccess(items: KeychainItems(backend: keychain, style: .macLegacy),
                                              services: services)
        #expect(access.storedItemPresence() == .unknown)
    }

    @Test(arguments: KeychainRefusalBudgetTests.refusals)
    func aCheckThatWouldNeedADialogAnswersUnknownAndReadsNoSecret(_ status: OSStatus) throws {
        let keychain = CountingKeychain()
        try Fixture.plantExistingInstall(keychain, TestClock(now: Date(timeIntervalSince1970: 1_790_000_000)))
        keychain.refuseLists(status)
        let access = KeychainCredentialAccess(items: KeychainItems(backend: keychain, style: .macLegacy),
                                              services: services)
        #expect(access.storedItemPresence() == .unknown, "unknown shows no explainer")
        let ops = keychain.ops(since: 0)
        #expect(!ops.isEmpty && ops.allSatisfy { $0.kind == "copy" && !$0.wantsData && $0.skipsDialogs })
        #expect(!access.hasRefusals)
    }

    @Test func theDataProtectionKeychainNeverAsksSoNothingIsChecked() throws {
        let keychain = CountingKeychain()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        let access = KeychainCredentialAccess(items: KeychainItems(backend: keychain, style: .dataProtection),
                                              services: services)
        #expect(access.storedItemPresence() == .absent)
        #expect(keychain.ops(since: 0).isEmpty)
    }
}

@Suite struct KeychainDialogIsolationTests {
    private static let other = "c@example.com"

    private func plantOther(_ keychain: CountingKeychain) throws {
        let token = StoredToken(refreshToken: "synthetic-refresh-c", grantedScopes: [GmailScope.readonly],
                                clientID: Fixture.client.clientID)
        keychain.plant(service: Fixture.tokenService, account: Self.other, data: try JSONEncoder().encode(token),
                       label: KeychainTokenStore.defaultLabel)
    }

    @Test(.timeLimit(.minutes(1)))
    func aDialogForOneItemHoldsUpNoOtherItem() async throws {
        let keychain = CountingKeychain()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        try plantOther(keychain)
        let items = KeychainItems(backend: keychain, canHoldSynchronizableItems: false)
        let tokens = KeychainTokenStore(service: Fixture.tokenService, items: items, isAppProcess: { true })
        let clients = KeychainClientStore(service: Fixture.clientService, items: items, isAppProcess: { true })
        #expect(try tokens.load(account: Self.other) != nil)
        let waiting = keychain.suspend(service: Fixture.tokenService, account: Fixture.existing)
        let pending = Task.detached { try tokens.load(account: Fixture.existing) }
        await waiting.entered()

        let mark = keychain.mark()
        #expect(try tokens.load(account: Self.other)?.refreshToken == "synthetic-refresh-c")
        #expect(!items.canHoldSynchronizableItems)
        #expect(try clients.loadAll().map(\.config.clientID) == [Fixture.client.clientID])
        #expect(keychain.ops(since: mark).contains { $0.service == Fixture.clientService && $0.wantsData })
        #expect(KeychainCredentialAccess(items: items, services: []).hasRefusals == false)

        waiting.resume()
        #expect(try await pending.value?.refreshToken == "synthetic-refresh-a")
    }

    @Test(.timeLimit(.minutes(1)))
    func aDialogForOneAccountHoldsUpNoOtherAccount() async throws {
        let keychain = CountingKeychain()
        keychain.refuseDataProtection(errSecMissingEntitlement)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        try plantOther(keychain)
        let install = Install.launch(keychain: keychain, canSync: false)
        let waiting = keychain.suspend(service: Fixture.tokenService, account: Fixture.existing)
        let pending = Task.detached { try install.synced.load(account: Fixture.existing) }
        await waiting.entered()

        #expect(try install.synced.load(account: Self.other)?.refreshToken == "synthetic-refresh-c")

        waiting.resume()
        #expect(try await pending.value?.refreshToken == "synthetic-refresh-a")
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondReaderOfARefusedItemGetsTheSameAnswerWithoutAskingAgain() async throws {
        let keychain = CountingKeychain()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        try Fixture.plantExistingInstall(keychain, clock)
        keychain.refuse(service: Fixture.tokenService, account: Fixture.existing, with: errSecUserCanceled)
        let items = KeychainItems(backend: keychain, canHoldSynchronizableItems: false)
        let tokens = KeychainTokenStore(service: Fixture.tokenService, items: items, isAppProcess: { true })
        let waiting = keychain.suspend(service: Fixture.tokenService, account: Fixture.existing)
        let first = Task.detached { () -> OSStatus? in
            do { _ = try tokens.load(account: Fixture.existing); return nil } catch { return refusedStatus(error) }
        }
        await waiting.entered()
        let second = Task.detached { () -> OSStatus? in
            do { _ = try tokens.load(account: Fixture.existing); return nil } catch { return refusedStatus(error) }
        }
        waiting.resume()
        #expect(await first.value == errSecUserCanceled)
        #expect(await second.value == errSecUserCanceled)
        #expect(Budget(ops: keychain.ops(since: 0)).dataReads[LoginItem(service: Fixture.tokenService,
                                                                         account: Fixture.existing)] == 1)
    }
}
