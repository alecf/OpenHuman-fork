import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanGmail

private enum Vaulted {
    static let workID = "777777777777-vaultworkeeee.apps.googleusercontent.com"
    static let otherID = "888888888888-vaultotherffff.apps.googleusercontent.com"

    static func json(_ id: String, secret: String = "SYNTHETIC-VAULT") -> Data {
        Data(#"{"installed":{"client_id":"\#(id)","client_secret":"\#(secret)"}}"#.utf8)
    }
}

@Suite struct OAuthClientVaultTests {
    @Test func theFirstClientIsTheDefaultAndSynchronizable() throws {
        let store = InMemoryOAuthClientStore()
        let vault = OAuthClientVault(store: store)
        let work = try vault.importClient(Vaulted.json(Vaulted.workID))
        let other = try vault.importClient(Vaulted.json(Vaulted.otherID))
        let all = try store.loadAll()
        #expect(all.count == 2 && all.allSatisfy { $0.sync == .syncing })
        #expect(all.filter(\.isDefault).map(\.config.clientID) == [Vaulted.workID], "a later client does not take over")
        #expect(try vault.loadDefault(environment: [:]).clientID == work.clientID)
        #expect(vault.available(environment: [:]).map(\.clientID) == [Vaulted.workID, other.clientID])
        #expect(vault.source(environment: [:]) == .storeFile)
    }

