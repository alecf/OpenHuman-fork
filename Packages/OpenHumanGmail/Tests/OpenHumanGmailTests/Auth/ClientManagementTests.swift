import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanGmail

private enum Managed {
    static let workID = "333333333333-managedworkcccc.apps.googleusercontent.com"
    static let otherID = "444444444444-managedotherdddd.apps.googleusercontent.com"

    static func json(_ id: String, secret: String = "SYNTHETIC-MANAGED", tokenURI: String = "https://oauth2.googleapis.com/token")
        -> Data {
        Data(#"{"installed":{"client_id":"\#(id)","client_secret":"\#(secret)","token_uri":"\#(tokenURI)"}}"#.utf8)
    }
}

@Suite struct ClientManagementTests {
    @Test func inspectingAFileValidatesLikeAnImportAndWritesNothing() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let config = try OAuthClientConfig.inspectImport(Managed.json(Managed.workID))
        #expect(config.clientID == Managed.workID && config.registryKey.count == 32)
        #expect(throws: OAuthError.self) {
            _ = try OAuthClientConfig.inspectImport(Managed.json(Managed.workID, tokenURI: "https://evil.example.com/token"))
        }
        #expect(throws: OAuthError.self) { _ = try OAuthClientConfig.inspectImport(Data("{}".utf8)) }
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("oauth-clients").path))
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("oauth-client.json").path))
    }

    @Test func registryKeysAreHexOnly() {
        #expect(OAuthClientConfig.isRegistryKey(OAuthClientConfig.registryKey(clientID: Managed.workID)))
        #expect(!OAuthClientConfig.isRegistryKey("../oauth-client"))
        #expect(!OAuthClientConfig.isRegistryKey(String(repeating: "A", count: 32)), "uppercase is not a key")
        #expect(!OAuthClientConfig.isRegistryKey(String(repeating: "a", count: 31)))
        #expect(!OAuthClientConfig.isRegistryKey(""))
    }

    @Test func theImportedDateIsTheFilesAndAReimportUpdatesItInPlace() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let work = try OAuthClientConfig.importClient(Managed.json(Managed.workID, secret: "SYNTHETIC-OLD"),
                                                      storeDirectory: dir.url)
        let file = dir.url.appendingPathComponent("oauth-clients/\(work.registryKey).json")
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        #expect(OAuthClientConfig.importedAt(key: work.registryKey, storeDirectory: dir.url) == past)
        #expect(OAuthClientConfig.importedAt(key: "not-a-key", storeDirectory: dir.url) == nil)
        #expect(OAuthClientConfig.importedAt(key: OAuthClientConfig.registryKey(clientID: Managed.otherID),
                                             storeDirectory: dir.url) == nil, "no file, no date")

        _ = try OAuthClientConfig.importClient(Managed.json(Managed.workID, secret: "SYNTHETIC-NEW"), storeDirectory: dir.url)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.appendingPathComponent("oauth-clients").path)
        #expect(names == ["\(work.registryKey).json"])
        #expect((OAuthClientConfig.importedAt(key: work.registryKey, storeDirectory: dir.url) ?? past) > past)
        #expect(OAuthClientConfig.importedClients(storeDirectory: dir.url).map(\.clientSecret) == ["SYNTHETIC-NEW"])
        #expect(try OAuthClientConfig.load(clientFile: nil, storeDirectory: dir.url).clientSecret
                == "SYNTHETIC-NEW")
        #expect(posixMode(file) == 0o600)
    }

    @Test func removingDeletesOnlyThatClientsOwnFile() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let work = try OAuthClientConfig.importClient(Managed.json(Managed.workID), storeDirectory: dir.url)
        let other = try OAuthClientConfig.importClient(Managed.json(Managed.otherID), storeDirectory: dir.url)
        let defaultFile = dir.url.appendingPathComponent("oauth-client.json")
        let defaultBefore = try Data(contentsOf: defaultFile)

        try OAuthClientConfig.removeImportedClient(key: other.registryKey, storeDirectory: dir.url)
        #expect(OAuthClientConfig.importedClients(storeDirectory: dir.url).map(\.clientID) == [Managed.workID])
        #expect(try Data(contentsOf: defaultFile) == defaultBefore, "the default file is never touched")
        try OAuthClientConfig.removeImportedClient(key: work.registryKey, storeDirectory: dir.url)
        #expect(OAuthClientConfig.importedClients(storeDirectory: dir.url).isEmpty)
        #expect(try OAuthClientConfig.load(clientFile: nil, storeDirectory: dir.url).clientID
                == Managed.workID)
        try OAuthClientConfig.removeImportedClient(key: work.registryKey, storeDirectory: dir.url)
        #expect(throws: OAuthError.self) {
            try OAuthClientConfig.removeImportedClient(key: "../oauth-client", storeDirectory: dir.url)
        }
        #expect(FileManager.default.fileExists(atPath: defaultFile.path))
    }

    @Test func aSymlinkInTheFolderIsRefusedAndItsTargetKept() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        _ = try OAuthClientConfig.importClient(Managed.json(Managed.workID), storeDirectory: dir.url)
        let target = dir.url.appendingPathComponent("elsewhere.json")
        try Managed.json(Managed.otherID).write(to: target)
        let key = OAuthClientConfig.registryKey(clientID: Managed.otherID)
        let link = dir.url.appendingPathComponent("oauth-clients/\(key).json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: OAuthError.self) { try OAuthClientConfig.removeImportedClient(key: key, storeDirectory: dir.url) }
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(OAuthClientConfig.importedAt(key: key, storeDirectory: dir.url) == nil)
    }
}
