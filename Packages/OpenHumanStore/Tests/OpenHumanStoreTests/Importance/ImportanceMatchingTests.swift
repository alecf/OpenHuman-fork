import Foundation
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct ImportanceMatchingTests {
    @Test func senderAndDomainRulesReadOnlyMailFromOthers() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "mine", labels: ["INBOX"], from: "me@example.com", subject: "note to self"),
                      .fixture("m2", thread: "sub", minutes: 1, labels: ["INBOX"], from: "x@mail.acme.example"),
                      .fixture("m3", thread: "lookalike", minutes: 2, labels: ["INBOX"], from: "x@notacme.example"),
                      .fixture("m4", thread: "colleague", minutes: 3, labels: ["INBOX"], from: "ann@example.com"),
                      .fixture("m5", thread: "colleague", minutes: 4, labels: ["INBOX"], from: "me@example.com")])
        try f.rule(.domain, "@ACME.example.")
        #expect(try f.importance("sub") == .important && f.importance("lookalike") == .normal)
        try f.rule(.domain, "example.com")
        #expect(try f.importance("mine") == .normal && f.importance("colleague") == .important)
        try f.rule(.sender, "Me <ME@example.com>", .neverImportant)
        #expect(try f.importance("colleague") == .important)
        #expect(try f.store.importanceRules(account: f.account).map(\.definition.value).sorted()
                == ["acme.example", "example.com", "me@example.com"])
        try fullRebuildChangesNothing(f.store)
    }

    @Test func keywordsMatchSubjectAndBodyCaseInsensitivelyAndABodyArrivingLaterCounts() throws {
        let f = try ImportanceFixture()
        try f.upsert([.fixture("m1", thread: "subject", labels: ["INBOX"], from: "a@x.example", subject: "URGENT: Ünïcode Invoice"),
                      .fixture("m2", thread: "body", minutes: 1, labels: ["INBOX"], from: "b@x.example", subject: "Hello",
                               snippet: "see attached"),
                      .fixture("m3", thread: "mine", minutes: 2, labels: ["INBOX"], from: "me@example.com",
                               subject: "re: Ünïcode invoice")])
        try f.rule(.keyword, "  ünïcode\u{200B} INVOICE ")
        #expect(try f.store.importanceRules(account: f.account).first?.definition.value == "ünïcode invoice")
        #expect(try f.importance("subject") == .important && f.importance("mine") == .normal)
        try f.rule(.keyword, "contract")
        #expect(try f.importance("body") == .normal)
        try f.store.storeBodies([(GmailMessageID("m2"), MessageBodyUpsert(text: "Please sign the CONTRACT today",
                                                                          hasCalendarInvite: false, decodeWarnings: [],
                                                                          searchText: "Please sign the CONTRACT today"), [])],
                                account: f.account)
        #expect(try f.importance("body") == .important)
        try f.upsert([.fixture("m4", thread: "snippet", minutes: 3, labels: ["INBOX"], from: "c@x.example", subject: "Hi",
                               snippet: "the contract is attached")])
        #expect(try f.importance("snippet") == .important)
        try fullRebuildChangesNothing(f.store)
    }

    @Test func labelRulesMatchByNameOrIdButNeverAHiddenLabel() throws {
        let f = try ImportanceFixture()
        try f.store.upsertLabels([LabelUpsert(gmailLabelID: GmailLabelID("Label_9"), name: "Clients/Acme", type: "user"),
                                  LabelUpsert(gmailLabelID: GmailLabelID("Label_8"), name: "OpenHuman/Snoozed", type: "user")],
                                 account: f.account, removeMissing: false)
        try f.upsert([.fixture("m1", thread: "client", labels: ["INBOX", "Label_9"]),
                      .fixture("m2", thread: "snoozy", minutes: 1, labels: ["INBOX", "Label_8"])])
        try f.rule(.label, "clients/acme")
        #expect(try f.importance("client") == .important)
        try f.rule(.label, "OpenHuman/Snoozed")
        try f.rule(.label, "Label_8")
        #expect(try f.importance("snoozy") == .normal)
        let byID = try f.rule(.label, "Label_9", .neverImportant)
        #expect(try f.importance("client") == .suppressed && f.threadRowReason("client") == byID.ruleIDs.first?.rawValue)
        _ = try f.store.deleteImportanceRules(byID.ruleIDs)
        try f.store.upsertLabels([LabelUpsert(gmailLabelID: GmailLabelID("Label_9"), name: "Clients/Renamed", type: "user")],
                                 account: f.account, removeMissing: false)
        #expect(try f.importance("client") == .normal)
        try fullRebuildChangesNothing(f.store)
    }

    @Test func matcherRulesUseTheRegisteredMatcherAndNothingElse() throws {
        let f = try ImportanceFixture()
        let id = uniqueMatcherID("flag")
        defer { ImportanceMatchers.unregister(id: id) }
        try f.upsert([.fixture("m1", thread: "urgent", labels: ["INBOX"], subject: "Urgent: server down"),
                      .fixture("m2", thread: "calm", minutes: 1, labels: ["INBOX"], subject: "Lunch?"),
                      .fixture("m3", thread: "invoice", minutes: 2, labels: ["INBOX"], subject: "Invoice 42")])
        try f.rule(.matcher, id)
        #expect(try f.importance("urgent") == .normal)
        ImportanceMatchers.register(FlagMatcher(id: id))
        #expect(ImportanceMatchers.registeredIDs.contains(id))
        try f.store.reevaluateImportance(account: f.account)
        #expect(try f.importance("urgent") == .important && f.importance("calm") == .normal)
        #expect(try f.store.importanceReason(f.ref("urgent")).line == "In Important: always important by the \(id) rule")
        try f.rule(.matcher, "\(id):lunch", .neverImportant)
        try f.rule(.matcher, "keyword:invoice")
        #expect(try f.importance("calm") == .suppressed && f.importance("invoice") == .important)
        try fullRebuildChangesNothing(f.store)
        ImportanceMatchers.unregister(id: id)
        ImportanceMatchers.unregister(id: "keyword")
        try f.store.reevaluateImportance(account: nil)
        #expect(try f.importance("urgent") == .normal && f.importance("calm") == .normal && f.importance("invoice") == .important)
        #expect(ImportanceMatchers.matcher(id: "keyword") != nil)
        try fullRebuildChangesNothing(f.store)
    }

    @Test func keywordMatcherFactsAndSemantics() {
        let facts = ImportanceFacts(accountID: AccountID(1), messages: [
            ImportanceMessageFacts(from: EmailAddress(email: "a@x.example"), to: [], cc: [], date: Date(timeIntervalSince1970: 0),
                                   isFromMe: false, isUnread: true, labelIDs: [], subject: "Quarterly",
                                   text: "the CONTRACT is attached"),
            ImportanceMessageFacts(from: EmailAddress(email: "me@x.example"), to: [], cc: [], date: Date(timeIntervalSince1970: 1),
                                   isFromMe: true, isUnread: false, labelIDs: [], subject: "secret", text: "budget"),
        ])
        let keyword = KeywordImportanceMatcher()
        #expect(keyword.id == "keyword" && keyword.readsText)
        #expect(keyword.matches(facts, argument: "Contract") && keyword.matches(facts, argument: "quarter"))
        #expect(!keyword.matches(facts, argument: "budget") && !keyword.matches(facts, argument: "secret"))
        #expect(!keyword.matches(facts, argument: "") && !keyword.matches(facts, argument: "missing"))
        #expect(TextSearch.contains("ab", "abc") == false && TextSearch.contains("xxabc", "abc") && !TextSearch.contains("abc", ""))
    }

    @Test func invalidValuesAndScopesAreRefused() throws {
        let f = try ImportanceFixture()
        let other = try f.store.addAccount(email: "two@example.com", displayName: nil, scopes: [])
        let foreign = try f.store.upsertSplit(account: other, id: nil, name: "Theirs", ruleText: "is:starred", position: nil,
                                              enabled: true)
        let mine = try f.split("Mine", "is:starred")
        func refused(_ d: ImportanceRuleDefinition) -> Bool {
            (try? f.store.addImportanceRule(d)) == nil
        }
        #expect(refused(.init(accountID: f.account, kind: .sender, value: "bob", effect: .important)))
        #expect(refused(.init(accountID: f.account, kind: .sender, value: "@acme.example", effect: .important)))
        #expect(refused(.init(accountID: f.account, kind: .domain, value: "localhost", effect: .important)))
        #expect(refused(.init(accountID: f.account, kind: .domain, value: "a@b.com", effect: .important)))
        #expect(refused(.init(accountID: f.account, kind: .keyword, value: " \u{200B} ", effect: .important)))
        #expect(refused(.init(accountID: f.account, kind: .keyword, value: String(repeating: "x", count: 201), effect: .important)))
        #expect(refused(.init(accountID: f.account, kind: .label, value: "  ", effect: .important)))
        #expect(refused(.init(accountID: f.account, kind: .matcher, value: "Bad Id", effect: .important)))
        #expect(refused(.init(accountID: f.account, kind: .matcher, value: "9lives", effect: .important)))
        #expect(refused(.init(accountID: f.account, kind: .sender, value: "a@b.com", effect: .important, splitID: mine)))
        #expect(refused(.init(accountID: nil, kind: .sender, value: "a@b.com", effect: .exemptFromSplit, splitID: mine)))
        #expect(throws: StoreError.notFound("split \(foreign.rawValue)")) {
            try f.store.addImportanceRule(.init(accountID: f.account, kind: .sender, value: "a@b.com", effect: .exemptFromSplit,
                                                splitID: foreign))
        }
        #expect(throws: StoreError.notFound("account 99")) {
            try f.store.addImportanceRule(.init(accountID: AccountID(99), kind: .sender, value: "a@b.com", effect: .important))
        }
        try f.store.setAccountStatus(other, .removing)
        #expect(throws: StoreError.accountNotActive(other)) {
            try f.store.addImportanceRule(.init(accountID: other, kind: .sender, value: "a@b.com", effect: .important))
        }
        #expect(try f.store.importanceRules(account: nil).isEmpty)
        let ok: [(ImportanceMatchKind, String, String)] = [
            (.sender, " mailto:Alice@Acme.EXAMPLE ", "alice@acme.example"), (.sender, "Alice Smith <alice@acme.example>", "alice@acme.example"),
            (.domain, "@Sub.Acme.example", "sub.acme.example"), (.keyword, "Pitch\u{00A0}  Deck", "pitch deck"),
            (.label, "  Clients/Acme ", "Clients/Acme"), (.matcher, "Sentiment.V1 : positive", "sentiment.v1:positive"),
        ]
        for (kind, raw, normalized) in ok {
            #expect(try ImportanceRuleValue.normalize(kind, raw) == normalized, "\(kind) \(raw)")
        }
    }
}
