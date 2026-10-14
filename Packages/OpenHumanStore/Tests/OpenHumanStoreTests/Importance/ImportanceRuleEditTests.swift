import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct ImportanceRuleEditTests {
    private func opCount(_ f: ImportanceFixture) throws -> Int {
        try f.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM pending_operations") ?? 0 }
    }

    @Test func alwaysImportantAppliesAtOnceToTheOpenThreadAndToFutureMailAndUndoes() throws {
        let f = try ImportanceFixture()
        try f.split("Pitches", "subject:pitch")
        try f.upsert([.fixture("m1", thread: "open", labels: ["INBOX", "UNREAD"], from: "dana@seed.example", subject: "Pitch")])
        #expect(try f.placement("open") == "Pitches")
        let receipt = try f.rule(.sender, "dana@seed.example")
        #expect(try f.placement("open") == "Important" && f.chips("open") == ["Pitches"] && opCount(f) == 0)
        try f.upsert([.fixture("m2", thread: "future", minutes: 5, labels: ["INBOX"], from: "dana@seed.example", subject: "Pitch 2")])
        #expect(try f.placement("future") == "Important" && f.importance("future") == .important)

        let redo = try #require(try f.store.undoImportanceRuleEdit(receipt))
        #expect(try f.store.importanceRules(account: f.account).isEmpty)
        #expect(try f.placement("open") == "Pitches" && f.placement("future") == "Pitches")
        #expect(redo.ruleIDs.isEmpty && redo.undo?.insert.map(\.id) == receipt.ruleIDs)
        let again = try #require(try f.store.undoImportanceRuleEdit(redo))
        #expect(try f.store.importanceRules(account: f.account).map(\.id) == receipt.ruleIDs)
        #expect(try f.placement("open") == "Important")
        #expect(again.undo == receipt.undo)
        try fullRebuildChangesNothing(f.store)
    }

    @Test func theOppositeEffectReplacesAndUndoRestoresIt() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX", "IMPORTANT"], from: "pat@x.example")])
        let always = try f.rule(.sender, "pat@x.example")
        let alwaysRule = try #require(try f.store.importanceRules(account: f.account).first)
        let same = try f.rule(.sender, "PAT@x.example")
        #expect(same == ImportanceRuleReceipt(ruleIDs: always.ruleIDs, undo: nil))
        #expect(try f.store.undoImportanceRuleEdit(same) == nil)

        let never = try f.rule(.sender, "pat@x.example", .neverImportant)
        let rules = try f.store.importanceRules(account: f.account)
        #expect(rules.count == 1 && rules.first?.definition.effect == .neverImportant)
        #expect(never.undo?.insert == [alwaysRule] && never.undo?.delete.map(\.id) == never.ruleIDs)
        #expect(try f.importance("t1") == .suppressed)
        _ = try #require(try f.store.undoImportanceRuleEdit(never))
        #expect(try f.store.importanceRules(account: f.account) == [alwaysRule] && f.importance("t1") == .important)
        try fullRebuildChangesNothing(f.store)
    }

    @Test func updateDeleteAndTheCompareAndSet() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "a", labels: ["INBOX"], from: "a@one.example"),
                      .fixture("m2", thread: "b", minutes: 1, labels: ["INBOX"], from: "b@two.example")])
        let added = try f.rule(.domain, "one.example")
        let id = try #require(added.ruleIDs.first)
        #expect(try f.importance("a") == .important && f.importance("b") == .normal)
        let edit = try f.store.updateImportanceRule(id, to: .init(accountID: f.account, kind: .domain, value: "two.example",
                                                                  effect: .important))
        #expect(try edit.ruleIDs == [id] && f.importance("a") == .normal && f.importance("b") == .important)
        let updated = try #require(try f.store.importanceRules(account: f.account).first)
        #expect(updated.id == id && updated.definition.value == "two.example" && updated.updatedAt > updated.createdAt)
        #expect(try f.store.undoImportanceRuleEdit(added) == nil)
        #expect(try f.store.importanceRules(account: f.account) == [updated])
        _ = try #require(try f.store.undoImportanceRuleEdit(edit))
        #expect(try f.store.importanceRules(account: f.account).map(\.definition.value) == ["one.example"])
        #expect(try f.importance("a") == .important)
        #expect(throws: StoreError.notFound("importance rule 999")) {
            try f.store.updateImportanceRule(ImportanceRuleID(rawValue: 999), to: .init(accountID: f.account, kind: .domain,
                                                                                       value: "x.example", effect: .important))
        }
        try f.rule(.sender, "b@two.example", .neverImportant)
        let all = try f.store.importanceRules(account: f.account)
        let deleted = try f.store.deleteImportanceRules(all.map(\.id) + [ImportanceRuleID(rawValue: 12345)])
        #expect(deleted.ruleIDs.isEmpty && Set(deleted.undo?.insert ?? []) == Set(all))
        #expect(try f.store.importanceRules(account: f.account).isEmpty && f.importance("a") == .normal)
        let restored = try #require(try f.store.undoImportanceRuleEdit(deleted))
        #expect(Set(try f.store.importanceRules(account: f.account)) == Set(all))
        #expect(try f.importance("a") == .important && f.importance("b") == .suppressed)
        _ = try #require(try f.store.undoImportanceRuleEdit(restored))
        #expect(try f.store.importanceRules(account: f.account).isEmpty)
        #expect(try f.store.deleteImportanceRules([ImportanceRuleID(rawValue: 777)]) == ImportanceRuleReceipt(ruleIDs: [], undo: nil))
        let fresh = try #require(try f.rule(.sender, "c@three.example").ruleIDs.first)
        #expect(all.allSatisfy { $0.id < fresh })
        try fullRebuildChangesNothing(f.store)
    }

    @Test func receiptsSurviveJSONAndAnUndoBlockedByANewerRuleChangesNothing() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX"], from: "q@x.example")])
        let deleted = try f.store.deleteImportanceRules(try f.rule(.sender, "q@x.example").ruleIDs)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let token = try decoder.decode(ImportanceRuleReceipt.self, from: encoder.encode(deleted))
        try f.rule(.sender, "q@x.example", .neverImportant)
        let before = try importanceDerivedState(f.store)
        #expect(try f.store.undoImportanceRuleEdit(token) == nil)
        #expect(try importanceDerivedState(f.store) == before)
        _ = try f.store.deleteImportanceRules(f.store.importanceRules(account: f.account).map(\.id))
        _ = try #require(try f.store.undoImportanceRuleEdit(token))
        #expect(try f.importance("t1") == .important)
    }

    @Test func everyAccountRulesApplyToEachAccount() throws {
        let f = try ImportanceFixture()
        let second = try f.store.addAccount(email: "two@example.com", displayName: nil, scopes: [])
        try f.store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: second, removeMissing: false)
        let g = ImportanceFixture(store: f.store, account: second)
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX"], from: "wife@home.example")])
        try g.upsert([.fixture("n1", thread: "u1", labels: ["INBOX"], from: "wife@home.example")])
        let receipt = try f.rule(.sender, "wife@home.example", global: true)
        #expect(try f.importance("t1") == .important && g.importance("u1") == .important)
        #expect(try f.store.importanceRules(account: second).map(\.id) == receipt.ruleIDs)
        #expect(try f.store.importanceRules(account: nil).first?.definition.accountID == nil)
        try g.rule(.sender, "wife@home.example", .neverImportant)
        #expect(try f.importance("t1") == .important && g.importance("u1") == .suppressed)
        _ = try #require(try f.store.undoImportanceRuleEdit(receipt))
        #expect(try f.importance("t1") == .normal)
        try fullRebuildChangesNothing(f.store)
    }
}

