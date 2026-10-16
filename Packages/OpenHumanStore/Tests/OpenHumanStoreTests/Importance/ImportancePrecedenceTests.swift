import Foundation
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct ImportancePrecedenceTests {
    @Test func withoutRulesTheImportanceSplitRuleIsTheDefaultSignal() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "gmail", labels: ["INBOX", "IMPORTANT", "UNREAD"], from: "x@a.example"),
                      .fixture("m2", thread: "plain", minutes: 1, labels: ["INBOX"], from: "y@b.example")])
        #expect(try f.importance("gmail") == .important && f.importance("plain") == .normal)
        #expect(try f.placement("gmail") == "Important" && f.placement("plain") == "Other")
        let why = try f.store.importanceReason(f.ref("gmail"))
        #expect(why.basis == .importanceSplit && why.rule == nil && why.importanceSplitRuleText == "is:important")
        #expect(why.line == "In Important: Gmail marked it important")
        #expect(try f.threadRowReason("gmail") == nil)
        let counts = try f.store.importanceCounts(account: f.account)
        #expect(counts == ImportanceCounts(accountID: f.account, important: 1, importantUnread: 1, normal: 1, suppressed: 0))
    }

    @Test func neverImportantBeatsImportantBeatsTheDefault() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "plain", labels: ["INBOX"], from: "alice@acme.example"),
                      .fixture("m2", thread: "gmail", minutes: 1, labels: ["INBOX", "IMPORTANT"], from: "alice@acme.example"),
                      .fixture("m3", thread: "colleague", minutes: 2, labels: ["INBOX"], from: "bob@acme.example")])
        let domain = try f.rule(.domain, "acme.example")
        #expect(try ["plain", "gmail", "colleague"].map(f.importance) == [.important, .important, .important])
        #expect(try f.members(of: "Important") == ["colleague", "gmail", "plain"])
        let never = try f.rule(.sender, "alice@acme.example", .neverImportant)
        #expect(try f.importance("plain") == .suppressed && f.importance("gmail") == .suppressed)
        #expect(try f.importance("colleague") == .important)
        #expect(try f.placement("gmail") == "Other" && f.placement("plain") == "Other")
        #expect(try f.threadRowReason("gmail") == never.ruleIDs.first?.rawValue)
        #expect(try f.threadRowReason("colleague") == domain.ruleIDs.first?.rawValue)
        #expect(try f.store.importanceReason(f.ref("gmail")).line
            == "In Other: never important from alice@acme.example; Gmail marks it important")
        #expect(try f.store.importanceReason(f.ref("plain")).line == "In Other: never important from alice@acme.example")
        try fullRebuildChangesNothing(f.store)
    }

    @Test func theTieBreakPicksTheReasonNeverTheImportance() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX"], from: "bob@corp.example", subject: "Budget review")])
        let keyword = try #require(try f.rule(.keyword, "budget").ruleIDs.first)
        let review = try #require(try f.rule(.keyword, "Review").ruleIDs.first)
        let domain = try #require(try f.rule(.domain, "corp.example").ruleIDs.first)
        let sender = try #require(try f.rule(.sender, "Bob@Corp.example").ruleIDs.first)
        #expect(try f.threadRowReason("t1") == sender.rawValue && f.importance("t1") == .important)
        _ = try f.store.deleteImportanceRules([sender])
        #expect(try f.threadRowReason("t1") == domain.rawValue)
        _ = try f.store.deleteImportanceRules([domain])
        #expect(try f.threadRowReason("t1") == keyword.rawValue && keyword < review)
        _ = try f.store.deleteImportanceRules([keyword])
        #expect(try f.threadRowReason("t1") == review.rawValue && f.importance("t1") == .important)
        try fullRebuildChangesNothing(f.store)
    }

    @Test func theMoreSpecificRuleWinsSenderOverDomain() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "alice", labels: ["INBOX"], from: "alice@example.com"),
                      .fixture("m2", thread: "bob", minutes: 1, labels: ["INBOX"], from: "bob@example.com")])
        let domain = try #require(try f.rule(.domain, "example.com", .neverImportant).ruleIDs.first)
        let sender = try #require(try f.rule(.sender, "alice@example.com").ruleIDs.first)
        #expect(try f.importance("alice") == .important && f.importance("bob") == .suppressed)
        #expect(try f.threadRowReason("alice") == sender.rawValue && f.threadRowReason("bob") == domain.rawValue)
        #expect(try f.store.importanceReason(f.ref("alice")).reasonText == "always important from alice@example.com")
        #expect(try f.store.importanceReason(f.ref("bob")).reasonText == "never important from example.com")
        #expect(try f.placement("alice") == "Important" && f.placement("bob") == "Other")
        try f.upsert([.fixture("m3", thread: "carol", minutes: 2, labels: ["INBOX"], from: "carol@acme.example")])
        try f.rule(.domain, "acme.example")
        let veto = try #require(try f.rule(.sender, "carol@acme.example", .neverImportant).ruleIDs.first)
        #expect(try f.importance("carol") == .suppressed && f.threadRowReason("carol") == veto.rawValue)
        try fullRebuildChangesNothing(f.store)
    }

    @Test func aKeywordRuleNeverOverridesASenderOrDomainRule() throws {
        let f = try ImportanceFixture()
        try f.store.upsertLabels([LabelUpsert(gmailLabelID: GmailLabelID("Label_1"), name: "Work", type: "user")],
                                 account: f.account, removeMissing: false)
        try f.upsert([.fixture("m1", thread: "s", labels: ["INBOX"], from: "a@s.example", subject: "Budget"),
                      .fixture("m2", thread: "d", minutes: 1, labels: ["INBOX"], from: "b@d.example", subject: "Budget"),
                      .fixture("m3", thread: "k", minutes: 2, labels: ["INBOX"], from: "c@k.example", subject: "Budget"),
                      .fixture("m4", thread: "l", minutes: 3, labels: ["INBOX", "Label_1"], from: "c@l.example", subject: "Hello")])
        try f.rule(.keyword, "budget", .neverImportant)
        try f.rule(.sender, "a@s.example")
        try f.rule(.domain, "d.example")
        #expect(try f.importance("s") == .important && f.importance("d") == .important && f.importance("k") == .suppressed)
        try f.rule(.keyword, "hello")
        try f.rule(.label, "Work", .neverImportant)
        #expect(try f.importance("l") == .suppressed)
        try fullRebuildChangesNothing(f.store)
    }

    @Test func neverBeatsAlwaysAtTheSameLevel() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "t", labels: ["INBOX"], from: "x@same.example")])
        try f.rule(.sender, "x@same.example")
        let never = try #require(try f.rule(.sender, "x@same.example", .neverImportant, global: true).ruleIDs.first)
        #expect(try f.store.importanceRules(account: f.account).count == 2)
        #expect(try f.importance("t") == .suppressed && f.threadRowReason("t") == never.rawValue)
        #expect(try f.store.importanceReason(f.ref("t")).reasonText == "never important from x@same.example")
        try fullRebuildChangesNothing(f.store)
    }

    @Test func aUserRuleBeatsAnAIRuleWhateverTheirSpecificity() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "t", labels: ["INBOX"], from: "p@q.example", subject: "Budget"),
                      .fixture("m2", thread: "u", minutes: 1, labels: ["INBOX"], from: "p@r.example")])
        try f.rule(.sender, "p@q.example", .neverImportant, source: .ai)
        let user = try #require(try f.rule(.domain, "q.example").ruleIDs.first)
        #expect(try f.importance("t") == .important && f.threadRowReason("t") == user.rawValue)
        try f.rule(.sender, "p@r.example", source: .ai)
        let userDomain = try #require(try f.rule(.domain, "r.example", .neverImportant).ruleIDs.first)
        #expect(try f.importance("u") == .suppressed && f.threadRowReason("u") == userDomain.rawValue)
        try f.rule(.sender, "p@q.example", source: .user)
        #expect(try f.importance("t") == .important)
        #expect(try f.store.importanceReason(f.ref("t")).reasonText == "always important from p@q.example")
        try fullRebuildChangesNothing(f.store)
    }

    @Test func specificityAmongAIRulesAndTheReasonNamesTheDecidingRule() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "t", labels: ["INBOX"], from: "p@q.example")])
        try f.rule(.domain, "q.example", .neverImportant, source: .ai)
        try f.rule(.sender, "p@q.example", source: .ai)
        let why = try f.store.importanceReason(f.ref("t"))
        #expect(try f.importance("t") == .important && why.basis == .rule)
        #expect(why.reasonText == "always important from p@q.example (suggested by AI)")
        #expect(why.line == "In Important: always important from p@q.example (suggested by AI)")
        try fullRebuildChangesNothing(f.store)
    }

    @Test func theAuthorsRulesBeatAIRules() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "both", labels: ["INBOX"], from: "ai@x.example"),
                      .fixture("m2", thread: "aiOnly", minutes: 1, labels: ["INBOX"], from: "z@y.example"),
                      .fixture("m3", thread: "gmail", minutes: 2, labels: ["INBOX", "IMPORTANT"], from: "n@w.example"),
                      .fixture("m4", thread: "veto", minutes: 3, labels: ["INBOX"], from: "v@v.example")])
        try f.rule(.sender, "ai@x.example", .neverImportant, source: .ai)
        let user = try f.rule(.domain, "x.example")
        #expect(try f.importance("both") == .important && f.threadRowReason("both") == user.ruleIDs.first?.rawValue)
        try f.rule(.sender, "z@y.example", source: .ai)
        #expect(try f.importance("aiOnly") == .important)
        #expect(try f.store.importanceReason(f.ref("aiOnly")).reasonText == "always important from z@y.example (suggested by AI)")
        try f.rule(.sender, "n@w.example", .neverImportant, source: .ai)
        #expect(try f.importance("gmail") == .suppressed && f.placement("gmail") == "Other")
        try f.rule(.sender, "v@v.example", .neverImportant)
        try f.rule(.sender, "v@v.example", source: .ai)
        #expect(try f.importance("veto") == .suppressed)
        #expect(try f.store.importanceRules(account: f.account).count == 6)
        try fullRebuildChangesNothing(f.store)
    }

    @Test func withoutAnImportanceSplitThereIsNoDefaultAndImportantMailStaysInOther() throws {
        let f = try ImportanceFixture()
        let pitches = try f.split("Pitches", "subject:pitch")
        try f.upsert([.fixture("m1", thread: "gmail", labels: ["INBOX", "IMPORTANT"], from: "g@a.example", subject: "Pitch"),
                      .fixture("m2", thread: "wanted", minutes: 1, labels: ["INBOX"], from: "w@b.example", subject: "A pitch"),
                      .fixture("m3", thread: "pitch", minutes: 2, labels: ["INBOX"], from: "p@c.example", subject: "pitch deck")])
        try f.rule(.sender, "w@b.example")
        let important = try f.importanceSplit
        try f.store.setImportanceSplit(account: f.account, nil)
        #expect(try f.store.splits(account: f.account).allSatisfy { !$0.isImportanceSplit })
        #expect(try f.importance("gmail") == .normal && f.placement("gmail") == "Important" && f.chips("gmail") == ["Pitches"])
        #expect(try f.importance("wanted") == .important && f.placement("wanted") == "Other" && f.chips("wanted") == ["Pitches"])
        #expect(try f.placement("pitch") == "Pitches")
        try fullRebuildChangesNothing(f.store)
        try f.store.setImportanceSplit(account: f.account, pitches)
        #expect(try f.importance("pitch") == .important && f.placement("pitch") == "Pitches" && f.placement("wanted") == "Pitches")
        try f.store.setImportanceSplit(account: f.account, important.id)
        #expect(try f.importance("gmail") == .important && f.placement("gmail") == "Important" && f.chips("gmail") == ["Pitches"])
        #expect(throws: StoreError.notFound("split nope")) { try f.store.setImportanceSplit(account: f.account, SplitID("nope")) }
        try fullRebuildChangesNothing(f.store)
    }
}

