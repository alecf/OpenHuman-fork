import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct DraftHoldsInboxTests {
    private func seeded() throws -> (MarkDoneFixture, ThreadRef) {
        let f = try MarkDoneFixture()
        _ = try f.store.upsertMessages([
            MessageUpsert.fixture("m1", thread: "t1", minutes: 1, labels: ["INBOX"]),
            MessageUpsert.fixture("d1", thread: "t1", minutes: 2, labels: ["DRAFT", "INBOX"], from: "me@example.com", fromName: nil),
        ], account: f.account, generation: 1)
        return (f, try f.ref("t1"))
    }

    @Test func archiveRemovesAThreadWhoseDraftCarriesInbox() throws {
        let (f, ref) = try seeded()
        #expect(try f.inbox() == ["t1"])
        _ = try f.store.apply(.archive([ref]), origin: .app)
        #expect(try f.inbox() == [])
        #expect(try f.store.label(account: f.account, key: "INBOX")?.totalThreads == 0)
        #expect(try f.labels("d1").effective.contains("INBOX") == false)
        let ops = try f.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pending_operations") ?? 0 }
        #expect(ops == 1)
    }

    @Test func aDraftAloneNeverPutsAThreadInTheInbox() throws {
        let f = try MarkDoneFixture()
        _ = try f.store.upsertMessages([
            MessageUpsert.fixture("m1", thread: "t1", minutes: 1, labels: ["SENT"], from: "me@example.com", fromName: nil),
            MessageUpsert.fixture("d1", thread: "t1", minutes: 2, labels: ["DRAFT", "INBOX"], from: "me@example.com", fromName: nil),
        ], account: f.account, generation: 1)
        #expect(try f.inbox() == [])
        #expect(try f.store.label(account: f.account, key: "INBOX")?.totalThreads == 0)
    }

    @Test func aRealInboxMessageStillKeepsTheThreadInTheInboxWhenTheDraftHasNoInbox() throws {
        let f = try MarkDoneFixture()
        _ = try f.store.upsertMessages([
            MessageUpsert.fixture("m1", thread: "t1", minutes: 1, labels: ["INBOX"]),
            MessageUpsert.fixture("d1", thread: "t1", minutes: 2, labels: ["DRAFT"], from: "me@example.com", fromName: nil),
        ], account: f.account, generation: 1)
        #expect(try f.inbox() == ["t1"])
    }
}
