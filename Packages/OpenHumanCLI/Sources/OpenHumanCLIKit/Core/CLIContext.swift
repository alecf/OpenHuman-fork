import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore
import OpenHumanSync

public enum AccountScope: Sendable { case one, oneOrAll }

public final class CLIContext {
    public let env: CLIEnvironment
    public let global: GlobalOptions
    public let path: String
    public let meta: CommandMeta
    let safeMode: SafeMode
    public let location: StoreLocation
    public var warnings: [String] = []
    var readonlyByDefault = false
    public private(set) var accountsUsed: [AccountItem] = []
    private var readStore: MailStore?
    private var writeStore: MailStore?
    private var cachedEngine: MailEngine?

    init(env: CLIEnvironment, global: GlobalOptions, path: String, meta: CommandMeta, safeMode: SafeMode) throws {
        self.env = env
        self.global = global
        self.path = path
        self.meta = meta
        self.safeMode = safeMode
        let variables = env.variables
        if let home = global.home, !home.isEmpty {
            location = StoreLocation(directory: URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true))
        } else {
            do { location = try StoreLocation.resolve(environment: variables) } catch {
                throw CLIError("failure", "Cannot resolve the store location.", .failure)
            }
        }
    }

    public var now: Date { env.clock.now }
    public var dryRun: Bool { global.dryRun }
    public var timeout: Duration { global.timeout.flatMap(parseDuration) ?? .seconds(30) }

    private func open(readOnly: Bool) throws -> MailStore {
        if let provider = env.storeProvider { return try provider(readOnly) }
        guard FileManager.default.fileExists(atPath: location.databaseURL.path) else {
            throw CLIError("no_store", "No OpenHuman Mail store found. Open the app and sign in first.", .authRequired)
        }
        do {
            let name = env.variables["OPENHUMAN_STORE_NOTIFICATION"].flatMap { $0.isEmpty ? nil : $0 } ?? OHIdentifiers.storeChangedNotification
            return try MailStore.open(StoreOptions(location: location, processKind: .cli, readOnly: readOnly,
                                                   observeExternalChanges: false, appVersion: env.appVersion,
                                                   changeNotificationName: name))
        } catch { throw CLIError.map(error) }
    }

    public func store() throws -> MailStore {
        if let writeStore { return writeStore }
        if let readStore { return readStore }
        let store = try open(readOnly: true)
        readStore = store
        return store
    }

    func writableStore() throws -> MailStore {
        precondition(meta.writes != .none && !global.dryRun, "writableStore() outside a real write")
        if let writeStore { return writeStore }
        let store = try open(readOnly: false)
        writeStore = store
        return store
    }

    func engine() throws -> MailEngine {
        if let cachedEngine { return cachedEngine }
        let store = try writableStore()
        let configuration = EngineConfiguration(role: .localClient, appVersion: env.appVersion,
                                                gmail: GmailClientConfig(userAgent: "openhuman-cli/\(env.appVersion)"),
                                                clock: env.clock, safeMode: safeMode)
        let engine = MailEngine(store: store, gmailFactory: nil, tokenStore: nil, oauthClient: nil,
                                configuration: configuration, systemEvents: nil)
        cachedEngine = engine
        return engine
    }

    func close() {
        try? readStore?.close()
        try? writeStore?.close()
        readStore = nil
        writeStore = nil
    }

    public func accounts(_ scope: AccountScope) throws -> [AccountItem] {
        let store = try store()
        let all = try store.accounts().filter { $0.status != .removing }
        guard !all.isEmpty else { throw CLIError.noAccount }
        let chosen: [AccountItem]
        if let selector = global.account, !selector.isEmpty {
            if selector.lowercased() == "all" {
                guard scope == .oneOrAll else {
                    throw CLIError.usage("This command works on one account. Pass --account <email|alias>.", code: "account_required")
                }
                chosen = all.filter { $0.status != .disabled }
            } else {
                guard let found = try store.account(matching: selector) else { throw CLIError.notFound("The account") }
                chosen = [found]
            }
        } else if let name = try store.setting(.defaultAccount, scope: .global),
                  let found = try store.account(matching: name) {
            chosen = [found]
        } else if all.count == 1 {
            chosen = all
        } else {
            throw CLIError.usage("Several accounts. Pass --account <email|alias|all> or set one with `openhuman accounts default`.",
                                 code: "account_required", details: ["accounts": .strings(all.map(\.email))])
        }
        if chosen.isEmpty { throw CLIError.noAccount }
        accountsUsed = chosen
        return chosen
    }

    func lookupAccounts() throws -> [AccountItem] {
        do { return try accounts(.oneOrAll) } catch let e as CLIError where e.code == "account_required" {
            let all = try store().accounts().filter { $0.status != .removing && $0.status != .disabled }
            accountsUsed = all
            return all
        }
    }

    func requireWritable(_ account: AccountItem) throws {
        if account.status == .needsReauth || account.status == .disabled {
            throw CLIError("auth_required", "The account needs to be reauthorized in OpenHuman Mail.", .authRequired)
        }
    }

    func noteReauth(_ accounts: [AccountItem]) {
        if accounts.contains(where: { $0.status == .needsReauth }) {
            warnings.append("An account needs to be reauthorized in OpenHuman Mail; showing cached data.")
        }
    }

    func appIsRunning(_ accounts: [AccountItem]) -> Bool {
        guard let store = try? store() else { return false }
        return accounts.contains { (try? store.lease(account: $0.id))?.isLive == true }
    }

    struct Freshness { var account: AccountItem; var syncedAt: Date?; var stale: Bool; var ownerLive: Bool }

    func freshness(_ account: AccountItem) -> Freshness {
        let status = try? store().syncStatus(account: account.id)
        let synced = status?.lastSuccessAt
        let live = status?.owner?.isLive == true
        let old = synced.map { now.timeIntervalSince($0) > 300 } ?? true
        return Freshness(account: account, syncedAt: synced, stale: old && !live, ownerLive: live)
    }
}