@Suite struct ImportancePitchTests {
    @Test func aPitchFromAnImportantSenderStaysInPrimaryWithTheChip() throws {
        let f = try ImportanceFixture()
        let pitches = try f.split("Pitches", "subject:pitch OR from:@startup.example")
        try f.upsert([.fixture("m1", thread: "wanted", labels: ["INBOX", "UNREAD"], from: "founder@startup.example",
                               subject: "Pitch: our seed round"),
                      .fixture("m2", thread: "other", minutes: 1, labels: ["INBOX", "UNREAD"], from: "spam@startup.example",
                               subject: "Pitch deck"),
                      .fixture("m3", thread: "gmail", minutes: 2, labels: ["INBOX", "IMPORTANT"], from: "vc@fund.example",
                               subject: "A pitch Gmail liked")])
        #expect(try f.members(of: "Pitches") == ["other", "wanted"])
        #expect(try f.placement("gmail") == "Important" && f.chips("gmail") == ["Pitches"])
        let before = try f.store.importanceCounts(account: f.account)

        try f.rule(.sender, "founder@startup.example")
        #expect(try f.importance("wanted") == .important && f.placement("wanted") == "Important")
        #expect(try f.chips("wanted") == ["Pitches"])
        let pitchesRow = try #require(try f.store.splits(account: f.account).first { $0.id == pitches })
        #expect(try f.item("wanted").splitChipIDs == [pitchesRow.labelRowID])
        #expect(try f.members(of: "Pitches") == ["other"] && f.importance("other") == .normal && f.chips("other").isEmpty)
        #expect(try f.members(of: "Important") == ["gmail", "wanted"])
        #expect(try f.store.importanceCounts(account: f.account).importantUnread == before.importantUnread + 1)
        #expect(try f.store.importanceReason(f.ref("wanted")).line == "In Important: always important from founder@startup.example")
        try fullRebuildChangesNothing(f.store)
    }

