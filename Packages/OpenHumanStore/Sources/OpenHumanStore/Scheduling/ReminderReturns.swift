import Foundation
import GRDB
import OpenHumanCore

enum ReminderReturns {
    static let key = "reminders.returned"

    private struct Boosted {
        let tid: Int64
        let thread: String
        let boost: Int64
        let lastMessageAt: Int64
    }

    static func load(account: Int64, in db: Database) throws -> [String: Int64] {
        guard let json = try String.fetchOne(db.cached("SELECT value_json FROM settings WHERE scope = ? AND key = ?"),
                                             arguments: [MailStore.scopeString(.account(AccountID(account))), key])
        else { return [:] }
        return (try? JSONDecoder().decode([String: Int64].self, from: Data(json.utf8))) ?? [:]
    }

    static func record(account: Int64, gmailThreadID: String, at time: Int64, in db: Database) throws {
        var entries = try load(account: account, in: db)
        entries[gmailThreadID] = time
        var kept: [String: Int64] = [:]
        for (thread, at) in entries {
            let tagged = try Bool.fetchOne(db.cached("""
                SELECT EXISTS (SELECT 1 FROM threads WHERE account_id = ? AND gmail_thread_id = ? AND in_inbox = 1
                               AND sort_boost_at = ?)
                """), arguments: [account, thread, at]) ?? false
            if tagged { kept[thread] = at }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(kept), as: UTF8.self)
        try MailStore.upsertSetting(scope: .account(AccountID(account)), key: key, json: json, in: db)
    }

    static func decorate(_ items: [ThreadListItem], in db: Database) throws -> [ThreadListItem] {
        guard !items.isEmpty else { return items }
        let tids = items.map(\.id.rawValue)
        var boosts: [Int64: (boost: Int64, lastMessageAt: Int64)] = [:]
        for chunk in chunks(tids) {
            for row in try Row.fetchAll(db, sql: """
                SELECT tid, sort_boost_at, last_message_at FROM threads
                WHERE tid IN (\(marks(chunk.count))) AND in_inbox = 1 AND sort_boost_at IS NOT NULL AND reminder_at IS NULL
                """, arguments: StatementArguments(chunk)) {
                boosts[row[0] as Int64] = (row[1] as Int64, row[2] as Int64)
            }
        }
        guard !boosts.isEmpty else { return items }
        var byAccount: [Int64: [Boosted]] = [:]
        for item in items {
            guard let found = boosts[item.id.rawValue] else { continue }
            byAccount[item.ref.accountID.rawValue, default: []].append(
                Boosted(tid: item.id.rawValue, thread: item.ref.gmailThreadID.rawValue, boost: found.boost,
                        lastMessageAt: found.lastMessageAt))
        }
        var returned = Set<Int64>()
        for account in byAccount.keys.sorted() {
            let recorded = try load(account: account, in: db)
            var unmatched: [Boosted] = []
            for candidate in byAccount[account] ?? [] {
                if recorded[candidate.thread] == candidate.boost {
                    returned.insert(candidate.tid)
                } else {
                    unmatched.append(candidate)
                }
            }
            returned.formUnion(try superhumanReturns(account: account, candidates: unmatched, in: db))
        }
        guard !returned.isEmpty else { return items }
        return items.map { item in
            guard returned.contains(item.id.rawValue) else { return item }
            var copy = item
            copy.returnedByReminder = true
            return copy
        }
    }

    static func decorate(_ page: ThreadPage, in db: Database) throws -> ThreadPage {
        ThreadPage(items: try decorate(page.items, in: db), nextCursor: page.nextCursor)
    }

    static func decorate(_ item: ThreadListItem, in db: Database) throws -> ThreadListItem {
        try decorate([item], in: db)[0]
    }

    private static func superhumanReturns(account: Int64, candidates: [Boosted], in db: Database) throws -> Set<Int64> {
        guard !candidates.isEmpty else { return [] }
        let rule = try SuperhumanReminderRule.load(account: account, in: db)
        guard rule.isActive else { return [] }
        let senders = rule.senders.sorted()
        var fromSender = Set<Int64>()
        for chunk in chunks(candidates.map(\.tid)) {
            let arguments = chunk.map(\.databaseValue) + senders.map(\.databaseValue)
            fromSender.formUnion(try Int64.fetchAll(db, sql: """
                SELECT DISTINCT tid FROM messages
                WHERE tid IN (\(marks(chunk.count))) AND lower(trim(from_email)) IN (\(marks(senders.count)))
                """, arguments: StatementArguments(arguments)))
        }
        var result = Set<Int64>()
        for candidate in candidates where fromSender.contains(candidate.tid) || rule.returned[candidate.thread] != nil {
            let messages = try ThreadAggregator.loadMessages(tid: candidate.tid, in: db).map { SuperhumanReminderRule.Candidate($0) }
            guard let back = rule.returnAt(messages, hidden: rule.hiddenMids(messages), gmailThreadID: candidate.thread),
                  back > candidate.lastMessageAt, back == candidate.boost else { continue }
            result.insert(candidate.tid)
        }
        return result
    }

    private static func chunks(_ ids: [Int64]) -> [[Int64]] {
        stride(from: 0, to: ids.count, by: 500).map { Array(ids[$0..<min($0 + 500, ids.count)]) }
    }

    private static func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}