    @Test func nothingStoredIsMissingAndABadFileIsRefusedWithoutWriting() throws {
        let store = InMemoryOAuthClientStore()
        let vault = OAuthClientVault(store: store)
        #expect(vault.source(environment: [:]) == .missing)
        #expect(throws: OAuthError.self) { _ = try vault.loadDefault(environment: [:]) }
        let evil = Data(#"{"installed":{"client_id":"x","token_uri":"https://evil.example.com/t"}}"#.utf8)
        #expect(throws: OAuthError.self) { _ = try vault.importClient(evil) }
        #expect(try store.loadAll().isEmpty)
    }

    @Test func replacingTheSameClientKeepsItsSyncChoiceAndTheDefault() throws {
        let store = InMemoryOAuthClientStore()
        let vault = OAuthClientVault(store: store)
        let work = try vault.importClient(Vaulted.json(Vaulted.workID, secret: "SYNTHETIC-OLD"))
        try vault.setSynchronizable(key: work.registryKey, false)
        _ = try vault.importClient(Vaulted.json(Vaulted.workID, secret: "SYNTHETIC-NEW"))
        let all = try store.loadAll()
        #expect(all.count == 1 && all[0].config.clientSecret == "SYNTHETIC-NEW")
        #expect(all[0].sync == .notSyncing && all[0].isDefault, "a Replace never turns sync back on")
    }

    @Test func dontSyncAndSyncAgainRewriteOnlyThatItem() throws {
        let store = InMemoryOAuthClientStore()
        let vault = OAuthClientVault(store: store)
        let work = try vault.importClient(Vaulted.json(Vaulted.workID))
        let other = try vault.importClient(Vaulted.json(Vaulted.otherID))
        #expect(try vault.setSynchronizable(key: other.registryKey, false) == .notSyncing)
        #expect(try vault.entry(key: other.registryKey)?.sync == .notSyncing)
        #expect(try vault.entry(key: work.registryKey)?.sync == .syncing)
        #expect(try vault.setSynchronizable(key: other.registryKey, true) == .syncing)
        #expect(throws: OAuthError.self) { try vault.setSynchronizable(key: "0123456789abcdef0123456789abcdef", true) }
    }

    @Test func aBuildThatCannotSyncReportsItInsteadOfPretending() throws {
        let vault = OAuthClientVault(store: InMemoryOAuthClientStore(syncAvailable: false))
        let work = try vault.importClient(Vaulted.json(Vaulted.workID))
        #expect(vault.entry(key: work.registryKey)?.sync == .unavailable)
    }

    @Test func removeDeletesOnlyThatClientsItem() throws {
        let store = InMemoryOAuthClientStore()
        let vault = OAuthClientVault(store: store)
        let work = try vault.importClient(Vaulted.json(Vaulted.workID))
        let other = try vault.importClient(Vaulted.json(Vaulted.otherID))
        try vault.remove(key: other.registryKey)
        #expect(try store.loadAll().map(\.config.registryKey) == [work.registryKey])
        #expect(throws: OAuthError.self) { try vault.remove(key: "../oauth-client") }
    }

    @Test func aKeychainThatRefusesFailsTheImportWithoutALeakedValue() throws {
        let store = InMemoryOAuthClientStore()
        store.failSaves(true)
        let vault = OAuthClientVault(store: store)
        do {
            _ = try vault.importClient(Vaulted.json(Vaulted.workID, secret: "SYNTHETIC-LEAK"))
            Issue.record("expected the import to fail")
        } catch {
            #expect(!"\(error)".contains("SYNTHETIC-LEAK") && !"\(error)".contains(Vaulted.workID))
        }
    }

    @Test func theOldFilesMoveIntoTheKeychainOnceAndAreDeleted() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let work = try OAuthClientConfig.importClient(Vaulted.json(Vaulted.workID), storeDirectory: dir.url)
        let other = try OAuthClientConfig.importClient(Vaulted.json(Vaulted.otherID), storeDirectory: dir.url)
        let store = InMemoryOAuthClientStore()
        let vault = OAuthClientVault(store: store, storeDirectory: dir.url)

        let report = vault.migrateLegacyFiles()
        #expect(report.migrated == 2 && report.filesDeleted == 3 && report.skipped == 0, "two clients, three files")
        let all = try store.loadAll()
        #expect(Set(all.map(\.config.registryKey)) == [work.registryKey, other.registryKey])
        #expect(all.allSatisfy { $0.sync == .syncing })
        #expect(all.filter(\.isDefault).map(\.config.clientID) == [Vaulted.workID], "the legacy file's client is the default")
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("oauth-client.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("oauth-clients").path))

        let again = vault.migrateLegacyFiles()
        #expect(again == OAuthClientMigrationReport())
        #expect(try store.loadAll().count == 2)
    }

    @Test func aClientAlreadyInTheKeychainIsNotOverwrittenByItsOldFile() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        _ = try OAuthClientConfig.importClient(Vaulted.json(Vaulted.workID, secret: "SYNTHETIC-FILE"), storeDirectory: dir.url)
        let store = InMemoryOAuthClientStore()
        let vault = OAuthClientVault(store: store, storeDirectory: dir.url)
        _ = try vault.importClient(Vaulted.json(Vaulted.workID, secret: "SYNTHETIC-KEYCHAIN"))
        try vault.setSynchronizable(key: OAuthClientConfig.registryKey(clientID: Vaulted.workID), false)

        let report = vault.migrateLegacyFiles()
        #expect(report.migrated == 0 && report.alreadyThere == 2 && report.filesDeleted == 2)
        let kept = try #require(try store.loadAll().first)
        #expect(kept.config.clientSecret == "SYNTHETIC-KEYCHAIN" && kept.sync == .notSyncing)
    }

