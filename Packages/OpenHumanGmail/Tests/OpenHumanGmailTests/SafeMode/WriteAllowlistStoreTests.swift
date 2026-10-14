import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct WriteAllowlistStoreTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oh-allowlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func guarded(_ store: WriteAllowlistStore) -> (WriteGuard, ScriptedTransport) {
        let inner = ScriptedTransport { request in
            if request.method == "GET" {
                return jsonResponse(200, ["labels": [["id": "Label_T", "name": "OpenHuman/Test"],
                                                     ["id": "Label_U", "name": "Private project"]]])
            }
            if request.url.path().hasPrefix("/upload/") { return jsonResponse(200, ["id": "m5", "threadId": "m5"]) }
            return jsonResponse(200, ["id": "m5"])
        }
        return (WriteGuard(wrapping: inner, allowlist: store), inner)
    }

    @Test func survivesAReloadWithIdsOnlyAtMode0600() async throws {
        let dir = try directory()
        let store = try WriteAllowlistStore.open(storeDirectory: dir, accountEmail: "Me@Example.com")
        let file = dir.appendingPathComponent("safe-mode-allowlist.json")
        #expect(store.fileURL == file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let (first, _) = guarded(store)
        _ = try await first.send(WG.request("GET", WG.api + "labels"))
        _ = try await first.send(WG.insert())
        #expect(SecureFile.permissions(of: file) == 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        for absent in ["me@example.com", "Me@Example.com", "Private project", "Label_U", "OpenHuman test", "Synthetic"] {
            #expect(!text.contains(absent), "\(absent)")
        }
        let onDisk = try JSONDecoder().decode(WriteAllowlist.self, from: Data(text.utf8))
        #expect(onDisk.messageIDs == ["m5"] && onDisk.threadIDs == ["m5"] && onDisk.draftIDs.isEmpty)
        #expect(text.contains("OpenHuman/Test"))

        let reloaded = try WriteAllowlistStore.open(storeDirectory: dir, accountEmail: "me@example.com")
        #expect(await reloaded.snapshot == store.snapshot)
        let (second, inner) = guarded(reloaded)
        _ = try await second.send(WG.request("POST", WG.api + "threads/m5/trash"))
        _ = try await second.send(WG.insert())
        #expect(inner.requests.count == 2)
        let counts = await reloaded.counts
        #expect(counts.threads == 1 && counts.messages == 1 && counts.drafts == 0 && counts.labels == 1)

        try FileManager.default.removeItem(at: file)
        let fresh = try WriteAllowlistStore.open(storeDirectory: dir, accountEmail: "me@example.com")
        #expect(await fresh.snapshot.isEmpty)
        let (third, wire) = guarded(fresh)
        await #expect(throws: TransportError.blockedBySafeMode("POST /gmail/v1/users/me/threads/m5/trash")) {
            _ = try await third.send(WG.request("POST", WG.api + "threads/m5/trash"))
        }
        #expect(wire.requests.isEmpty)
    }

    @Test func anotherAccountsCampaignIsRefused() async throws {
        let dir = try directory()
        let store = try WriteAllowlistStore.open(storeDirectory: dir, accountEmail: "work@example.com")
        let (g, _) = guarded(store)
        _ = try await g.send(WG.request("GET", WG.api + "labels"))
        #expect(throws: WriteAllowlistError.otherAccount) {
            _ = try WriteAllowlistStore.open(storeDirectory: dir, accountEmail: "personal@example.com")
        }
    }

    @Test func badFilesAreRefused() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent(WriteAllowlist.fileName)
        let hash = WriteAllowlist.accountHash("me@example.com")
        func write(_ text: String) throws { try Data(text.utf8).write(to: file) }

        try write("not json")
        #expect(throws: WriteAllowlistError.malformed("invalid JSON")) {
            _ = try WriteAllowlistStore(fileURL: file, accountEmail: "me@example.com")
        }
        try write(#"{"version":1,"accountHash":"\#(hash)"}"#)
        #expect(throws: WriteAllowlistError.self) { _ = try WriteAllowlistStore(fileURL: file, accountEmail: "me@example.com") }
        try write(#"{"version":2,"accountHash":"\#(hash)","threadIDs":[],"messageIDs":[],"draftIDs":[],"labels":{}}"#)
        #expect(throws: WriteAllowlistError.unsupportedVersion(2)) {
            _ = try WriteAllowlistStore(fileURL: file, accountEmail: "me@example.com")
        }
        try write(#"{"version":1,"accountHash":"\#(hash)","threadIDs":["t 1"],"messageIDs":[],"draftIDs":[],"labels":{}}"#)
        #expect(throws: WriteAllowlistError.malformed("an id is not a Gmail id")) {
            _ = try WriteAllowlistStore(fileURL: file, accountEmail: "me@example.com")
        }
        try write(#"{"version":1,"accountHash":"\#(hash)","threadIDs":[],"messageIDs":[],"draftIDs":[],"labels":{"Label_U":"Work"}}"#)
        #expect(throws: WriteAllowlistError.malformed("a label is not an OpenHuman label")) {
            _ = try WriteAllowlistStore(fileURL: file, accountEmail: "me@example.com")
        }
        try FileManager.default.removeItem(at: file)
        let target = dir.appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: WriteAllowlistError.notARegularFile) {
            _ = try WriteAllowlistStore(fileURL: file, accountEmail: "me@example.com")
        }
    }

    @Test func aLooserModeIsTightenedOnLoad() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent(WriteAllowlist.fileName)
        let hash = WriteAllowlist.accountHash("me@example.com")
        try Data(#"{"version":1,"accountHash":"\#(hash)","threadIDs":["t1"],"messageIDs":["m1"],"draftIDs":[],"labels":{}}"#.utf8)
            .write(to: file)
        chmod(file.path, 0o644)
        let store = try WriteAllowlistStore(fileURL: file, accountEmail: "me@example.com")
        #expect(SecureFile.permissions(of: file) == 0o600)
        #expect(store.fileURL == file)
    }

    @Test func encodingIsSortedAndStable() throws {
        let a = WriteAllowlist(accountHash: "h", threadIDs: ["t2", "t1"], messageIDs: ["b", "a"], draftIDs: [],
                               labels: ["Label_T": "OpenHuman/Test"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(a), as: UTF8.self)
        #expect(text.contains(#""threadIDs":["t1","t2"]"#) && text.contains(#""messageIDs":["a","b"]"#))
        #expect(try JSONDecoder().decode(WriteAllowlist.self, from: Data(text.utf8)) == a)
        #expect(WriteAllowlist.accountHash("ME@example.com") == WriteAllowlist.accountHash("me@example.com"))
        #expect(WriteAllowlist.accountHash("me@example.com").count == 64)
    }
}
