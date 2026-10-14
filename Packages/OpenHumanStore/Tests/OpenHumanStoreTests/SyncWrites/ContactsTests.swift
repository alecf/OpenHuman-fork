import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct ContactsTests {
    private func contacts(_ f: AggregationFixture) throws -> [String: (sent: Int, received: Int, name: String?)] {
        try f.store.read { db in
            var out: [String: (Int, Int, String?)] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT email, name, sent_count, received_count FROM contacts") {
                out[r["email"]] = (r["sent_count"], r["received_count"], r["name"])
            }
            return out
        }
    }

    @Test func countersMoveOnlyOnFirstInsert() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("m1", from: "alice@example.com", fromName: "Alice", history: 1)])
        try f.upsert([.fixture("m1", labels: ["INBOX", "STARRED"], from: "alice@example.com", fromName: "Alice", history: 2)])
        try f.upsert([.fixture("m1", labels: [], from: "alice@example.com", fromName: "Alice", history: 1)])
        var c = try contacts(f)
        #expect(c["alice@example.com"]?.received == 1 && c["alice@example.com"]?.sent == 0)
        #expect(c["me@example.com"] == nil)

        try f.upsert([.fixture("s1", labels: ["SENT"], from: "me@example.com", fromName: "Me",
                               to: ["Bob@Example.com", "alice@example.com", "me@example.com"], history: 3)])
        c = try contacts(f)
        #expect(c["bob@example.com"]?.sent == 1 && c["alice@example.com"]?.sent == 1)
        #expect(c["alice@example.com"]?.received == 1)
    }

    @Test func draftsAndSpamDoNotCountAndLabelsOnlyRowsCountWhenHeadersArrive() throws {
        let f = try AggregationFixture()
        try f.upsert([.fixture("d1", labels: ["DRAFT"], from: "me@example.com", to: ["zed@example.com"]),
                      .fixture("x1", labels: ["SPAM"], from: "spammer@example.com")])
        #expect(try contacts(f).isEmpty)
        var bare = MessageUpsert.fixture("m9", from: "late@example.com", history: 1)
        bare.headers = nil
        try f.upsert([bare])
        #expect(try contacts(f).isEmpty)
        try f.upsert([.fixture("m9", from: "late@example.com", fromName: "Late Larry", history: 2)])
        try f.upsert([.fixture("m9", from: "late@example.com", fromName: "Late Larry", history: 3)])
        #expect(try contacts(f)["late@example.com"]?.received == 1)
        #expect(try contacts(f)["late@example.com"]?.name == "Late Larry")
    }
}
