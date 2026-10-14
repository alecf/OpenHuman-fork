import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct WaitingViewTests {
    private func incoming(_ id: String, _ thread: String, minutes: Int) -> MessageUpsert {
        .fixture(id, thread: thread, minutes: minutes, labels: ["INBOX"], from: "alice@example.com", to: ["me@example.com"])
    }

    private func mine(_ id: String, _ thread: String, minutes: Int, to: [String] = ["alice@example.com"],
                      labels: [String] = ["SENT"]) -> MessageUpsert {
        .fixture(id, thread: thread, minutes: minutes, labels: labels, from: "me@example.com", fromName: "Me", to: to)
    }

    @Test func aConversationWaitsUntilTheReplyArrives() throws {
        let f = try MutationFixture()
        try f.upsert([incoming("m1", "t1", minutes: 0), mine("m2", "t1", minutes: 5)])
        #expect(try f.view(.waiting) == ["t1"])
        let since = try f.store.waitingSince(try f.ref("t1"))
        #expect(since == Date(timeIntervalSince1970: 1_790_000_000 + 5 * 60), "sorted by the account's own send time")
        try f.upsert([incoming("m3", "t1", minutes: 9)])
        #expect(try f.view(.waiting).isEmpty)
        #expect(try f.store.waitingSince(try f.ref("t1")) == nil)
        try f.upsert([mine("m4", "t1", minutes: 12)])
        #expect(try f.view(.waiting) == ["t1"])
    }

    @Test func oldestSendFirstAndTheCountFollowsTheRows() throws {
        let f = try MutationFixture()
        try f.upsert([mine("a", "newer", minutes: 30), mine("b", "older", minutes: 10)])
        #expect(try f.view(.waiting) == ["older", "newer"])
        let total = try f.raw("SELECT total_threads FROM labels WHERE account_id = ? AND key = 'oh:waiting'",
                              [f.account.rawValue]).first?["total_threads"] as Int?
        #expect(total == 2)
    }

    @Test func notesToSelfAutomatedAddressesAndMutedConversationsDoNotWait() throws {
        let f = try MutationFixture()
        try f.labels([("L_m", "OpenHuman/Muted")])
        try f.upsert([
            mine("self", "note", minutes: 1, to: ["me@example.com"]),
            mine("bot", "robot", minutes: 2, to: ["no-reply@example.com"]),
            mine("mute", "muted", minutes: 3, labels: ["SENT", "L_m"]),
            mine("ok", "real", minutes: 4, to: ["no-reply@example.com", "dana@example.com"]),
        ])
        #expect(try f.view(.waiting) == ["real"])
    }

    @Test func theWaitingAutoLabelSeedsTheView() throws {
        let f = try MutationFixture()
        try f.labels([("L_w", "OpenHuman/Waiting"), ("L_s", "[Superhuman]/AI/Waiting")])
        try f.upsert([mine("w1", "ours", minutes: 1, to: [], labels: ["SENT", "L_w"]),
                      mine("w2", "theirs", minutes: 2, to: [], labels: ["SENT", "L_s"]),
                      mine("w3", "none", minutes: 3, to: [])])
        #expect(Set(try f.view(.waiting)) == ["ours", "theirs"])
    }

    @Test func theOverrideWinsAndUndoes() throws {
        let f = try MutationFixture()
        try f.upsert([mine("m1", "t1", minutes: 1), mine("n1", "note", minutes: 2, to: ["me@example.com"])])
        let t1 = try f.ref("t1")
        #expect(try f.store.setWaitingOverride(t1, .notWaiting) == nil)
        #expect(try f.view(.waiting).isEmpty, "Not waiting takes it out at once")
        try f.upsert([mine("m2", "t1", minutes: 4)])
        #expect(try f.view(.waiting).isEmpty)
        #expect(try f.store.setWaitingOverride(t1, nil) == .notWaiting)
        #expect(try f.view(.waiting) == ["t1"])
        try f.store.setWaitingOverride(try f.ref("note"), .waiting)
        #expect(Set(try f.view(.waiting)) == ["t1", "note"])
        try f.upsert([.fixture("r1", thread: "note", minutes: 6, labels: ["INBOX"], from: "dana@example.com")])
        #expect(try f.view(.waiting) == ["t1"])
        let unknown = ThreadRef(accountID: f.account, rowID: ThreadRowID(rawValue: 999_999), gmailThreadID: GmailThreadID("x"))
        #expect(throws: StoreError.self) { try f.store.setWaitingOverride(unknown, .waiting) }
    }

    @Test func inWaitingSearchesTheView() throws {
        let f = try MutationFixture()
        try f.upsert([incoming("m1", "t1", minutes: 0), mine("m2", "t1", minutes: 5), incoming("m3", "t2", minutes: 6)])
        let query = try parseSearchQuery("in:waiting")
        #expect(query.canonicalText == "in:waiting")
        #expect(query.gmailQuery.isEmpty, "local only: never sent to Gmail")
        let hits = try f.store.search(query, accounts: [f.account], after: nil, limit: 50).hits
        #expect(hits.map(\.thread.ref.gmailThreadID.rawValue) == ["t1"])
    }
}
