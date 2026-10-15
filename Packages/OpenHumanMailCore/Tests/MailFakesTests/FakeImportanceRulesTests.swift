import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFakes

@Suite struct FakeImportanceRulesTests {
    let thread = ThreadKey(account: work, rowID: 1, gmailThreadID: GmailThreadID("t-importance"))

    @Test func neverFromADomainReplacesAlwaysAndTheSenderRuleStillWins() async throws {
        let port = FakeImportanceRules()
        port.learn(thread, .init(sender: "Alice@Example.com", gmailImportant: false))
        _ = try await port.apply(ImportanceChange(kind: .alwaysDomain, account: work, value: "example.com"))
        _ = try await port.apply(ImportanceChange(kind: .neverDomain, account: work, value: "Example.com"))
        #expect(port.allRules.map(\.kind) == [.neverDomain], "never replaces always for the same domain")
        #expect(port.allRules.first?.match == .domain && port.allRules.first?.effect == .neverImportant)
        var why = try await port.explain(thread)
        #expect(!why.isImportant && why.reason == "Never important from example.com")

        _ = try await port.apply(ImportanceChange(kind: .alwaysSender, account: work, value: "alice@example.com"))
        why = try await port.explain(thread)
        #expect(why.isImportant && why.reason == "Always important from alice@example.com", "the sender rule is more specific")
        let other = ThreadKey(account: work, rowID: 2, gmailThreadID: GmailThreadID("t-other"))
        port.learn(other, .init(sender: "bob@mail.example.com", gmailImportant: true))
        #expect(try await !port.explain(other).isImportant, "a subdomain is in the domain; bob is not an exception")
    }

    @Test func keywordAndLabelRulesCarryTheirEffect() async throws {
        let port = FakeImportanceRules()
        port.learn(thread, .init(sender: "bob@example.org", gmailImportant: true, subject: "Invoice for the newsletter",
                                 labels: ["Clients"]))
        _ = try await port.apply(ImportanceChange(kind: .keyword, account: work, value: "Invoice"))
        _ = try await port.apply(ImportanceChange(kind: .keyword, account: work, value: "newsletter", effect: .neverImportant))
        #expect(port.allRules.map(\.value) == ["invoice", "newsletter"])
        #expect(port.allRules.map(\.effect) == [.important, .neverImportant])
        #expect(port.allRules.allSatisfy { $0.kind == .keyword && $0.match == .keyword })
        var why = try await port.explain(thread)
        #expect(!why.isImportant && why.reason == "Never important when it mentions \u{201C}newsletter\u{201D}",
                "never beats always at the same level")

        _ = try await port.apply(ImportanceChange(kind: .label, account: work, value: " Clients "))
        #expect(port.allRules.last?.value == "Clients", "a label keeps its case")
        why = try await port.explain(thread)
        #expect(why.isImportant && why.reason == "Always important with the label Clients", "a label beats any keyword")

        _ = try await port.apply(ImportanceChange(kind: .neverDomain, account: work, value: "example.org"))
        #expect(try await !port.explain(thread).isImportant, "a domain beats any label")
    }

    @Test func theKindDecidesTheEffectOfOneKeyOverrides() {
        let always = ImportanceChange(kind: .alwaysSender, account: work, value: "Dana@Example.com", effect: .neverImportant)
        #expect(always.effect == .important && always.value == "dana@example.com")
        #expect(ImportanceChange(kind: .keyword, account: work, value: "Hi").effect == .important)
        #expect(ImportanceChange(kind: .notPitch, account: work, value: "a@b.c").effect == .exemptFromSplit)
        #expect(ImportanceRuleKind.kind(match: .domain, effect: .neverImportant) == .neverDomain)
        #expect(ImportanceRuleKind.kind(match: .label, effect: .exemptFromSplit) == .excludeFromSplit)
        #expect(ImportanceRuleKind.allCases.allSatisfy { kind in
            kind.impliedEffect.map { ImportanceRuleKind.kind(match: kind.match, effect: $0) == kind || kind == .notPitch } ?? true
        })
        let info = ImportanceRuleInfo(id: "1", kind: .neverDomain, account: work, value: "example.com", split: nil,
                                      createdAt: fixedNow)
        #expect(info.match == .domain && info.effect == .neverImportant && info.origin == .user && !info.appliesToEveryAccount)
    }

    @Test func updateKeepsTheIdAndDeleteUndoesWithTheRules() async throws {
        let port = FakeImportanceRules()
        _ = try await port.apply(ImportanceChange(kind: .alwaysSender, account: work, value: "dana@example.com"))
        let id = try #require(port.allRules.first?.id)
        let edit = try await port.update(id, to: ImportanceChange(kind: .neverDomain, account: work, value: "example.com"))
        #expect(port.allRules.map(\.id) == [id] && port.allRules.first?.kind == .neverDomain)
        _ = try await port.undo(edit)
        #expect(port.allRules.first?.kind == .alwaysSender && port.allRules.first?.value == "dana@example.com")

        let deletion = try await port.delete([id])
        #expect(port.allRules.isEmpty)
        let redo = try #require(try await port.undo(deletion))
        #expect(port.allRules.map(\.id) == [id], "undo brings the rule back with its id")
        #expect(try await port.undo(deletion) == nil, "a deletion already undone has nothing left to undo")
        _ = try await port.undo(redo)
        #expect(port.allRules.isEmpty, "the redo deletes it again")
    }

    @Test func anUndoWhoseRuleWasEditedSinceDoesNothing() async throws {
        let port = FakeImportanceRules()
        let added = try await port.apply(ImportanceChange(kind: .alwaysDomain, account: work, value: "example.com"))
        let id = try #require(port.allRules.first?.id)
        _ = try await port.update(id, to: ImportanceChange(kind: .alwaysDomain, account: work, value: "example.org"))
        #expect(try await port.undo(added) == nil, "the rule it added is not as it was")
        #expect(port.allRules.map(\.value) == ["example.org"])
    }

    @Test func anUnknownRuleIsNotFoundAndAQueuedFailureIsThrown() async throws {
        let change = ImportanceChange(kind: .neverDomain, account: work, value: "example.com")
        let port = FakeImportanceRules()
        await #expect(throws: MailPortError.notFound("rule")) { try await port.update("rule-9", to: change) }
        port.failNext(.unavailable("test"))
        await #expect(throws: MailPortError.unavailable("test")) { try await port.delete([]) }
    }

    @Test func theRulesStreamFollowsSettingsEdits() async throws {
        let port = FakeImportanceRules()
        var iterator = port.rules(work).makeAsyncIterator()
        #expect(try await iterator.next() == [])
        _ = try await port.apply(ImportanceChange(kind: .keyword, account: work, value: "invoice"))
        let id = try #require(try await iterator.next()?.first?.id)
        _ = try await port.update(id, to: ImportanceChange(kind: .keyword, account: work, value: "invoice", effect: .neverImportant))
        #expect(try await iterator.next()?.map(\.effect) == [.neverImportant])
        _ = try await port.delete([id])
        #expect(try await iterator.next() == [])
    }
}
