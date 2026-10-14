import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

struct ImportanceFixture {
    let store: MailStore
    let account: AccountID

    init(email: String = "me@example.com") throws {
        (store, account) = try OpenHumanStoreTesting.storeWithAccount(email: email)
    }

    init(store: MailStore, account: AccountID) {
        self.store = store
        self.account = account
    }

    @discardableResult
    func upsert(_ messages: [MessageUpsert]) throws -> UpsertResult {
        try store.upsertMessages(messages, account: account, generation: 1)
    }

    func ref(_ thread: String) throws -> ThreadRef {
        try #require(try store.thread(account: account, gmailThreadID: GmailThreadID(thread)))
    }

    func item(_ thread: String) throws -> ThreadListItem {
        try #require(try store.thread(ref(thread)))
    }

    func view(_ view: MailboxView) throws -> [String] {
        try store.threadPage(view: view, after: nil, limit: 200).items.map(\.ref.gmailThreadID.rawValue)
    }

    var importanceSplit: SplitItem {
        get throws { try #require(try store.splits(account: account).first(where: \.isImportanceSplit)) }
    }

    func members(of split: String) throws -> [String] {
        if split == "Other" { return try view(.splitOther(account)) }
        let item = try #require(try store.splits(account: account).first { $0.name == split })
        return try view(.split(account, item.id))
    }

    func placement(_ thread: String) throws -> String {
        let t = try ref(thread).rowID.rawValue
        let names = try store.read { db in
            try String.fetchAll(db, sql: """
                SELECT l.name FROM thread_labels tl JOIN labels l USING (label_rid) WHERE tl.tid = ? AND l.kind = 'split'
                """, arguments: [t])
        }
        try #require(names.count <= 1, "a thread is in at most one split view")
        return names.first ?? "-"
    }

    func chips(_ thread: String) throws -> [String] {
        let rids = try item(thread).splitChipIDs
        let splits = try store.splits(account: account)
        return rids.map { rid in splits.first { $0.labelRowID == rid }?.name ?? "?" }
    }

    @discardableResult
    func split(_ name: String, _ ruleText: String, enabled: Bool = true) throws -> SplitID {
        try store.upsertSplit(account: account, id: nil, name: name, ruleText: ruleText, position: nil, enabled: enabled)
    }

    @discardableResult
    func rule(_ kind: ImportanceMatchKind, _ value: String, _ effect: ImportanceEffect = .important,
              split: SplitID? = nil, source: ImportanceRuleSource = .user, global: Bool = false) throws -> ImportanceRuleReceipt {
        try store.addImportanceRule(ImportanceRuleDefinition(accountID: global ? nil : account, kind: kind, value: value,
                                                             effect: effect, splitID: split, source: source))
    }

    func importance(_ thread: String) throws -> ThreadImportance { try item(thread).importance }
}

func importanceDerivedState(_ store: MailStore) throws -> [String] {
    try store.read { db in
        var out = try String.fetchAll(db, sql: "SELECT label_rid || ':' || sort_at || ':' || tid || ':' || unread FROM thread_labels")
        for row in try Row.fetchAll(db, sql: "SELECT * FROM threads") {
            out.append(row.columnNames.filter { $0 != "updated_at" }.map { "\($0)=\(row[$0] as DatabaseValue)" }.joined(separator: "|"))
        }
        out += try String.fetchAll(db, sql: "SELECT 'count:' || label_rid || ':' || total_threads || ':' || unread_threads FROM labels")
        return out.sorted()
    }
}

func fullRebuildChangesNothing(_ store: MailStore, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let incremental = try importanceDerivedState(store)
    try store.write { db in
        try ThreadAggregator.refresh(tids: Set(try Int64.fetchAll(db, sql: "SELECT tid FROM threads")), in: db)
    }
    let rebuilt = try importanceDerivedState(store)
    #expect(rebuilt == incremental, """
        a full rebuild changed derived rows: \(Set(incremental).subtracting(rebuilt).sorted()) \
        -> \(Set(rebuilt).subtracting(incremental).sorted())
        """, sourceLocation: sourceLocation)
}

struct ImportanceRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func pick<T>(_ list: [T]) -> T { list[Int(next() % UInt64(list.count))] }
}

struct FlagMatcher: ImportanceMatcher {
    let id: String
    var readsText: Bool = false
    var needle = "urgent"

    func matches(_ facts: ImportanceFacts, argument: String) -> Bool {
        let wanted = argument.isEmpty ? needle : argument
        return facts.messages.contains { $0.subject.lowercased().contains(wanted) }
    }
}

func uniqueMatcherID(_ base: String) -> String {
    "test.\(base).\(UUID().uuidString.prefix(8).lowercased())"
}
