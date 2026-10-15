import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

actor UndoLog: MailUndoing {
    private(set) var steps: [String] = []
    let label: String
    var failNext = false

    init(_ label: String) { self.label = label }

    func setFailNext() { failNext = true }

    func undo(_ token: UndoToken) async throws -> UndoToken? {
        if failNext {
            failNext = false
            throw MailPortError.unavailable("test")
        }
        let name = String(decoding: token.payload, as: UTF8.self)
        steps.append("\(label):\(name)")
        return UndoToken(payload: Data((name.hasSuffix("+") ? String(name.dropLast()) : name + "+").utf8))
    }
}

private func rule(_ kind: BlockRule.Kind, _ value: String, _ disposition: BlockDisposition? = nil) -> BlockRule {
    BlockRule(kind: kind, value: value, disposition: disposition, createdAt: Date(timeIntervalSince1970: 1_800_000_000))!
}

@Suite struct BlockRuleListTests {
    @Test func addedRulesGoFirstAndReplaceTheSameId() {
        let old = rule(.sender, "a@acme.example", .trash)
        let other = rule(.domain, "spam.example")
        let new = rule(.sender, "a@acme.example", .archive)
        let next = BlockRuleList.applying(BlockRuleChange(account: AccountID(1), added: [new], removed: [old]), to: [other, old])
        #expect(next == [new, other])
    }

    @Test func theInverseOfAChangeRestoresTheList() {
        let a = rule(.sender, "a@acme.example"), b = rule(.domain, "spam.example")
        let change = BlockRuleChange(account: AccountID(1), added: [a], removed: [])
        let after = BlockRuleList.applying(change, to: [b])
        #expect(after == [a, b])
        #expect(BlockRuleList.applying(change.inverse, to: after) == [b])
    }

    @Test func searchNarrowsByTextAndIgnoresCase() {
        let rules = [rule(.sender, "news@acme.example"), rule(.domain, "spam.example")]
        #expect(BlockRuleList.filtered(rules, query: "  ACME ") == [rules[0]])
        #expect(BlockRuleList.filtered(rules, query: "example").count == 2)
        #expect(BlockRuleList.filtered(rules, query: "").count == 2)
        #expect(BlockRuleList.filtered(rules, query: "zzz").isEmpty)
    }

    @Test func typedValuesBecomeSenderOrDomainRules() {
        let now = Date()
        #expect(BlockRuleList.parse(" Dana@Acme.Example ", now: now)?.id == "sender:dana@acme.example")
        #expect(BlockRuleList.parse("@acme.example", now: now)?.id == "domain:acme.example", "a leading @ is a domain")
        #expect(BlockRuleList.parse("acme.example", now: now)?.id == "domain:acme.example")
        #expect(BlockRuleList.parse("nonsense", now: now) == nil)
        #expect(BlockRuleList.parse("a@b", now: now) == nil)
    }
}

@MainActor
@Suite struct BlockCenterTests {
    func makeCenter(finds: @escaping @Sendable (String, AccountID) async throws -> Bool = { _, _ in false })
        -> (BlockCenter, FakeMailStore) {
        let store = FakeMailStore(corpus: .make(threadCount: 3))
        return (BlockCenter(settings: store, finds: finds), store)
    }

    let account = AccountID(1)