    @Test func aKeychainThatRefusesLeavesTheFilesWhereTheyAre() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        _ = try OAuthClientConfig.importClient(Vaulted.json(Vaulted.workID), storeDirectory: dir.url)
        let store = InMemoryOAuthClientStore()
        store.failSaves(true)
        let report = OAuthClientVault(store: store, storeDirectory: dir.url).migrateLegacyFiles()
        #expect(report.migrated == 0 && report.filesDeleted == 0 && report.skipped == 2)
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("oauth-client.json").path))
        #expect(OAuthClientConfig.importedClients(storeDirectory: dir.url).count == 1)
    }

    @Test func aSymlinkedClientFileIsNeverFollowedOrDeleted() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let outside = dir.url.appendingPathComponent("outside.json")
        try Vaulted.json(Vaulted.workID).write(to: outside)
        try FileManager.default.createSymbolicLink(at: dir.url.appendingPathComponent("oauth-client.json"),
                                                   withDestinationURL: outside)
        let store = InMemoryOAuthClientStore()
        let report = OAuthClientVault(store: store, storeDirectory: dir.url).migrateLegacyFiles()
        #expect(report.migrated == 0 && report.filesDeleted == 0)
        #expect(try store.loadAll().isEmpty && FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func aKeychainThatCannotBeReadNeverHidesTheClientFiles() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        _ = try OAuthClientConfig.importClient(Vaulted.json(Vaulted.workID), storeDirectory: dir.url)
        let store = InMemoryOAuthClientStore()
        store.failLoads(true)
        let vault = OAuthClientVault(store: store, storeDirectory: dir.url)
        let report = vault.migrateLegacyFiles()
        #expect(report.filesDeleted == 0 && report.skipped == 2, "never deleted without a read-back")
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("oauth-client.json").path))
        #expect(try vault.loadDefault(environment: [:]).clientID == Vaulted.workID)
        #expect(vault.source(environment: [:]) == .storeFile)
        #expect(vault.available(environment: [:]).map(\.clientID) == [Vaulted.workID])
        store.failLoads(false)
        let again = vault.migrateLegacyFiles()
        #expect(again.filesDeleted == 2)
        #expect(try store.loadAll().map(\.config.clientID) == [Vaulted.workID])
    }

    @Test func anImportIsUsableAtOnceEvenWhenTheReadBackFails() throws {
        let store = InMemoryOAuthClientStore()
        store.failLoads(true)
        let vault = OAuthClientVault(store: store)
        #expect(vault.source(environment: [:]) == .missing)
        let result = try vault.importClientReporting(Vaulted.json(Vaulted.workID))
        #expect(result.sync == .syncing)
        #expect(vault.source(environment: [:]) == .storeFile)
        #expect(try vault.loadDefault(environment: [:]).clientID == Vaulted.workID)
    }

    @Test func anImportThatNoStoreTakesSaysWhyWithTheCode() throws {
        let store = InMemoryOAuthClientStore()
        store.failSaves(true)
        let vault = OAuthClientVault(store: store)
        #expect(throws: OAuthClientSaveError(status: -25299, reason: "OSStatus -25299")) {
            _ = try vault.importClient(Vaulted.json(Vaulted.workID))
        }
        #expect(vault.source(environment: [:]) == .missing)
        #expect(throws: OAuthError.self) { _ = try vault.importClient(Data("{}".utf8)) }
    }

    @Test func aClientOnlyInTheSynchronizableCopyIsWrittenLocallyBeforeItsFileGoes() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        _ = try OAuthClientConfig.importClient(Vaulted.json(Vaulted.workID), storeDirectory: dir.url)
        let store = SyncOnlyThenLocalStore()
        let vault = OAuthClientVault(store: store, storeDirectory: dir.url)
        let report = vault.migrateLegacyFiles()
        #expect(store.localSaves == 1, "written to this Mac's own item first")
        #expect(report.filesDeleted == 2)
    }

    @Test func removingAClientAlsoRemovesItsLegacyFiles() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let work = try OAuthClientConfig.importClient(Vaulted.json(Vaulted.workID), storeDirectory: dir.url)
        let store = InMemoryOAuthClientStore()
        store.failLoads(true)
        let vault = OAuthClientVault(store: store, storeDirectory: dir.url)
        vault.migrateLegacyFiles()
        try vault.remove(key: work.registryKey)
        #expect(vault.source(environment: [:]) == .missing, "a removed client never comes back from its file")
    }
}

private final class SyncOnlyThenLocalStore: OAuthClientStore, @unchecked Sendable {
    private let lock = NSLock()
    private var local: OAuthClientConfig?
    private(set) var localSaves = 0

    func loadAll() throws -> [StoredOAuthClient] {
        lock.lock(); defer { lock.unlock() }
        let config = local ?? OAuthClientConfig.google(clientID: Vaulted.workID, clientSecret: "SYNTHETIC-SYNCED")
        return [StoredOAuthClient(config: config, isDefault: true, sync: .syncing, isLocal: local != nil)]
    }

    func save(_ client: OAuthClientConfig, isDefault: Bool, synchronizable: Bool) throws -> OAuthClientSyncState {
        lock.lock(); defer { lock.unlock() }
        local = client
        localSaves += 1
        return .syncing
    }

    func delete(key: String) throws {}
}
