import Foundation
import OpenHumanCore
import Synchronization

public enum OAuthClientSyncState: Sendable, Equatable {
    case syncing
    case notSyncing
    case unavailable
}

public struct StoredOAuthClient: Sendable {
    public var config: OAuthClientConfig
    public var isDefault: Bool
    public var sync: OAuthClientSyncState
    public var modifiedAt: Date?
    public var isLocal: Bool
    public var wasShared: Bool

    public init(config: OAuthClientConfig, isDefault: Bool, sync: OAuthClientSyncState, modifiedAt: Date? = nil,
                isLocal: Bool = true, wasShared: Bool = false) {
        self.config = config
        self.isDefault = isDefault
        self.sync = sync
        self.modifiedAt = modifiedAt
        self.isLocal = isLocal
        self.wasShared = wasShared
    }
}

public protocol OAuthClientStore: Sendable {
    var canHoldSharedCopies: Bool { get }
    func loadAll() throws -> [StoredOAuthClient]
    @discardableResult
    func save(_ client: OAuthClientConfig, isDefault: Bool, synchronizable: Bool) throws -> OAuthClientSyncState
    func delete(key: String) throws
    func markShared(key: String) throws
}

extension OAuthClientStore {
    public var canHoldSharedCopies: Bool { true }
    public func markShared(key: String) throws {}
}

public enum OAuthClientStoreError: Error, Equatable, Sendable {
    case keychain(Int32)
    case corrupt
    case notAppProcess
}

public struct OAuthClientSaveError: Error, Equatable, Sendable {
    public var status: Int32?
    public var reason: String

    public init(status: Int32?, reason: String) {
        self.status = status
        self.reason = reason
    }
}

public final class InMemoryOAuthClientStore: OAuthClientStore {
    private struct State {
        var items: [String: StoredOAuthClient] = [:]
        var clock = 0
        var failSaves = false
        var failLoads = false
        var syncAvailable: Bool
        var saves = 0
    }
    private let state: Mutex<State>

    public init(syncAvailable: Bool = true) { state = Mutex(State(syncAvailable: syncAvailable)) }

    public var canHoldSharedCopies: Bool { state.withLock { $0.syncAvailable } }
    public var saveCount: Int { state.withLock { $0.saves } }

    public func failSaves(_ fail: Bool) { state.withLock { $0.failSaves = fail } }
    public func failLoads(_ fail: Bool) { state.withLock { $0.failLoads = fail } }
    public func setSyncAvailable(_ available: Bool) { state.withLock { $0.syncAvailable = available } }

    public func removeSharedCopy(key: String) {
        state.withLock { s in
            guard s.items[key]?.sync == .syncing else { return }
            s.items[key]?.sync = .unavailable
        }
    }

    public func loadAll() throws -> [StoredOAuthClient] {
        try state.withLock { s in
            if s.failLoads { throw OAuthClientStoreError.keychain(-50) }
            return s.items.sorted { $0.key < $1.key }.map(\.value)
        }
    }

    @discardableResult
    public func save(_ client: OAuthClientConfig, isDefault: Bool, synchronizable: Bool) throws -> OAuthClientSyncState {
        try state.withLock { s in
            if s.failSaves { throw OAuthClientStoreError.keychain(-25299) }
            let result: OAuthClientSyncState = !synchronizable ? .notSyncing
                : (s.syncAvailable ? .syncing : .unavailable)
            s.clock += 1
            s.saves += 1
            s.items[client.registryKey] = StoredOAuthClient(
                config: client, isDefault: isDefault, sync: result,
                modifiedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(s.clock)), wasShared: result == .syncing)
            return result
        }
    }

    public func delete(key: String) throws {
        _ = state.withLock { $0.items.removeValue(forKey: key) }
    }

    public func markShared(key: String) throws {
        state.withLock { $0.items[key]?.wasShared = true }
    }
}