    @Test func notAPitchRemovesTheSenderFromTheSplitOnly() throws {
        let f = try ImportanceFixture()
        let pitches = try f.split("Pitches", "subject:pitch")
        try f.split("Newsletters", "list:news")
        var news = MessageUpsert.fixture("m2", thread: "news", minutes: 1, labels: ["INBOX"], from: "pr@agency.example",
                                         subject: "Pitch digest")
        news.headers?.listID = "<news.agency.example>"
        try f.upsert([.fixture("m1", thread: "agency", labels: ["INBOX"], from: "pr@agency.example", subject: "A pitch"),
                      news,
                      .fixture("m3", thread: "gmail", minutes: 2, labels: ["INBOX", "IMPORTANT"], from: "pr@agency.example",
                               subject: "Pitch")])
        #expect(try f.placement("agency") == "Pitches" && f.placement("news") == "Pitches" && f.chips("news") == ["Newsletters"])
        let notPitch = try f.rule(.sender, "pr@agency.example", .exemptFromSplit, split: pitches)
        #expect(try f.placement("agency") == "Other" && f.chips("agency").isEmpty)
        #expect(try f.placement("news") == "Newsletters" && f.chips("news").isEmpty && f.importance("news") == .normal)
        #expect(try f.placement("gmail") == "Important" && f.chips("gmail").isEmpty && f.importance("gmail") == .important)
        let why = try f.store.importanceReason(f.ref("agency"))
        #expect(why.exemptions.map(\.id) == notPitch.ruleIDs && why.line == "In Other: no rule or split matched; removed from a split by your rule")
        try f.rule(.sender, "pr@agency.example", .exemptFromSplit)
        #expect(try f.placement("news") == "Other")
        #expect(throws: StoreError.conflict("the importance split cannot be exempted from; use never important")) {
            try f.rule(.sender, "pr@agency.example", .exemptFromSplit, split: f.importanceSplit.id)
        }
        try fullRebuildChangesNothing(f.store)
        try f.store.deleteSplit(pitches)
        #expect(try f.store.importanceRules(account: f.account).filter { $0.definition.splitID != nil }.isEmpty)
        try fullRebuildChangesNothing(f.store)
    }

    @Test func aSuppressedThreadNeverLandsInTheImportanceSplit() throws {
        let f = try ImportanceFixture()
        try f.split("Pitches", "subject:pitch")
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX", "IMPORTANT"], from: "noisy@x.example", subject: "Pitch")])
        #expect(try f.placement("t1") == "Important" && f.chips("t1") == ["Pitches"])
        try f.rule(.sender, "noisy@x.example", .neverImportant)
        #expect(try f.placement("t1") == "Pitches" && f.chips("t1").isEmpty && f.importance("t1") == .suppressed)
        #expect(try f.store.importanceCounts(account: f.account).suppressed == 1)
    }
}

extension ImportanceFixture {
    func threadRowReason(_ thread: String) throws -> Int64? {
        let t = try ref(thread).rowID.rawValue
        return try store.read { db in
            try Int64.fetchOne(db, sql: "SELECT importance_reason_rid FROM threads WHERE tid = ?", arguments: [t])
        }
    }
}