    @Test func addRemoveAndUndoPersistThroughTheSettingsPort() async throws {
        let (center, store) = makeCenter()
        let a = rule(.sender, "a@acme.example"), d = rule(.domain, "spam.example")
        let addA = try await center.add(a, account: account)
        _ = try await center.add(d, account: account)
        #expect(await center.rules(account) == [d, a], "newest first")

        let removed = try await center.remove(ids: [a.id], account: account)
        #expect(await center.rules(account) == [d])
        let undoer = center.ruleUndoer
        let redo = try await undoer.undo(removed)
        #expect(Set(await center.rules(account).map(\.id)) == [a.id, d.id])
        _ = try await undoer.undo(try #require(redo))
        #expect(await center.rules(account) == [d])
        _ = try await undoer.undo(addA)
        #expect(await center.rules(account) == [d], "the add of a was already undone through the remove; nothing else changes")
        _ = store
    }

    @Test func addingTheSameRuleTwiceChangesNothingTheSecondTime() async throws {
        let (center, _) = makeCenter()
        let a = rule(.sender, "a@acme.example")
        _ = try await center.add(a, account: account)
        let again = try await center.add(a, account: account)
        #expect(again.changesNothing)
        #expect(await center.rules(account).count == 1)
    }

    @Test func eachRulesOwnChoiceChangesAndUndoes() async throws {
        let (center, _) = makeCenter()
        let a = rule(.sender, "a@acme.example")
        _ = try await center.add(a, account: account)
        let token = try await center.setDisposition(.trash, ofRule: a.id, account: account)
        #expect(await center.rules(account).first?.disposition == .trash)
        _ = try await center.ruleUndoer.undo(token)
        #expect(await center.rules(account).first?.disposition == nil)
    }

    @Test func theGlobalDefaultIsArchiveUntilChanged() async throws {
        let (center, _) = makeCenter()
        #expect(await center.defaultDisposition() == .archive)
        try await center.setDefaultDisposition(.trash)
        #expect(await center.defaultDisposition() == .trash)
    }

    @Test func accountsHaveSeparateLists() async throws {
        let (center, _) = makeCenter()
        _ = try await center.add(rule(.domain, "spam.example"), account: AccountID(1))
        #expect(await center.rules(AccountID(2)).isEmpty)
    }


    @Test func sentMailToTheSenderMeansAskFirst() async {
        let seen = Box()
        let (center, _) = makeCenter { query, _ in
            await seen.add(query)
            return true
        }
        #expect(await center.hasSentTo(rule(.sender, "friend@acme.example"), account: account))
        #expect(await center.hasSentTo(rule(.domain, "acme.example"), account: account))
        #expect(await seen.queries == [
            "in:sent (to:\"friend@acme.example\" OR cc:\"friend@acme.example\" OR bcc:\"friend@acme.example\")",
            "in:sent (to:\"acme.example\" OR cc:\"acme.example\" OR bcc:\"acme.example\")",
        ])
    }

    @Test func noSentMailMeansNoQuestion() async {
        let (center, _) = makeCenter { _, _ in false }
        #expect(await center.hasSentTo(rule(.sender, "stranger@acme.example"), account: account) == false)
    }

    @Test func aSearchThatFailsAsksToo() async {
        struct Boom: Error {}
        let (center, _) = makeCenter { _, _ in throw Boom() }
        #expect(await center.hasSentTo(rule(.domain, "acme.example"), account: account), "never block unasked when unsure")
    }
}

actor Box {
    private(set) var queries: [String] = []
    func add(_ query: String) { queries.append(query) }
}

@MainActor
@Suite struct BlockUndoerTests {
    func make() -> (BlockUndoer, UndoLog, UndoLog) {
        let rules = UndoLog("rule"), mail = UndoLog("mail")
        return (BlockUndoer(rules: rules, mail: mail), rules, mail)
    }

    @Test func oneUndoTakesBackTheCleanupThenTheRuleAndRedoDoesTheReverse() async throws {
        let (undoer, rules, mail) = make()
        let token = undoer.begin(rule: UndoToken(payload: Data("block".utf8)))
        #expect(undoer.attach(cleanup: UndoToken(payload: Data("archive".utf8)), to: token))

        let redo = try #require(try await undoer.undo(token))
        #expect(await mail.steps == ["mail:archive"])
        #expect(await rules.steps == ["rule:block"])
        #expect(!undoer.isApplied(token))

        _ = try await undoer.undo(redo)
        #expect(await rules.steps == ["rule:block", "rule:block+"], "the rule comes back first")
        #expect(await mail.steps == ["mail:archive", "mail:archive+"])
        #expect(undoer.isApplied(token))
    }

    @Test func theCleanupIsUndoneBeforeTheRuleOnUndoAndAfterItOnRedo() async throws {
        let log = UndoLog("x")
        let undoer = BlockUndoer(rules: Tagged(inner: log, tag: "rule"), mail: Tagged(inner: log, tag: "mail"))
        let token = undoer.begin(rule: UndoToken(payload: Data("block".utf8)))
        _ = undoer.attach(cleanup: UndoToken(payload: Data("trash".utf8)), to: token)
        let redo = try #require(try await undoer.undo(token))
        _ = try await undoer.undo(redo)
        #expect(await log.steps == ["x:mail/trash", "x:rule/block", "x:rule/block+", "x:mail/trash+"])
    }

