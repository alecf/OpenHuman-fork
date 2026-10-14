import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct SearchTextNormalizerTests {
    @Test func nfcWhitespaceAndInvisibleCharacters() {
        let decomposed = "Cafe\u{0301}  \t na\u{00EF}ve\n\n\u{200B}hid\u{200D}den \u{202E}evil\u{202C} \u{FEFF}bom\u{00AD}x"
        #expect(SearchTextNormalizer.normalizeBody(decomposed) == "Caf\u{00E9} na\u{00EF}ve hidden evil bomx")
        #expect(SearchTextNormalizer.normalizeField("  Re:\u{00A0}\u{00A0}Plan \n") == "Re: Plan")
    }

    @Test func quotedLinesDropOnlyWhenEnoughTextRemains() {
        let quote = "> earlier message\n  > nested quote"
        let short = "Thanks!\n" + quote
        #expect(SearchTextNormalizer.normalizeBody(short) == "Thanks! > earlier message > nested quote")
        let long = String(repeating: "word ", count: 50) + "\n" + quote
        let out = SearchTextNormalizer.normalizeBody(long)
        #expect(!out.contains("earlier") && out.count >= 200)
        #expect(!SearchTextNormalizer.normalizeBody(String(repeating: "word ", count: 50) + "\n\u{200B}> q").contains("q"))
    }

    @Test func capsAt32KBOnACharacterBoundary() {
        let emoji = "👩‍👩‍👧"
        let text = String(repeating: "a", count: SearchTextNormalizer.maxBodyBytes - 2) + "é" + emoji
        let out = SearchTextNormalizer.normalizeBody(text)
        #expect(out.utf8.count <= SearchTextNormalizer.maxBodyBytes)
        #expect(out.hasSuffix("é") || out.hasSuffix("a"))
        #expect(SearchTextNormalizer.cap("aé", maxBytes: 2) == "a")
        #expect(SearchTextNormalizer.cap("", maxBytes: 0) == "")
    }
}

@Suite struct SearchDocumentWriteTests {
    private func doc(_ f: AggregationFixture, _ message: String) throws -> SearchDocuments.Document? {
        try f.store.read { db in
            try Row.fetchOne(db, sql: """
                SELECT d.* FROM message_search_docs d JOIN messages m USING (mid) WHERE m.gmail_message_id = ?
                """, arguments: [message]).map {
                SearchDocuments.Document(subject: $0["subject"], participants: $0["participants"], body: $0["body"],
                                         attachmentNames: $0["attachment_names"])
            }
        }
    }

    private func matches(_ f: AggregationFixture, _ query: String) throws -> [String] {
        try f.store.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.gmail_message_id FROM messages_fts JOIN messages m ON m.mid = messages_fts.rowid
                WHERE messages_fts MATCH ? ORDER BY m.gmail_message_id
                """, arguments: [query])
        }
    }

    @Test func metadataUpsertIndexesSubjectParticipantsAndSnippet() throws {
        let f = try AggregationFixture()
        var m = MessageUpsert.fixture("m1", subject: "Quarterly  invoice", snippet: "it&#39;s attached")
        m.headers?.cc = [EmailAddress(name: "Carol", email: "carol@example.com")]
        try f.upsert([m])
        let d = try #require(try doc(f, "m1"))
        #expect(d.subject == "Quarterly invoice" && d.body == "it's attached")
        #expect(d.participants == "Alice Smith <alice@example.com>\n<me@example.com>\nCarol <carol@example.com>")
        #expect(try matches(f, "\"oice\"") == ["m1"])
        #expect(try matches(f, "participants : \"carol\"") == ["m1"])
    }

    @Test func aStoredBodyReplacesTheSnippetAndLaterMetadataKeepsIt() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", snippet: "short preview", history: 1)])
        try f.store.storeBodies([(GmailMessageID("m1"), .fixture(text: "The full body mentions zeppelins"),
                                  [AttachmentUpsert(partID: "2", filename: "plan.pdf", mimeType: "application/pdf", size: 9,
                                                    isInline: false)])], account: f.account)
        #expect(try doc(f, "m1")?.body == "The full body mentions zeppelins")
        #expect(try doc(f, "m1")?.attachmentNames == "plan.pdf")
        try f.upsert([.fixture("m1", snippet: "changed preview", history: 2)])
        #expect(try doc(f, "m1")?.body == "The full body mentions zeppelins")
        #expect(try matches(f, "\"zeppelin\"") == ["m1"] && matches(f, "attachment_names : \"plan\"") == ["m1"])
    }

    @Test func unchangedUpsertsCauseNoDocumentWrites() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", history: 1)])
        try f.store.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER watch AFTER UPDATE ON message_search_docs BEGIN SELECT RAISE(ABORT, 'doc rewritten'); END")
        }
        try f.upsert([.fixture("m1", history: 2)])
        try f.store.write { db in try db.execute(sql: "DROP TRIGGER watch") }
    }

    @Test func deletingAMessageRemovesItFromTheIndex() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", subject: "Unique walrus")])
        #expect(try matches(f, "\"walrus\"") == ["m1"])
        _ = try f.store.deleteMessages([GmailMessageID("m1")], account: f.account, historyID: HistoryID(9))
        #expect(try matches(f, "\"walrus\"").isEmpty)
    }
}