public struct OAuthClientMigrationReport: Sendable, Equatable {
    public var migrated = 0
    public var alreadyThere = 0
    public var filesDeleted = 0
    public var skipped = 0
}

public struct OAuthClientShareReport: Sendable, Equatable {
    public var shared = 0
    public var alreadyShared = 0
    public var stayLocal = 0
    public var removedElsewhere = 0
    public var failed = 0

    public init() {}
}

public final class OAuthClientVault: Sendable {
    public let store: any OAuthClientStore
    private let storeDirectory: URL?
    private let log: CredentialChainLog
    private let importedHere = Mutex<[OAuthClientConfig]>([])

    public init(store: any OAuthClientStore, storeDirectory: URL? = nil, log: CredentialChainLog = .shared) {
        self.store = store
        self.storeDirectory = storeDirectory
        self.log = log
    }

    public func stored() -> [StoredOAuthClient] {
        do { return try store.loadAll() } catch {
            Log(.keychain).error("OAuth clients: the Keychain could not be read (\(Self.code(error))); the client files "
                                 + "and this launch's import are used")
            return []
        }
    }

    public func legacyFileClients() -> [OAuthClientConfig] {
        guard let directory = storeDirectory else { return [] }
        var result: [OAuthClientConfig] = []
        if let legacy = OAuthClientConfig.legacyDefaultClient(storeDirectory: directory) { result.append(legacy) }
        for client in OAuthClientConfig.importedClients(storeDirectory: directory)
        where !result.contains(where: { $0.clientID == client.clientID }) {
            result.append(client)
        }
        return result
    }

    public func defaultStored() -> StoredOAuthClient? {
        let all = stored()
        return all.first(where: \.isDefault) ?? all.first
    }

    func environmentClient(_ environment: [String: String]) throws -> OAuthClientConfig? {
        guard OAuthClientConfig.resolveSource(environment: environment, storeDirectory: nil) == .environment else { return nil }
        return try OAuthClientConfig.load(environment: environment, storeDirectory: nil)
    }

    private func defaultWithoutEnvironment() -> OAuthClientConfig? {
        if let stored = defaultStored() { return stored.config }
        if let imported = importedHere.withLock({ $0.last }) { return imported }
        return legacyFileClients().first
    }

    public func loadDefault(environment: [String: String]) throws -> OAuthClientConfig {
        if let env = try environmentClient(environment) { return env }
        if let client = defaultWithoutEnvironment() { return client }
        throw OAuthError.configurationMissing(
            "no OAuth client: set \(OAuthClientConfig.environmentKey), import a Desktop client JSON, or use the client picker")
    }

    public func source(environment: [String: String]) -> OAuthClientSource {
        if OAuthClientConfig.resolveSource(environment: environment, storeDirectory: nil) == .environment { return .environment }
        return defaultWithoutEnvironment() == nil ? .missing : .storeFile
    }

    public func available(environment: [String: String]) -> [OAuthClientConfig] {
        var result: [OAuthClientConfig] = []
        func add(_ client: OAuthClientConfig) {
            if !result.contains(where: { $0.clientID == client.clientID }) { result.append(client) }
        }
        if let main = try? loadDefault(environment: environment) { add(main) }
        for item in stored() { add(item.config) }
        for client in importedHere.withLock({ $0 }) { add(client) }
        for client in legacyFileClients() { add(client) }
        return result
    }

    public func entry(key: String) -> StoredOAuthClient? { stored().first { $0.config.registryKey == key } }

    public struct ImportResult: Sendable {
        public var config: OAuthClientConfig
        public var sync: OAuthClientSyncState
    }

    @discardableResult
    public func importClient(_ data: Data) throws -> OAuthClientConfig {
        try importClientReporting(data).config
    }

