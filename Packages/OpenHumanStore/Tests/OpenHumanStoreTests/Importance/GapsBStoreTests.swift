import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct GapsBStoreTests {
    @Test func aConversationRuleMovesOnlyThatConversationAndASenderRuleStillWins() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "one", labels: ["INBOX"], from: "ann@acme.example", subject: "Plan"),
                      .fixture("m2", thread: "two", minutes: 1, labels: ["INBOX"], from: "ann@acme.example", subject: "Lunch")])
        #expect(try f.importance("one") == .normal && f.importance("two") == .normal)

        let value = ThreadImportanceMatcher.value(for: GmailThreadID("one"))
        #expect(value == "thread:one")
        let moved = try f.rule(.matcher, value)
        #expect(try f.importance("one") == .important && f.importance("two") == .normal, "only that conversation")
        #expect(try f.store.importanceReason(f.ref("one")).reasonText == "moved to Important (this conversation only)")
        #expect(try f.members(of: f.importanceSplit.name).contains("one"))

        try f.upsert([.fixture("m3", thread: "one", minutes: 2, labels: ["INBOX"], from: "bob@else.example")])
        #expect(try f.importance("one") == .important)

        try f.rule(.domain, "acme.example", .neverImportant)
        #expect(try f.importance("one") == .important && f.importance("two") == .suppressed)
        let sender = try f.rule(.sender, "ann@acme.example", .neverImportant)
        #expect(try f.importance("one") == .suppressed)
        _ = try f.store.undoImportanceRuleEdit(sender)
        #expect(try f.importance("one") == .important)

        let other = try f.rule(.matcher, value, .neverImportant)
        #expect(try f.importance("one") == .suppressed)
        #expect(try f.store.importanceRules(account: f.account).filter { $0.definition.kind == .matcher }.count == 1)
        #expect(try f.store.importanceReason(f.ref("one")).reasonText == "moved to Other (this conversation only)")
        _ = try f.store.undoImportanceRuleEdit(other)
        #expect(try f.importance("one") == .important)
        try fullRebuildChangesNothing(f.store)

        _ = try #require(try f.store.undoImportanceRuleEdit(moved))
        #expect(try f.importance("one") == .suppressed)
        try fullRebuildChangesNothing(f.store)
    }

    @Test func theThreadMatcherIsBuiltInAndCannotBeReplacedOrRemoved() {
        #expect(ImportanceMatchers.registeredIDs.contains(ThreadImportanceMatcher.matcherID))
        ImportanceMatchers.unregister(id: ThreadImportanceMatcher.matcherID)
        #expect(ImportanceMatchers.matcher(id: "thread") is ThreadImportanceMatcher)
        ImportanceMatchers.register(FlagMatcher(id: "thread"))
        #expect(ImportanceMatchers.matcher(id: "thread") is ThreadImportanceMatcher)

        let facts = ImportanceFacts(accountID: AccountID(1), messages: [], threadID: GmailThreadID("t1"))
        #expect(ThreadImportanceMatcher().matches(facts, argument: "t1"))
        #expect(!ThreadImportanceMatcher().matches(facts, argument: "t2"))
        #expect(!ThreadImportanceMatcher().matches(ImportanceFacts(accountID: AccountID(1), messages: []), argument: "t1"))
        #expect(ThreadImportanceMatcher.thread(inValue: "thread:t1") == GmailThreadID("t1"))
        #expect(ThreadImportanceMatcher.thread(inValue: "keyword:t1") == nil)
        #expect(ThreadImportanceMatcher.thread(inValue: "thread") == nil)
    }

    @Test func alsoShowListsASplitsConversationsInOtherTooAndTurningItOffTakesThemOut() throws {
        let f = try ImportanceFixture()
        let pitches = try f.split("Pitches", "from:@vendor.example")
        try f.upsert([.fixture("m1", thread: "pitch", labels: ["INBOX"], from: "sales@vendor.example", subject: "Offer"),
                      .fixture("m2", thread: "plain", minutes: 1, labels: ["INBOX"], from: "ann@acme.example", subject: "Hi"),
                      .fixture("m3", thread: "vip", minutes: 2, labels: ["INBOX"], from: "boss@vendor.example", subject: "Deal")])
        try f.rule(.sender, "boss@vendor.example")
        #expect(try f.members(of: "Pitches") == ["pitch"])
        #expect(try f.members(of: "Other") == ["plain"])
        let off: [String] = try f.store.setting(.alsoShowSplitInInbox, scope: .account(f.account))
        #expect(off.isEmpty, "off by default")

        try f.store.setSetting(.alsoShowSplitInInbox, [pitches.rawValue], scope: .account(f.account))
        #expect(try f.members(of: "Pitches") == ["pitch"], "still in its split")
        #expect(try Set(f.members(of: "Other")) == ["pitch", "plain"])
        #expect(try !f.members(of: "Other").contains("vip"), "an important conversation is already in Important")
        #expect(try f.members(of: f.importanceSplit.name).contains("vip"))
        try fullRebuildChangesNothing(f.store)

        try f.upsert([.fixture("m4", thread: "pitch", minutes: 3, labels: ["INBOX"], from: "sales@vendor.example")])
        #expect(try f.members(of: "Pitches") == ["pitch"])
        #expect(try Set(f.members(of: "Other")) == ["pitch", "plain"])
        try fullRebuildChangesNothing(f.store)

        try f.store.setSetting(.alsoShowSplitInInbox, [], scope: .account(f.account))
        #expect(try f.members(of: "Other") == ["plain"])
        #expect(try f.members(of: "Pitches") == ["pitch"])
        try fullRebuildChangesNothing(f.store)
    }

    @Test func onlyIfNoReplyWritesTheConditionWithTheNewestMessageAndItLeavesWithTheSchedule() throws {
        let f = try MutationFixture()
        _ = try f.seed(1)
        let id = try f.syncedDraft(replyTo: "m1")
        let before = nine.addingTimeInterval(-3600)
        try f.store.write { db in try SendMutations.schedule(id, at: nine, onlyIfNoReply: true, now: epochMillis(before), in: db) }
        func headers() throws -> [String: String] { DraftRowCodec.decodeHeaders(try f.draftRow(id)["extra_headers_json"]) }
        #expect(try DraftRowCodec.header(OHGmailLabels.sendAtConditionHeader, in: headers()) == "no-reply m1")
        #expect(try DraftRowCodec.header(OHGmailLabels.sendAtHeader, in: headers()) == "20261012T0900Z", "the stamp as before")
        let draft = try #require(try f.store.draft(id))
        #expect(try f.store.scheduledSendHasReply(draft) == false)

        _ = try f.upsert([.fixture("m8", thread: "t1", minutes: 8, labels: ["INBOX"], from: "me@example.com")])
        #expect(try f.store.scheduledSendHasReply(draft) == false, "my own message is not a reply")
        _ = try f.upsert([.fixture("m9", thread: "t1", minutes: 9, labels: ["INBOX"], from: "bob@else.example")])
        #expect(try f.store.scheduledSendHasReply(draft) == true)

        try f.store.write { db in try SendMutations.schedule(id, at: ten, now: epochMillis(before), in: db) }
        #expect(try DraftRowCodec.header(OHGmailLabels.sendAtConditionHeader, in: headers()) == nil)
        let plain = try #require(try f.store.draft(id))
        #expect(try f.store.scheduledSendHasReply(plain) == false, "no condition: never cancelled")
        try f.store.write { db in try SendMutations.schedule(id, at: ten, onlyIfNoReply: true, now: epochMillis(before), in: db) }
        #expect(try DraftRowCodec.header(OHGmailLabels.sendAtConditionHeader, in: headers()) == "no-reply m9")
        try f.store.cancelScheduledSend(id)
        #expect(try DraftRowCodec.header(OHGmailLabels.sendAtConditionHeader, in: headers()) == nil)
        #expect(try DraftRowCodec.header(OHGmailLabels.sendAtHeader, in: headers()) == nil)

        let new = try f.newDraft()
        #expect(throws: StoreError.self) {
            try f.store.write { db in try SendMutations.schedule(new, at: nine, onlyIfNoReply: true, now: epochMillis(before), in: db) }
        }
        var odd = draft
        odd.extraHeaders[OHGmailLabels.sendAtConditionHeader] = "if-opened"
        #expect(try f.store.scheduledSendHasReply(odd) == nil)
    }
}
