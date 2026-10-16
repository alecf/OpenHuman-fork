import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanStore
import Testing
@testable import OpenHumanMail

private let now = Date(timeIntervalSince1970: 1_791_000_000)

@Test(.timeLimit(.minutes(1))) func everyStoreRuleIsListedWithItsMatchEffectOriginAndScope() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: FakeCorpus.make(threadCount: 5, now: now))
    _ = try store.addImportanceRule(ImportanceRuleDefinition(accountID: account, kind: .keyword, value: "Invoice",
                                                             effect: .important))
    _ = try store.addImportanceRule(ImportanceRuleDefinition(accountID: account, kind: .label, value: "Clients",
                                                             effect: .neverImportant))
    _ = try store.addImportanceRule(ImportanceRuleDefinition(accountID: nil, kind: .domain, value: "example.org",
                                                             effect: .neverImportant))
    _ = try store.addImportanceRule(ImportanceRuleDefinition(accountID: account, kind: .matcher, value: "keyword:urgent",
                                                             effect: .important, source: .ai))
    let port = MailStoreImportance(store: store)
    let rules = try await firstValue(port.rules(account)) { $0.count == 4 }
    let byValue = Dictionary(rules.map { ($0.value, $0) }, uniquingKeysWith: { first, _ in first })
    let keyword = try #require(byValue["invoice"])
    #expect(keyword.kind == .keyword && keyword.match == .keyword && keyword.effect == .important)
    let label = try #require(byValue["Clients"])
    #expect(label.kind == .label && label.effect == .neverImportant && !label.appliesToEveryAccount)
    let domain = try #require(byValue["example.org"])
    #expect(domain.kind == .neverDomain && domain.appliesToEveryAccount && domain.origin == .user)
    let matcher = try #require(byValue["keyword:urgent"])
    #expect(matcher.kind == .matcher && matcher.origin == .ai)
    #expect(rules.allSatisfy { $0.account == account })
}

@Test(.timeLimit(.minutes(1))) func neverFromTheDomainPlusAlwaysFromTheSenderKeepsTheSenderImportant() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: FakeCorpus.make(threadCount: 10, now: now))
    let data = MailStoreAdapter(store: store)
    let window = try await firstValue(data.threadWindow(.system(.inbox), account: account, limit: 20)) { !$0.rows.isEmpty }
    let row = try #require(window.rows.first { !$0.isImportant && !$0.participants.allSatisfy(\.isMe) })
    let sender = try #require(row.participants.first { !$0.isMe }?.email.lowercased())
    let domain = String(try #require(sender.split(separator: "@").last))
    let port = MailStoreImportance(store: store)

    _ = try await port.apply(ImportanceChange(kind: .neverDomain, account: account, value: domain, thread: row.id))
    var why = try await port.explain(row.id)
    #expect(!why.isImportant && why.reason == "never important from \(domain)")
    let always = try await port.apply(ImportanceChange(kind: .alwaysSender, account: account, value: sender, thread: row.id))
    why = try await port.explain(row.id)
    #expect(why.isImportant && why.reason == "always important from \(sender)", "the sender rule is more specific")
    let listed = try await firstValue(port.rules(account)) { $0.count == 2 }
    #expect(Set(listed.map(\.kind)) == [.neverDomain, .alwaysSender])
    _ = try await port.undo(always)
    #expect(try await !port.explain(row.id).isImportant, "undo leaves the domain rule deciding")
}

@Test(.timeLimit(.minutes(1))) func settingsEditsKeepTheIdAndScopeAndDeletesUndo() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: FakeCorpus.make(threadCount: 5, now: now))
    let port = MailStoreImportance(store: store)
    _ = try store.addImportanceRule(ImportanceRuleDefinition(accountID: nil, kind: .domain, value: "example.org",
                                                             effect: .important, source: .ai))
    let everyAccount = try #require(try store.importanceRules(account: account).first)

    let edit = try await port.update(String(everyAccount.id.rawValue),
                                     to: ImportanceChange(kind: .neverDomain, account: account, value: "example.org"))
    let edited = try #require(try store.importanceRules(account: account).first)
    #expect(edited.id == everyAccount.id && edited.definition.accountID == nil)
    #expect(edited.definition.effect == .neverImportant && edited.definition.source == .user)
    _ = try await port.undo(edit)
    #expect(try store.importanceRules(account: account).first?.definition == everyAccount.definition)

    _ = try await port.apply(ImportanceChange(kind: .keyword, account: account, value: "Quarterly report",
                                              effect: .neverImportant))
    let keyword = try #require(try store.importanceRules(account: account).first { $0.definition.kind == .keyword })
    #expect(keyword.definition.value == "quarterly report" && keyword.definition.effect == .neverImportant)
    let deletion = try await port.delete([String(keyword.id.rawValue)])
    #expect(try store.importanceRules(account: account).count == 1)
    let redo = try await port.undo(deletion)
    #expect(redo != nil)
    #expect(try store.importanceRules(account: account).contains { $0.id == keyword.id })
    #expect(try await port.undo(deletion) == nil, "the rows are back: nothing left to undo")

    await #expect(throws: MailPortError.notFound("rule")) {
        try await port.update("not-a-rule", to: ImportanceChange(kind: .alwaysSender, account: account, value: "a@example.com"))
    }
    await #expect(throws: MailPortError.notFound("thread or rule")) {
        try await port.update("999999", to: ImportanceChange(kind: .alwaysSender, account: account, value: "a@example.com"))
    }
}

