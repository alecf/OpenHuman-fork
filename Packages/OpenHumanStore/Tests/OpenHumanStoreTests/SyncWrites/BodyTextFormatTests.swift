import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct BodyTextFormatTests {
    private func body(_ text: String, _ format: BodyTextFormat) -> MessageBodyUpsert {
        MessageBodyUpsert(html: nil, text: text, hasCalendarInvite: false, decodeWarnings: [], searchText: text,
                          textFormat: format)
    }

    @Test func theTextPartsFormatRoundTrips() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([.fixture("f1", body: body("Soft \nbreak", .flowedDelSp)),
                                      .fixture("f2", body: body("Soft \nbreak", .flowed)),
                                      .fixture("f3", body: .fixture())], account: account, generation: 1)
        func format(_ id: String) throws -> BodyTextFormat? {
            let m = try #require(try store.message(account: account, gmailMessageID: GmailMessageID(id)))
            return try store.body(m.id)?.textFormat
        }
        #expect(try format("f1") == .flowedDelSp)
        #expect(try format("f2") == .flowed)
        #expect(try format("f3") == .fixed, "the default")
        let m1 = try #require(try store.message(account: account, gmailMessageID: GmailMessageID("f1")))
        #expect(try store.body(m1.id)?.text == "Soft \nbreak", "stored as sent")
        let raw = try store.read { try String.fetchOne($0, sql: "SELECT text_format FROM message_bodies WHERE mid = ?",
                                                       arguments: [m1.id.rawValue]) }
        #expect(raw == "flowed-delsp")
        _ = try store.upsertMessages([.fixture("f1", history: 2, body: body("Hard\nbreak", .fixed))], account: account,
                                     generation: 1)
        #expect(try format("f1") == .fixed)
    }

    @Test func anUnknownValueReadsFixed() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        _ = try store.upsertMessages([.fixture("odd", body: body("x", .flowed))], account: account, generation: 1)
        let m = try #require(try store.message(account: account, gmailMessageID: GmailMessageID("odd")))
        try store.write { db in try db.execute(sql: "UPDATE message_bodies SET text_format = 'later-format' WHERE mid = ?",
                                               arguments: [m.id.rawValue]) }
        #expect(try store.body(m.id)?.textFormat == .fixed)
    }
}