    @Test func theBlockedConversationsMoveIsUndoneBetweenTheCleanupAndTheRule() async throws {
        let log = UndoLog("x")
        let undoer = BlockUndoer(rules: Tagged(inner: log, tag: "rule"), mail: Tagged(inner: log, tag: "mail"))
        let token = undoer.begin(rule: UndoToken(payload: Data("block".utf8)), moved: UndoToken(payload: Data("archive".utf8)))
        _ = undoer.attach(cleanup: UndoToken(payload: Data("trash".utf8)), to: token)
        let redo = try #require(try await undoer.undo(token))
        _ = try await undoer.undo(redo)
        #expect(await log.steps == ["x:mail/trash", "x:mail/archive", "x:rule/block",
                                    "x:rule/block+", "x:mail/archive+", "x:mail/trash+"])
    }

    @Test func aBlockWithNoCleanupUndoesJustTheRule() async throws {
        let (undoer, rules, mail) = make()
        let token = undoer.begin(rule: UndoToken(payload: Data("block".utf8)))
        _ = try await undoer.undo(token)
        #expect(await rules.steps == ["rule:block"])
        #expect(await mail.steps.isEmpty)
    }

    @Test func aCleanupChosenAfterTheBlockWasUndoneIsRefused() async throws {
        let (undoer, _, _) = make()
        let token = undoer.begin(rule: UndoToken(payload: Data("block".utf8)))
        _ = try await undoer.undo(token)
        #expect(!undoer.isApplied(token))
        #expect(!undoer.attach(cleanup: UndoToken(payload: Data("archive".utf8)), to: token), "the caller undoes the batch itself")
    }

    @Test func onlyOneCleanupAttachesToAnEntry() {
        let (undoer, _, _) = make()
        let token = undoer.begin(rule: UndoToken(payload: Data("block".utf8)))
        #expect(undoer.attach(cleanup: UndoToken(payload: Data("one".utf8)), to: token))
        #expect(!undoer.attach(cleanup: UndoToken(payload: Data("two".utf8)), to: token))
    }

    @Test func aFailedStepThrowsAndLeavesTheEntryUndoable() async throws {
        let (undoer, rules, mail) = make()
        let token = undoer.begin(rule: UndoToken(payload: Data("block".utf8)))
        _ = undoer.attach(cleanup: UndoToken(payload: Data("archive".utf8)), to: token)
        await mail.setFailNext()
        await #expect(throws: (any Error).self) { try await undoer.undo(token) }
        #expect(undoer.isApplied(token), "nothing was undone: the block is still in force")
        #expect(await rules.steps.isEmpty)
        _ = try await undoer.undo(token)
        #expect(await mail.steps == ["mail:archive"])
        #expect(await rules.steps == ["rule:block"])
    }

    @Test func theWindowsUndoStackHoldsOneEntryForBlockAndCleanup() async throws {
        let (undoer, rules, mail) = make()
        let coordinator = UndoCoordinator(commands: mail, notices: nil)
        let token = undoer.begin(rule: UndoToken(payload: Data("block".utf8)))
        coordinator.push(UndoCoordinator.Entry(title: "Blocked acme.example", token: token, undoer: undoer))
        _ = undoer.attach(cleanup: UndoToken(payload: Data("archive".utf8)), to: token)
        #expect(coordinator.stack.count == 1)
        await coordinator.undoLast()
        #expect(await mail.steps == ["mail:archive"])
        #expect(await rules.steps == ["rule:block"])
        #expect(coordinator.redoStack.count == 1)
        await coordinator.redoLast()
        #expect(undoer.isApplied(token))
        #expect(coordinator.stack.count == 1)
    }
}

struct Tagged: MailUndoing {
    let inner: UndoLog
    let tag: String

    func undo(_ token: UndoToken) async throws -> UndoToken? {
        let name = String(decoding: token.payload, as: UTF8.self)
        let base = name.hasSuffix("+") ? String(name.dropLast()) : name
        let back = try await inner.undo(UndoToken(payload: Data("\(tag)/\(name)".utf8)))
        _ = back
        return UndoToken(payload: Data((name.hasSuffix("+") ? base : name + "+").utf8))
    }
}
