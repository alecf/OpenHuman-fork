import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite(.serialized) struct ImportanceConvergenceTests {
    @Test(arguments: (1...6).map { UInt64($0) }) func fastReevaluationEqualsAFullRebuild(seed: UInt64) throws {
        let f = try ImportanceFixture()
        let second = try f.store.addAccount(email: "two@example.com", displayName: nil, scopes: [])
        try f.store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: second, removeMissing: false)
        let g = ImportanceFixture(store: f.store, account: second)
        for fixture in [f, g] {
            try fixture.store.upsertLabels([LabelUpsert(gmailLabelID: GmailLabelID("Label_1"), name: "Work", type: "user"),
                                            LabelUpsert(gmailLabelID: GmailLabelID("Label_2"), name: "Clients", type: "user")],
                                           account: fixture.account, removeMissing: false)
        }
        var splitIDs = [try f.importanceSplit.id]
        splitIDs.append(try f.split("Pitches", "subject:pitch"))
        splitIDs.append(try f.split("News", "from:@news.example OR list:news"))
        splitIDs.append(try f.split("Work", "label:Work"))
        try g.split("Pitches", "subject:pitch")

        let matcherID = uniqueMatcherID("conv")
        defer { ImportanceMatchers.unregister(id: matcherID) }
        var rng = ImportanceRNG(seed: seed)
        let senders = ["a@acme.example", "b@mail.acme.example", "c@news.example", "d@x.org", "me@example.com", "e@startup.example"]
        let subjects = ["Pitch deck", "Contract review", "hello", "News digest", "Invoice 7", "urgent pitch", "Ünïcode note"]
        let labelPools: [[String]] = [["INBOX"], ["INBOX", "UNREAD"], ["INBOX", "IMPORTANT"], ["INBOX", "Label_1"],
                                      ["INBOX", "IMPORTANT", "UNREAD", "Label_2"], [], ["TRASH"], ["INBOX", "SPAM"]]
        let bodies = ["please review the contract", "a short pitch", "nothing here", "URGENT: call me", "invoice attached"]
        var history: [String: UInt64] = [:]
        var threadOf: [String: String] = [:]
        var receipts: [ImportanceRuleReceipt] = []
        var seen = Set<String>()

        func definition(_ fixture: ImportanceFixture) -> ImportanceRuleDefinition {
            let kind = rng.pick(ImportanceMatchKind.allCases)
            let value: String = switch kind {
            case .sender: rng.pick(senders)
            case .domain: rng.pick(["acme.example", "news.example", "x.org", "startup.example", "example.com"])
            case .keyword: rng.pick(["pitch", "contract", "invoice", "urgent", "digest", "ünïcode"])
            case .label: rng.pick(["Work", "Label_2", "IMPORTANT", "clients", "nope"])
            case .matcher: rng.pick([matcherID, "\(matcherID):pitch", "keyword:contract", "unknown.matcher"])
            }
            let effect = rng.pick(ImportanceEffect.allCases)
            let split: SplitID? = fixture.account == f.account && effect == .exemptFromSplit && rng.next() % 2 == 0
                ? rng.pick(splitIDs) : nil
            let global = split == nil && rng.next() % 5 == 0
            return ImportanceRuleDefinition(accountID: global ? nil : fixture.account, kind: kind, value: value, effect: effect,
                                            splitID: split, source: rng.next() % 4 == 0 ? .ai : .user)
        }

        for step in 0..<200 {
            let fixture = rng.next() % 4 == 0 ? g : f
            switch rng.next() % 10 {
            case 0, 1:
                if let receipt = try? fixture.store.addImportanceRule(definition(fixture)) { receipts.append(receipt) }
            case 2:
                let rules = try f.store.importanceRules(account: nil)
                guard !rules.isEmpty else { continue }
                receipts.append(try f.store.deleteImportanceRules([rng.pick(rules).id]))
            case 3:
                let rules = try fixture.store.importanceRules(account: fixture.account)
                guard !rules.isEmpty else { continue }
                if let receipt = try? fixture.store.updateImportanceRule(rng.pick(rules).id, to: definition(fixture)) {
                    receipts.append(receipt)
                }
            case 4:
                guard !receipts.isEmpty else { continue }
                if let redo = try f.store.undoImportanceRuleEdit(rng.pick(receipts)) { receipts.append(redo) }
            case 5:
                let mid = "\(fixture.account.rawValue)-m\(rng.next() % 30)"
                let h = (history[mid] ?? 0) + 1
                history[mid] = h
                let thread = threadOf[mid] ?? "\(fixture.account.rawValue)-t\(rng.next() % 12)"
                threadOf[mid] = thread
                try fixture.upsert([.fixture(mid, thread: thread, minutes: Int(rng.next() % 500), labels: rng.pick(labelPools),
                                             from: rng.pick(senders), subject: rng.pick(subjects), snippet: rng.pick(bodies),
                                             history: h)])
            case 6:
                guard let mid = history.keys.sorted().filter({ $0.hasPrefix("\(fixture.account.rawValue)-") }).randomElement(using: &rng)
                else { continue }
                let text = rng.pick(bodies)
                try fixture.store.storeBodies([(GmailMessageID(mid), MessageBodyUpsert(text: text, hasCalendarInvite: false,
                                                                                       decodeWarnings: [], searchText: text), [])],
                                              account: fixture.account)
            case 7:
                guard let mid = history.keys.sorted().filter({ $0.hasPrefix("\(fixture.account.rawValue)-") }).randomElement(using: &rng),
                      let h = history[mid] else { continue }
                history[mid] = h + 1
                let label = rng.pick(["INBOX", "IMPORTANT", "UNREAD", "Label_1"])
                let add = rng.next() % 2 == 0
                _ = try fixture.store.applyLabelDeltas([LabelDelta(gmailMessageID: GmailMessageID(mid), historyID: HistoryID(h + 1),
                                                                   added: add ? [GmailLabelID(label)] : [],
                                                                   removed: add ? [] : [GmailLabelID(label)])],
                                                       account: fixture.account)
            case 8:
                let split = rng.pick(splitIDs)
                switch rng.next() % 4 {
                case 0:
                    let item = try #require(try f.store.splits(account: f.account).first { $0.id == split })
                    _ = try f.store.upsertSplit(account: f.account, id: split, name: item.name, ruleText: item.ruleText,
                                                position: nil, enabled: !item.enabled)
                case 1:
                    try f.store.reorderSplits(account: f.account, [split])
                case 2:
                    let item = try #require(try f.store.splits(account: f.account).first { $0.id == split })
                    _ = try f.store.upsertSplit(account: f.account, id: split, name: item.name,
                                                ruleText: rng.pick(["is:important", "subject:pitch", "from:acme.example", "label:Clients",
                                                                    "is:unread OR subject:invoice"]),
                                                position: nil, enabled: item.enabled)
                default:
                    try f.store.setImportanceSplit(account: f.account, rng.next() % 3 == 0 ? nil : split)
                }
            default:
                if rng.next() % 2 == 0 {
                    ImportanceMatchers.register(FlagMatcher(id: matcherID, readsText: rng.next() % 2 == 0, needle: "pitch"))
                } else {
                    ImportanceMatchers.unregister(id: matcherID)
                }
                try f.store.reevaluateImportance(account: nil)
            }
            if step % 10 == 9 {
                try fullRebuildChangesNothing(f.store)
                try assertSplitCountsMatch(f.store)
                seen.formUnion(try f.store.read { db in
                    try String.fetchAll(db, sql: """
                        SELECT DISTINCT importance FROM threads
                        UNION SELECT 'reason' FROM threads WHERE importance_reason_rid IS NOT NULL
                        UNION SELECT 'chips' FROM threads WHERE split_chip_rids <> ''
                        """)
                })
            }
        }
        #expect(seen == ["important", "normal", "suppressed", "reason", "chips"], "seed \(seed) saw \(seen.sorted())")
        #expect(receipts.filter { $0.undo != nil }.count >= 10)
    }

    private func assertSplitCountsMatch(_ store: MailStore, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let bad = try store.read { db in
            try Row.fetchAll(db, sql: """
                SELECT l.label_rid, l.total_threads, l.unread_threads, COALESCE(c.n, 0) AS n, COALESCE(c.u, 0) AS u
                FROM labels l LEFT JOIN (SELECT label_rid, count(*) n, sum(unread) u FROM thread_labels GROUP BY label_rid) c
                     USING (label_rid)
                WHERE l.total_threads <> COALESCE(c.n, 0) OR l.unread_threads <> COALESCE(c.u, 0)
                """)
        }
        #expect(bad.isEmpty, "count drift: \(bad)", sourceLocation: sourceLocation)
        let wrong = try store.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM threads t WHERE
                  (SELECT count(*) FROM thread_labels tl JOIN labels l USING (label_rid) WHERE tl.tid = t.tid AND l.kind = 'split')
                  <> t.in_inbox
                """) ?? 0
        }
        #expect(wrong == 0, "threads with the wrong number of split rows: \(wrong)", sourceLocation: sourceLocation)
    }
}

extension ImportanceRNG: RandomNumberGenerator {}
