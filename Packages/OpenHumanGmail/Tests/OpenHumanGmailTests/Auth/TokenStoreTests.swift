import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct TokenStoreTests {
    private let token = Synthetic.token(expiry: Date(timeIntervalSince1970: 1_790_000_000))

    @Test func inMemoryRoundTrip() throws {
        let store = InMemoryTokenStore()
        try store.save(token, account: "Me@Example.com")
        #expect(try store.load(account: "me@example.com") == token)
        #expect(try store.allAccounts() == ["me@example.com"])
        try store.delete(account: "ME@EXAMPLE.COM")
        #expect(try store.load(account: "me@example.com") == nil)
        #expect(try store.allAccounts().isEmpty)
    }

    @Test func fileStoreUsesOwnerOnlyModes() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let store = FileTokenStore(baseDirectory: dir.url)
        try store.save(token, account: "Me@Example.com")
        let file = dir.url.appendingPathComponent("tokens/me@example.com.json")
        #expect(posixMode(dir.url.appendingPathComponent("tokens")) == 0o700)
        #expect(posixMode(file) == 0o600)
        #expect(try store.load(account: "me@example.com") == token)
        #expect(try store.allAccounts() == ["me@example.com"])
        var updated = token
        updated.accessToken = "synthetic-access-9"
        try store.save(updated, account: "me@example.com")
        #expect(posixMode(file) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appendingPathComponent("tokens").path)
                == ["me@example.com.json"])
        try store.delete(account: "me@example.com")
        #expect(try store.load(account: "me@example.com") == nil)
        try store.delete(account: "me@example.com")
    }

    @Test func fileStoreTightensALooseDirectory() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let tokens = dir.url.appendingPathComponent("tokens")
        try FileManager.default.createDirectory(at: tokens, withIntermediateDirectories: false)
        chmod(tokens.path, 0o755)
        try FileTokenStore(baseDirectory: dir.url).save(token, account: "a@example.com")
        #expect(posixMode(tokens) == 0o700)
    }

    @Test func accountNamesCannotEscapeTheDirectory() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let store = FileTokenStore(baseDirectory: dir.url)
        for bad in ["../evil", "a/b", "", "..", ".hidden"] {
            #expect(throws: TokenStoreError.invalidAccount) { try store.save(token, account: bad) }
        }
    }
}
