import Foundation
import GRDB
import OpenHumanCore

struct SuperhumanReminderRule: Sendable, Equatable {
    static let keyPrefix = "superhuman_reminders."
    static let hideKey = "superhuman_reminders.hide"
    static let sendersKey = "superhuman_reminders.senders"
    static let sinceKey = "superhuman_reminders.since"
    static let backlogKey = "superhuman_reminders.backlog_imported"
    static let convertedKey = "superhuman_reminders.converted"
    static let returnedKey = "superhuman_reminders.returned"
    static let defaultSenders = ["reminder@superhuman.com"]

    var hide = true
    var senders: Set<String> = Set(defaultSenders)
    var since: Int64?
    var backlogImported = false
    var converted: Set<String> = []
    var returned: [String: Int64] = [:]

    var isActive: Bool { hide && !senders.isEmpty }

    struct Candidate: Sendable, Equatable {
        var mid: Int64
        var gmailID: String
        var internalDate: Int64
        var fromEmail: String?
        var isFromMe: Bool
        var isDraft: Bool
        var inTrash: Bool
        var inSpam: Bool
        var hasAttachments: Bool
        var hasCalendarInvite: Bool
        var inInbox: Bool

        var isVisible: Bool { !isDraft && !inTrash && !inSpam }
    }

    static func normalized(_ list: [String]) -> Set<String> {
        Set(list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { $0.contains("@") })
    }

    func isReminderEmail(_ c: Candidate) -> Bool {
        guard c.isVisible, !c.isFromMe, !c.hasAttachments, !c.hasCalendarInvite,
              let from = c.fromEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !from.isEmpty
        else { return false }
        return senders.contains(from)
    }

    private func isHandled(_ c: Candidate) -> Bool {
        backlogImported || (since.map { c.internalDate >= $0 } ?? false)
    }

    func hiddenMids(_ thread: [Candidate]) -> Set<Int64> {
        guard isActive else { return [] }
        let detected = thread.filter(isReminderEmail)
        guard !detected.isEmpty else { return [] }
        let detectedMids = Set(detected.map(\.mid))
        let hasOtherMail = thread.contains { $0.isVisible && !detectedMids.contains($0.mid) }
        return Set(detected.filter { converted.contains($0.gmailID) || (hasOtherMail && isHandled($0)) }.map(\.mid))
    }

    func returnAt(_ thread: [Candidate], hidden: Set<Int64>, gmailThreadID: String) -> Int64? {
        guard isActive else { return nil }
        let own = thread.lazy.filter { hidden.contains($0.mid) && $0.inInbox }.map(\.internalDate).max()
        switch (own, returned[gmailThreadID]) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    static func load(account: Int64, in db: Database) throws -> SuperhumanReminderRule {
        var rule = SuperhumanReminderRule()
        let accountScope = MailStore.scopeString(.account(AccountID(account)))
        let decoder = JSONDecoder()
        for row in try Row.fetchAll(db.cached("""
            SELECT scope, key, value_json FROM settings WHERE key >= ? AND key < ? AND scope IN ('global', ?)
            """), arguments: [keyPrefix, "superhuman_reminders/", accountScope]) {
            let scope: String = row["scope"]
            let key: String = row["key"]
            let data = Data((row["value_json"] as String).utf8)
            switch (scope == "global", key) {
            case (true, hideKey):
                if let value = try? decoder.decode(Bool.self, from: data) { rule.hide = value }
            case (true, sendersKey):
                if let value = try? decoder.decode([String].self, from: data) { rule.senders = normalized(value) }
            case (true, sinceKey):
                if let value = try? decoder.decode(Int64?.self, from: data) { rule.since = value }
            case (true, backlogKey):
                if let value = try? decoder.decode(Bool.self, from: data) { rule.backlogImported = value }
            case (false, convertedKey):
                if let value = try? decoder.decode([String].self, from: data) { rule.converted = Set(value) }
            case (false, returnedKey):
                if let value = try? decoder.decode([String: Int64].self, from: data) { rule.returned = value }
            default:
                break
            }
        }
        return rule
    }

    static func settingChanged(key: String, scope: SettingScope, previousJSON: String?, in db: Database) throws {
        let accounts: [Int64]
        switch scope {
        case .global: accounts = try Int64.fetchAll(db, sql: "SELECT account_id FROM accounts")
        case .account(let id): accounts = [id.rawValue]
        }
        let decoder = JSONDecoder()
        var tids = Set<Int64>()
        for account in accounts {
            let rule = try load(account: account, in: db)
            var senders = rule.senders
            var returnedThreads = Set(rule.returned.keys)
            if key == sendersKey {
                let previous = previousJSON.flatMap { try? decoder.decode([String].self, from: Data($0.utf8)) }
                senders.formUnion(normalized(previous ?? defaultSenders))
            }
            if key == returnedKey, let previousJSON,
               let previous = try? decoder.decode([String: Int64].self, from: Data(previousJSON.utf8)) {
                returnedThreads.formUnion(previous.keys)
            }
            for sender in senders.sorted() {
                tids.formUnion(try Int64.fetchAll(db.cached("""
                    SELECT DISTINCT tid FROM messages WHERE account_id = ? AND from_email = ?
                    """), arguments: [account, sender]))
            }
            for thread in returnedThreads.sorted() {
                if let tid = try Int64.fetchOne(db.cached("""
                    SELECT tid FROM threads WHERE account_id = ? AND gmail_thread_id = ?
                    """), arguments: [account, thread]) { tids.insert(tid) }
            }
        }
        if !tids.isEmpty { try ThreadAggregator.refresh(tids: tids, in: db) }
    }
}

extension SuperhumanReminderRule.Candidate {
    init(_ m: ThreadAggregator.Message) {
        self.init(mid: m.mid, gmailID: m.gmailID, internalDate: m.internalDate, fromEmail: m.fromEmail,
                  isFromMe: m.isFromMe, isDraft: m.isDraft, inTrash: m.inTrash, inSpam: m.inSpam,
                  hasAttachments: m.hasAttachments, hasCalendarInvite: m.hasCalendarInvite,
                  inInbox: m.labels.contains("INBOX"))
    }
}