    @discardableResult
    public func importClientReporting(_ data: Data) throws -> ImportResult {
        let config = try OAuthClientConfig.inspectImport(data)
        let existing = stored()
        let current = existing.first(where: \.isDefault) ?? existing.first
        let becomesDefault = current == nil || current?.config.clientID == config.clientID
            || current?.config.hasClientSecret == false
        let previous = existing.first { $0.config.clientID == config.clientID }
        let wantsSync = previous.map { $0.sync != .notSyncing } ?? true
        let sync: OAuthClientSyncState
        do {
            sync = try store.save(config, isDefault: becomesDefault || (previous?.isDefault ?? false),
                                  synchronizable: wantsSync)
        } catch {
            var status: Int32?
            if case OAuthClientStoreError.keychain(let code) = error { status = code }
            Log(.keychain).error("import: the client could not be saved in the Keychain (\(Self.code(error)))")
            throw OAuthClientSaveError(status: status, reason: Self.code(error))
        }
        if becomesDefault {
            for other in existing where other.isDefault && other.config.clientID != config.clientID {
                _ = try? store.save(other.config, isDefault: false, synchronizable: other.sync != .notSyncing)
            }
        }
        importedHere.withLock { list in
            list.removeAll { $0.clientID == config.clientID }
            list.append(config)
        }
        Log(.oauth).notice("OAuth client saved in the Keychain\(becomesDefault ? " (also the default)" : "")"
                           + (sync == .unavailable ? "; on this Mac only (iCloud Keychain unavailable)" : ""))
        return ImportResult(config: config, sync: sync)
    }

    public func remove(key: String) throws {
        guard OAuthClientConfig.isRegistryKey(key) else {
            throw OAuthError.configurationMissing("clients: not a client key")
        }
        do { try store.delete(key: key) } catch {
            throw OAuthError.configurationMissing("clients: the Keychain item could not be removed")
        }
        importedHere.withLock { $0.removeAll { $0.registryKey == key } }
        if let directory = storeDirectory {
            try? OAuthClientConfig.removeImportedClient(key: key, storeDirectory: directory)
            if OAuthClientConfig.legacyDefaultClient(storeDirectory: directory)?.registryKey == key {
                try? OAuthClientConfig.deleteClientFile(OAuthClientConfig.storeFileURL(directory))
            }
            OAuthClientConfig.removeClientsDirectoryIfEmpty(directory)
        }
        Log(.oauth).notice("OAuth client removed from the Keychain")
    }

    @discardableResult
    public func setSynchronizable(key: String, _ on: Bool) throws -> OAuthClientSyncState {
        guard let entry = entry(key: key) else { throw OAuthError.configurationMissing("clients: no such client") }
        do { return try store.save(entry.config, isDefault: entry.isDefault, synchronizable: on) } catch {
            throw OAuthError.configurationMissing("clients: the Keychain item could not be changed")
        }
    }

    // Why: a client saved while iCloud Keychain was unavailable would otherwise stay on this device forever
    @discardableResult
    public func migrateSyncWanted() -> OAuthClientShareReport {
        var report = OAuthClientShareReport()
        guard store.canHoldSharedCopies else {
            log.record(.entitlement, .noEntitlement)
            return report
        }
        let entries: [StoredOAuthClient]
        do { entries = try store.loadAll() } catch {
            log.record(.shareClient, Self.outcome(error))
            Log(.keychain).error("OAuth clients: the Keychain could not be read at launch (\(Self.code(error)))")
            return report
        }
        for entry in entries where entry.isLocal {
            let subject = CredentialChainLog.subject(client: entry.config.clientID)
            switch entry.sync {
            case .notSyncing:
                report.stayLocal += 1
            case .syncing where entry.wasShared:
                report.alreadyShared += 1
            case .syncing:
                // Why: remembered here, so a later removal on another device is not undone by sharing it again
                do {
                    try store.markShared(key: entry.config.registryKey)
                    report.alreadyShared += 1
                } catch {
                    report.failed += 1
                    log.record(.shareClient, Self.outcome(error), subject: subject)
                }
            case .unavailable where entry.wasShared:
                report.removedElsewhere += 1
                log.record(.shareClient, .removedElsewhere, subject: subject)
            case .unavailable:
                do {
                    let result = try store.save(entry.config, isDefault: entry.isDefault, synchronizable: true)
                    if result == .syncing {
                        report.shared += 1
                    } else {
                        report.failed += 1
                        if !store.canHoldSharedCopies { log.record(.shareClient, .noEntitlement, subject: subject) }
                    }
                } catch {
                    report.failed += 1
                    log.record(.shareClient, Self.outcome(error), subject: subject)
                }
            }
        }
        if report.shared + report.removedElsewhere + report.failed > 0 {
            Log(.oauth).notice("OAuth clients at launch: \(report.shared) shared, \(report.alreadyShared) already shared, "
                               + "\(report.removedElsewhere) removed on another device, \(report.failed) left for the next "
                               + "launch")
        }
        return report
    }