@Suite struct ImportanceExportImportTests {
    private func comparable(_ document: ImportanceRulesDocument) -> [String] {
        document.rules.map { r in
            ["\(r.account?.lowercased() ?? "*")", r.kind.rawValue, r.value, r.effect.rawValue, r.split ?? "-", r.source.rawValue,
             "\(Int64((r.createdAt.timeIntervalSince1970 * 1000).rounded()))"].joined(separator: "|")
        }
    }

    private func seeded() throws -> ImportanceFixture {
        let f = try ImportanceFixture(email: "owner@work.example")
        let pitches = try f.split("Pitches", "subject:pitch")
        try f.rule(.sender, "founder@startup.example")
        try f.rule(.domain, "noise.example", .neverImportant)
        try f.rule(.keyword, "contract", global: true)
        try f.rule(.sender, "pr@agency.example", .exemptFromSplit, split: pitches)
        try f.rule(.matcher, "keyword:invoice", source: .ai)
        return f
    }

    @Test func exportThenImportIntoAnEmptyStoreReproducesTheRules() throws {
        let a = try seeded()
        let document = try a.store.exportImportanceRules(account: a.account)
        #expect(document.version == 1 && document.rules.count == 5)
        #expect(document.rules.first { $0.effect == .exemptFromSplit }?.split == "Pitches")
        #expect(document.rules.first { $0.kind == .keyword }?.account == nil)
        #expect(document.rules.filter { $0.kind != .keyword }.allSatisfy { $0.account == "owner@work.example" })
        let json = try document.encodedJSON()
        let decoded = try ImportanceRulesDocument(json: json)
        #expect(comparable(decoded) == comparable(document))

        let b = try ImportanceFixture(email: "Owner@Work.example")
        try b.split("Pitches", "subject:pitch")
        let preview = try b.store.importImportanceRules(decoded, dryRun: true)
        #expect(preview == ImportanceImportSummary(added: 5, replaced: 0, unchanged: 0, skipped: 0, receipt: nil))
        #expect(try b.store.importanceRules(account: nil).isEmpty)
        let summary = try b.store.importImportanceRules(decoded, dryRun: false)
        #expect(summary.added == 5 && summary.receipt?.ruleIDs.count == 5)
        #expect(try comparable(b.store.exportImportanceRules(account: b.account)) == comparable(document))
        #expect(try b.store.importImportanceRules(decoded, dryRun: false)
                == ImportanceImportSummary(added: 0, replaced: 0, unchanged: 5, skipped: 0, receipt: nil))
        let importReceipt = try #require(summary.receipt)
        _ = try #require(try b.store.undoImportanceRuleEdit(importReceipt))
        #expect(try b.store.importanceRules(account: nil).isEmpty)
    }

    @Test func importAddsOrReplacesNeverDeletesAndSkipsWhatThisMacLacks() throws {
        let a = try seeded()
        let document = try a.store.exportImportanceRules(account: nil)
        let b = try ImportanceFixture(email: "owner@work.example")
        try b.upsert([.fixture("m1", thread: "noise", labels: ["INBOX"], from: "x@noise.example")])
        let keep = try b.rule(.sender, "keep@me.example")
        try b.rule(.domain, "noise.example")
        #expect(try b.importance("noise") == .important)
        var extra = document
        extra.rules.append(ExportedImportanceRule(account: "nobody@else.example", kind: .sender, value: "x@y.example",
                                                  effect: .important, createdAt: Date(timeIntervalSince1970: 1_790_000_000)))
        extra.rules.append(ExportedImportanceRule(account: "owner@work.example", kind: .domain, value: "not a domain",
                                                  effect: .important, createdAt: Date(timeIntervalSince1970: 1_790_000_000)))
        let summary = try b.store.importImportanceRules(extra, dryRun: false)
        #expect(summary.added == 3 && summary.replaced == 1 && summary.unchanged == 0 && summary.skipped == 3)
        #expect(try b.importance("noise") == .suppressed)
        let values = try b.store.importanceRules(account: b.account).map(\.definition.value)
        #expect(values.contains("keep@me.example") && values.count == 5)
        let importReceipt = try #require(summary.receipt)
        _ = try #require(try b.store.undoImportanceRuleEdit(importReceipt))
        #expect(try b.importance("noise") == .important)
        #expect(try b.store.importanceRules(account: b.account).map(\.definition.value).sorted()
                == ["keep@me.example", "noise.example"])
        #expect(keep.ruleIDs.count == 1)
        try fullRebuildChangesNothing(b.store)
    }

    @Test func otherVersionsAreRefused() throws {
        let f = try ImportanceFixture()
        let future = ImportanceRulesDocument(version: 2, rules: [])
        #expect(throws: StoreError.conflict("importance rules version 2 is not supported")) {
            try f.store.importImportanceRules(future, dryRun: true)
        }
        let json = Data(#"{"version": 2, "rules": []}"#.utf8)
        #expect(throws: StoreError.conflict("importance rules version 2 is not supported")) { try ImportanceRulesDocument(json: json) }
        #expect(throws: StoreError.conflict("the importance rules are not readable")) {
            try ImportanceRulesDocument(json: Data("{".utf8))
        }
    }
}

