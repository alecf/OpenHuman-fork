import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

@Suite struct FactoryAllowlistWiringTests {
    private static let me = "me@example.com"

    private func campaignDirectory(for account: String = me) throws -> TempDirectory {
        let dir = try TempDirectory()
        var allowlist = WG.allowlist
        allowlist.accountHash = WriteAllowlist.accountHash(account)
        try JSONEncoder().encode(allowlist).write(to: dir.url.appendingPathComponent(WriteAllowlist.fileName))
        chmod(dir.url.appendingPathComponent(WriteAllowlist.fileName).path, 0o600)
        return dir
    }

    private func wire() -> FakeHTTPTransport {
        let http = FakeHTTPTransport()
        http.on("POST", "/gmail/v1/users/me/threads/") { request in
            let id = request.url.pathComponents.dropLast().last ?? ""
            return FakeHTTPTransport.json(200, ["id": id, "messages": [["id": "m1", "threadId": id]]])
        }
        http.on("POST", "/upload/gmail/v1/users/me/messages/send") { _ in FakeHTTPTransport.json(200, ["id": "sent"]) }
        return http
    }

    private func factory(_ mode: SafeMode, _ http: FakeHTTPTransport, storeDirectory: URL?,
                         scopes: [String] = [GmailScope.modify]) -> DefaultGmailClientFactory {
        DefaultGmailClientFactory(safeMode: mode, apiTransport: http, config: GmailClientConfig(userAgent: "t"),
                                  clock: InstantClock(), storeDirectory: storeDirectory) { _ in
            (StaticTokenProvider(), scopes)
        }
    }

    private func blocked(_ path: String) -> GmailError { .transport(.blockedBySafeMode("POST \(path)")) }

    @Test func writeAllowlistWithTheStoreDirectoryGetsWriteGuardOverTheCampaign() async throws {
        let dir = try campaignDirectory()
        defer { dir.cleanup() }
        let http = wire()
        let api = try factory(.writeAllowlist, http, storeDirectory: dir.url).client(for: "Me@Example.com")
        _ = try await api.trashThread(id: "t1")
        await #expect(throws: blocked("/gmail/v1/users/me/threads/t9/trash")) { _ = try await api.trashThread(id: "t9") }
        await #expect(throws: blocked("/upload/gmail/v1/users/me/messages/send")) {
            _ = try await api.sendMessage(rawRFC822: Data("Subject: x\r\n\r\nx".utf8), threadID: "t1")
        }
        #expect(http.requests.filter { $0.method != "GET" }.map(\.url.path) == ["/gmail/v1/users/me/threads/t1/trash"])
    }

    @Test func everyMissingOrUnusableAllowlistFailsClosedToReadOnly() async throws {
        let mine = try campaignDirectory()
        let others = try campaignDirectory(for: "personal@example.com")
        let linked = try TempDirectory()
        defer { [mine, others, linked].forEach { $0.cleanup() } }
        try FileManager.default.createSymbolicLink(at: linked.url.appendingPathComponent(WriteAllowlist.fileName),
                                                   withDestinationURL: mine.url.appendingPathComponent(WriteAllowlist.fileName))
        let malformed = try TempDirectory()
        defer { malformed.cleanup() }
        try Data("{not json".utf8).write(to: malformed.url.appendingPathComponent(WriteAllowlist.fileName))

        let cases: [(String, URL?, [String])] = [
            ("no store directory", nil, [GmailScope.modify]),
            ("another account's campaign", others.url, [GmailScope.modify]),
            ("a symlink", linked.url, [GmailScope.modify]),
            ("a malformed file", malformed.url, [GmailScope.modify]),
            ("no gmail.modify", mine.url, [GmailScope.readonly]),
        ]
        for (name, directory, scopes) in cases {
            let http = wire()
            let api = try factory(.writeAllowlist, http, storeDirectory: directory, scopes: scopes).client(for: Self.me)
            await #expect(throws: blocked("/gmail/v1/users/me/threads/t1/trash"), "\(name)") {
                _ = try await api.trashThread(id: "t1")
            }
            #expect(http.requests.isEmpty, "\(name)")
        }
    }

    @Test func oneCampaignPerStoreDirectory() async throws {
        let dir = try campaignDirectory()
        defer { dir.cleanup() }
        let http = wire()
        let factory = factory(.writeAllowlist, http, storeDirectory: dir.url)
        _ = try await factory.client(for: Self.me).trashThread(id: "t1")
        let second = try factory.client(for: "second@example.com")
        await #expect(throws: blocked("/gmail/v1/users/me/threads/t1/trash")) { _ = try await second.trashThread(id: "t1") }
        #expect(http.requests.count == 1)
    }

    @Test func theCampaignSurvivesInvalidate() async throws {
        let dir = try campaignDirectory()
        defer { dir.cleanup() }
        let http = wire()
        let factory = factory(.writeAllowlist, http, storeDirectory: dir.url)
        _ = try await factory.client(for: Self.me).trashThread(id: "t1")
        try FileManager.default.removeItem(at: dir.url.appendingPathComponent(WriteAllowlist.fileName))
        factory.invalidate(accountEmail: Self.me)
        _ = try await factory.client(for: Self.me).untrashThread(id: "t1")
        #expect(http.requests.count == 2)
    }

    @Test func normalAndReadOnlyIgnoreTheStoreDirectory() async throws {
        let dir = try campaignDirectory()
        defer { dir.cleanup() }
        let normalWire = wire()
        _ = try await factory(.normal, normalWire, storeDirectory: dir.url).client(for: Self.me).trashThread(id: "t9")
        #expect(normalWire.requests.count == 1)
        let readOnlyWire = wire()
        let readOnly = try factory(.readOnly, readOnlyWire, storeDirectory: dir.url).client(for: Self.me)
        await #expect(throws: blocked("/gmail/v1/users/me/threads/t1/trash")) { _ = try await readOnly.trashThread(id: "t1") }
        #expect(readOnlyWire.requests.isEmpty)
    }
}