    static func outcome(_ error: any Error) -> CredentialOutcome {
        if case OAuthClientStoreError.keychain(let status) = error { return .keychain(status: status) }
        return .unreadable
    }

    static func code(_ error: any Error) -> String {
        if case OAuthClientStoreError.keychain(let status) = error { return "OSStatus \(status)" }
        if let save = error as? OAuthClientSaveError { return save.status.map { "OSStatus \($0)" } ?? save.reason }
        return String(describing: type(of: error))
    }

    @discardableResult
    public func migrateLegacyFiles() -> OAuthClientMigrationReport {
        var report = OAuthClientMigrationReport()
        guard let directory = storeDirectory else { return report }

        let legacy = OAuthClientConfig.legacyDefaultClient(storeDirectory: directory)
        var files: [(client: OAuthClientConfig, url: URL, isLegacy: Bool)] = []
        if let legacy { files.append((legacy, OAuthClientConfig.storeFileURL(directory), true)) }
        for client in OAuthClientConfig.importedClients(storeDirectory: directory) {
            files.append((client, OAuthClientConfig.clientFileURL(directory, key: client.registryKey), false))
        }
        if legacy == nil, SecureFile.inspect(OAuthClientConfig.storeFileURL(directory)).kind != .missing { report.skipped += 1 }

        guard !files.isEmpty else {
            OAuthClientConfig.removeClientsDirectoryIfEmpty(directory)
            return report
        }
        var defaultTaken = stored().contains(where: \.isDefault)

        for file in files {
            let makeDefault = file.isLegacy && !defaultTaken
            let entry = stored().first { $0.config.clientID == file.client.clientID }
            if let entry, entry.isLocal {
                report.alreadyThere += 1
                if makeDefault, !entry.isDefault {
                    _ = try? store.save(entry.config, isDefault: true, synchronizable: entry.sync != .notSyncing)
                }
                if makeDefault { defaultTaken = true }
            } else {
                do {
                    try store.save(entry?.config ?? file.client, isDefault: makeDefault || (entry?.isDefault ?? false),
                                   synchronizable: entry.map { $0.sync != .notSyncing } ?? true)
                } catch {
                    Log(.keychain).error("OAuth client migration: a client could not be saved in the Keychain "
                                         + "(\(Self.code(error))); its file stays")
                    report.skipped += 1
                    continue
                }
                guard stored().contains(where: { $0.config.clientID == file.client.clientID && $0.isLocal }) else {
                    Log(.keychain).error("OAuth client migration: the saved client could not be read back; its file stays")
                    report.skipped += 1
                    continue
                }
                if makeDefault { defaultTaken = true }
                if entry == nil { report.migrated += 1 } else { report.alreadyThere += 1 }
            }
            if (try? OAuthClientConfig.deleteClientFile(file.url)) != nil { report.filesDeleted += 1 }
        }
        OAuthClientConfig.removeClientsDirectoryIfEmpty(directory)
        if report.migrated + report.filesDeleted > 0 {
            Log(.oauth).notice("OAuth clients moved into the Keychain: \(report.migrated) saved, \(report.filesDeleted) files deleted")
        }
        return report
    }
}