@Test(.timeLimit(.minutes(1))) func movingOneConversationIsAThreadRuleThatASenderRuleOutranks() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: FakeCorpus.make(threadCount: 10, now: now))
    let data = MailStoreAdapter(store: store)
    let window = try await firstValue(data.threadWindow(.system(.inbox), account: account, limit: 20)) { !$0.rows.isEmpty }
    let row = try #require(window.rows.first { !$0.isImportant && !$0.participants.allSatisfy(\.isMe) })
    let sender = try #require(row.participants.first { !$0.isMe }?.email.lowercased())
    let port = MailStoreImportance(store: store)

    let moved = try await port.apply(ImportanceChange(kind: .alwaysThread, account: account,
                                                      value: row.id.gmailThreadID.rawValue, thread: row.id))
    var why = try await port.explain(row.id)
    #expect(why.isImportant && why.reason == "moved to Important (this conversation only)")
    let stored = try #require(try store.importanceRules(account: account).first)
    #expect(stored.definition.kind == .matcher && stored.definition.value == "thread:\(row.id.gmailThreadID.rawValue)")
    let listed = try await firstValue(port.rules(account)) { $0.count == 1 }
    #expect(listed.first?.kind == .alwaysThread && listed.first?.match == .thread
            && listed.first?.value == row.id.gmailThreadID.rawValue)

    _ = try await port.apply(ImportanceChange(kind: .neverSender, account: account, value: sender, thread: row.id))
    why = try await port.explain(row.id)
    #expect(!why.isImportant && why.reason == "never important from \(sender)", "thread scope is below sender")
    _ = moved
}

@Test(.timeLimit(.minutes(1))) func replyCountersAreTheStoresSentReplies() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: FakeCorpus.make(threadCount: 12, now: now))
    let expected = try store.sentReplies(account: account, since: .distantPast)
    let counters = try await MailStoreImportance(store: store).replyCounters(account, since: .distantPast)
    #expect(counters.map(\.email) == expected.map(\.email))
    #expect(counters.map(\.repliedAt) == expected.map(\.sentAt))
    #expect(counters.map(\.name) == expected.map(\.name))
}

@Test(.timeLimit(.minutes(1))) func rowCarriesThePlacementAndTheGmailMark() async throws {
    let (store, account) = try FixtureStoreSeeder.makeStore(corpus: FakeCorpus.make(threadCount: 12, now: now))
    let data = MailStoreAdapter(store: store)
    let inbox = try await firstValue(data.threadWindow(.system(.inbox), account: account, limit: 50)) { !$0.rows.isEmpty }
    let marked = try #require(inbox.rows.first { $0.isImportant && !$0.participants.allSatisfy(\.isMe) })
    #expect(marked.isPlacedImportant, "by default Gmail's mark places the conversation in Important")
    #expect(inbox.rows.filter { !$0.isImportant }.allSatisfy { !$0.isPlacedImportant })

    let port = MailStoreImportance(store: store)
    _ = try await port.apply(ImportanceChange(kind: .neverThread, account: account,
                                              value: marked.id.gmailThreadID.rawValue, thread: marked.id))
    let other = try await firstValue(data.threadWindow(.splitOther, account: account, limit: 50)) { window in
        window.rows.contains { $0.id == marked.id }
    }
    let row = try #require(other.rows.first { $0.id == marked.id })
    #expect(row.isImportant && !row.isPlacedImportant, "Gmail's mark and Mail's placement travel separately")
    let why = try await port.explain(marked.id)
    #expect(why.gmailImportant && !why.isImportant && why.gmailDisagrees)
    #expect(why.line == "In Other: moved to Other (this conversation only); Gmail marks it important")
}
