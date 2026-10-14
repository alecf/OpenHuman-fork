import Foundation
import GRDB
import OpenHumanCore
import Testing
@testable import OpenHumanStore

@Suite struct SnippetV2Tests {
    private func fileStore() throws -> (MailStore, URL) {
        let (store, dir) = try openTemp()
        return (store, dir)
    }

    private func snippet(_ id: String, files: [SnippetAttachment] = [], to: [EmailAddress] = []) -> SnippetItem {
        SnippetItem(id: id, name: "Snippet \(id)", bodyHTML: "<p>Body</p>", variables: [], useCount: 0, to: to, attachments: files)
    }

    @Test func sha256MatchesTheStandardVectors() {
        #expect(SHA256Digest.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256Digest.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256Digest.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(SHA256Digest.hex(Data(repeating: 0x61, count: 1_000_000))
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func recipientsRoundTripAndV1RowsReadEmpty() throws {
        let f = try MutationFixture()
        let to = [EmailAddress(name: "Dana Example", email: "dana@example.com")]
        let cc = [EmailAddress(email: "team@example.com")]
        try f.store.upsertSnippet(SnippetItem(id: "r1", name: "Intro", bodyHTML: "<p>Hi</p>", variables: [], useCount: 0,
                                              to: to, cc: cc, bcc: []))
        try f.store.upsertSnippet(SnippetItem(id: "plain", name: "Plain", bodyHTML: "<p>x</p>", variables: [], useCount: 0))
        let read = try f.store.snippets(account: nil)
        let intro = try #require(read.first { $0.id == "r1" })
        #expect(intro.to == to && intro.cc == cc && intro.bcc.isEmpty)
        let row = try #require(try f.raw("SELECT to_json, cc_json, bcc_json FROM snippets WHERE snippet_id = 'r1'").first)
        #expect(row["to_json"] as String == #"[{"e":"dana@example.com","n":"Dana Example"}]"#)
        #expect(row["bcc_json"] as String == "[]")
        let plain = try #require(read.first { $0.id == "plain" })
        #expect(plain.to.isEmpty && plain.attachments.isEmpty)
        var edited = intro
        edited.to = []
        try f.store.upsertSnippet(edited)
        #expect(try f.store.snippets(account: nil).first { $0.id == "r1" }?.to.isEmpty == true)
    }

    @Test func aStoredFileIsNamedByItsHashAndReadBack() throws {
        let (store, dir) = try fileStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("synthetic attachment".utf8)
        let stored = try store.storeSnippetAttachment(data: bytes, filename: "notes.txt", mimeType: "text/plain")
        #expect(stored.contentHash == SHA256Digest.hex(bytes) && stored.size == bytes.count && stored.filename == "notes.txt")
        let url = try #require(store.location.snippetFileURL(stored))
        #expect(url.path.hasSuffix("Snippets/\(stored.contentHash)/notes.txt"))
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try store.storeSnippetAttachment(data: bytes, filename: "notes.txt", mimeType: "text/plain") == stored)
        try store.upsertSnippet(snippet("f1", files: [stored]))
        #expect(try store.snippets(account: nil).first?.attachments == [stored])
        let odd = try store.storeSnippetAttachment(data: bytes, filename: "../../escape.txt", mimeType: "")
        #expect(!odd.filename.contains("/") && odd.mimeType == "application/octet-stream")
    }

    @Test func aFileGoesWithTheLastSnippetThatUsedIt() throws {
        let (store, dir) = try fileStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = try store.storeSnippetAttachment(data: Data("shared".utf8), filename: "a.txt", mimeType: "text/plain")
        let own = try store.storeSnippetAttachment(data: Data("own".utf8), filename: "b.txt", mimeType: "text/plain")
        try store.upsertSnippet(snippet("s1", files: [shared, own]))
        try store.upsertSnippet(snippet("s2", files: [shared]))
        let sharedURL = try #require(store.location.snippetFileURL(shared))
        let ownURL = try #require(store.location.snippetFileURL(own))

        try store.upsertSnippet(snippet("s1", files: [shared]))
        #expect(!FileManager.default.fileExists(atPath: ownURL.path))
        #expect(!FileManager.default.fileExists(atPath: ownURL.deletingLastPathComponent().path), "its empty hash folder too")
        #expect(FileManager.default.fileExists(atPath: sharedURL.path))
        try store.deleteSnippet(id: "s1")
        #expect(FileManager.default.fileExists(atPath: sharedURL.path))
        try store.deleteSnippet(id: "s2")
        #expect(!FileManager.default.fileExists(atPath: sharedURL.path))
    }

    @Test func anUnsavedFileIsSweptOnlyAfterTheGracePeriod() throws {
        let (store, dir) = try fileStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let orphan = try store.storeSnippetAttachment(data: Data("never saved".utf8), filename: "o.txt", mimeType: "text/plain")
        let url = try #require(store.location.snippetFileURL(orphan))
        store.removeUnreferencedSnippetFiles([])
        #expect(FileManager.default.fileExists(atPath: url.path), "an editor may still save it")
        store.removeUnreferencedSnippetFiles([], now: Date().addingTimeInterval(SnippetFiles.orphanGrace + 60))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func capsAndMalformedReferencesAreRefused() throws {
        let (store, dir) = try fileStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = Data(count: SnippetAttachmentLimits.maxFileBytes + 1)
        #expect(throws: StoreError.limitExceeded("snippet attachment size")) {
            try store.storeSnippetAttachment(data: big, filename: "big.bin", mimeType: "application/octet-stream")
        }
        let ghost = SnippetAttachment(contentHash: String(repeating: "a", count: 64), filename: "ghost.txt", mimeType: "text/plain", size: 1)
        #expect(throws: StoreError.notFound("snippet attachment file")) { try store.upsertSnippet(snippet("g", files: [ghost])) }
        let bad = SnippetAttachment(contentHash: "../x", filename: "x.txt", mimeType: "text/plain", size: 1)
        #expect(throws: StoreError.self) { try store.upsertSnippet(snippet("b", files: [bad])) }
        #expect(store.location.snippetFileURL(SnippetAttachment(contentHash: String(repeating: "b", count: 64),
                                                                filename: "../up.txt", mimeType: "", size: 0)) == nil)
        let nineMB = 9 * 1024 * 1024
        let heavy = (0..<3).map { SnippetAttachment(contentHash: String(repeating: "c", count: 63) + "\($0)", filename: "h\($0).bin",
                                                    mimeType: "", size: nineMB) }
        #expect(throws: StoreError.limitExceeded("snippet attachments size")) { try SnippetFiles.validate(heavy) }
        let many = (0..<11).map { SnippetAttachment(contentHash: String(repeating: "d", count: 63) + "\($0 % 10)",
                                                    filename: "m\($0).txt", mimeType: "", size: 1) }
        #expect(throws: StoreError.limitExceeded("snippet attachments")) { try SnippetFiles.validate(many) }
        #expect(try store.snippets(account: nil).isEmpty, "nothing was saved")
    }

    @Test func aReadOnlyStoreRefusesFiles() throws {
        let (store, dir) = try fileStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.close()
        let (reader, _) = try openTemp(readOnly: true, dir: dir)
        #expect(throws: StoreError.readOnly) {
            try reader.storeSnippetAttachment(data: Data("x".utf8), filename: "x.txt", mimeType: "text/plain")
        }
        #expect(!FileManager.default.fileExists(atPath: reader.location.snippetFilesDirectory.path))
    }
}