@Suite struct ImportanceReasonTests {
    @Test func theOneLineExplainsEachBasis() throws {
        let f = try ImportanceFixture()
        try f.split("Pitches", "subject:pitch")
        try f.upsert([.fixture("m1", thread: "kw", labels: ["INBOX"], from: "a@x.example", subject: "Contract"),
                      .fixture("m2", thread: "pitch", minutes: 1, labels: ["INBOX"], from: "b@x.example", subject: "pitch"),
                      .fixture("m3", thread: "plain", minutes: 2, labels: ["INBOX"], from: "c@x.example", subject: "hi"),
                      .fixture("m4", thread: "lbl", minutes: 3, labels: ["INBOX", "STARRED"], from: "d@x.example")])
        try f.rule(.keyword, "contract")
        try f.rule(.label, "STARRED", .neverImportant)
        #expect(try f.store.importanceReason(f.ref("kw")).line == "In Important: always important when it mentions \u{201C}contract\u{201D}")
        #expect(try f.store.importanceReason(f.ref("pitch")).line == "In Pitches: matches the Pitches split")
        #expect(try f.store.importanceReason(f.ref("plain")).line == "In Other: no rule or split matched")
        #expect(try f.store.importanceReason(f.ref("lbl")).line == "In Other: never important with the label STARRED")
        let pitch = try f.store.importanceReason(f.ref("pitch"))
        #expect(pitch.placementSplitID != nil && pitch.basis == ImportanceBasis.none && pitch.sender == "b@x.example")
        let important = try f.importanceSplit
        _ = try f.store.upsertSplit(account: f.account, id: important.id, name: important.name, ruleText: "from:c@x.example",
                                    position: nil, enabled: true)
        #expect(try f.store.importanceReason(f.ref("plain")).line == "In Important: matches the importance rule from:c@x.example")
        #expect(throws: StoreError.notFound("thread 999")) {
            try f.store.importanceReason(ThreadRef(accountID: f.account, rowID: ThreadRowID(rawValue: 999),
                                                   gmailThreadID: GmailThreadID("none")))
        }
    }

    @Test func aThreadOutsideTheInboxIsExplainedOnTheFly() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX"], from: "boss@corp.example"),
                      .fixture("m2", thread: "t1", minutes: 1, labels: ["INBOX"], from: "me@example.com"),
                      .fixture("m3", thread: "t1", minutes: 2, labels: ["INBOX"], from: "peer@corp.example")])
        try f.rule(.sender, "boss@corp.example")
        try f.upsert([.fixture("m1", thread: "t1", labels: [], from: "boss@corp.example", history: 2),
                      .fixture("m2", thread: "t1", minutes: 1, labels: [], from: "me@example.com", history: 2),
                      .fixture("m3", thread: "t1", minutes: 2, labels: [], from: "peer@corp.example", history: 2)])
        #expect(try f.importance("t1") == .normal && f.placement("t1") == "-" && f.threadRowReason("t1") == nil)
        let why = try f.store.importanceReason(f.ref("t1"))
        #expect(!why.isInInbox && why.importance == .important && why.placementName.isEmpty && why.chipSplitIDs.isEmpty)
        #expect(why.line == "Not in the inbox: always important from boss@corp.example")
        #expect(why.sender == "peer@corp.example")
    }
}

