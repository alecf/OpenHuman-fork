import Foundation
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct GmailImportantReasonTests {
    @Test func aSuppressedGmailImportantThreadSaysBothInItsLine() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "news", labels: ["INBOX", "IMPORTANT"], from: "news@letters.example"),
                      .fixture("m2", thread: "boss", minutes: 1, labels: ["INBOX", "IMPORTANT"], from: "boss@corp.example"),
                      .fixture("m3", thread: "gmail", minutes: 2, labels: ["INBOX", "IMPORTANT"], from: "x@a.example"),
                      .fixture("m4", thread: "plain", minutes: 3, labels: ["INBOX"], from: "news@letters.example")])
        try f.rule(.sender, "news@letters.example", .neverImportant)
        try f.rule(.sender, "boss@corp.example")

        let news = try f.store.importanceReason(f.ref("news"))
        #expect(news.gmailImportant && news.importance == .suppressed)
        #expect(news.line == "In Other: never important from news@letters.example; Gmail marks it important")
        let plain = try f.store.importanceReason(f.ref("plain"))
        #expect(!plain.gmailImportant && plain.line == "In Other: never important from news@letters.example")
        let boss = try f.store.importanceReason(f.ref("boss"))
        #expect(boss.gmailImportant && boss.line == "In Important: always important from boss@corp.example",
                "no disagreement, nothing added")
        #expect(try f.store.importanceReason(f.ref("gmail")).line == "In Important: Gmail marked it important")
    }

    @Test func withNoImportanceSplitTheLineSaysGmailMarksIt() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "gmail", labels: ["INBOX", "IMPORTANT"], from: "g@a.example")])
        try f.store.setImportanceSplit(account: f.account, nil)
        let why = try f.store.importanceReason(f.ref("gmail"))
        #expect(why.importance == .normal && why.gmailImportant)
        #expect(why.line.hasSuffix("; Gmail marks it important"), "\(why.line)")
    }

    @Test func aPinnedConversationStaysInOtherWhenGmailMarksANewMessageImportant() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "one", labels: ["INBOX", "IMPORTANT"], from: "ann@acme.example", subject: "Plan")])
        #expect(try f.importance("one") == .important && f.placement("one") == f.importanceSplit.name)
        try f.rule(.matcher, ThreadImportanceMatcher.value(for: GmailThreadID("one")), .neverImportant)
        #expect(try f.importance("one") == .suppressed && f.placement("one") == "Other")

        try f.upsert([.fixture("m2", thread: "one", minutes: 1, labels: ["INBOX", "IMPORTANT", "UNREAD"],
                               from: "ann@acme.example")])
        #expect(try f.importance("one") == .suppressed && f.placement("one") == "Other", "the pin outranks Gmail's new mark")
        #expect(try f.item("one").isImportant, "the row still carries Gmail's mark for the chip")
        #expect(try f.store.importanceReason(f.ref("one")).line
            == "In Other: moved to Other (this conversation only); Gmail marks it important")
        try fullRebuildChangesNothing(f.store)
    }

    @Test func outsideTheInboxTheLineStillNamesGmailsMark() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "done", labels: ["IMPORTANT"], from: "news@letters.example")])
        try f.rule(.sender, "news@letters.example", .neverImportant)
        let why = try f.store.importanceReason(f.ref("done"))
        #expect(!why.isInInbox && why.gmailImportant)
        #expect(why.line == "Not in the inbox: never important from news@letters.example; Gmail marks it important")
    }
}