@Suite struct ImportanceObservationTests {
    @Test func theRuleListAndTheCountsEmitOnChange() async throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "t1", labels: ["INBOX", "UNREAD"], from: "a@x.example"),
                      .fixture("m2", thread: "t2", minutes: 1, labels: ["INBOX"], from: "b@x.example")])
        let rules = Collector(f.store.observeImportanceRules(account: f.account))
        let counts = Collector(f.store.observeImportanceCounts(account: f.account))
        defer { rules.stop(); counts.stop() }
        #expect(await rules.wait { $0.last == [] })
        #expect(await counts.wait { $0.last?.importantUnread == 0 && $0.last?.normal == 2 })
        let receipt = try f.rule(.sender, "a@x.example")
        #expect(await rules.wait { $0.last?.map(\.id) == receipt.ruleIDs })
        #expect(await counts.wait { $0.last == ImportanceCounts(accountID: f.account, important: 1, importantUnread: 1,
                                                                normal: 1, suppressed: 0) })
        _ = try f.store.undoImportanceRuleEdit(receipt)
        #expect(await rules.wait { $0.last == [] })
        #expect(await counts.wait { $0.last?.important == 0 })
        #expect(try f.store.threadPage(view: .system(f.account, .inbox), after: nil, limit: 10).items.allSatisfy { $0.importance == .normal })
    }
}
