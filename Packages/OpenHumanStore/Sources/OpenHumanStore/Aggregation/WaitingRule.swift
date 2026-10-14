import Foundation
import GRDB
import OpenHumanCore

public enum WaitingOverride: String, Codable, Sendable {
    case notWaiting = "not_waiting"
    case waiting
}

enum WaitingRule {
    static let automatedPrefixes = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply",
                                    "mailer-daemon", "postmaster", "notifications", "notification", "bounce"]

    static func overrides(account: Int64, in db: Database) throws -> [Int64: String] {
        var out: [Int64: String] = [:]
        for row in try Row.fetchAll(db.cached("SELECT tid, state FROM waiting_overrides WHERE account_id = ?"),
                                    arguments: [account]) {
            out[row["tid"]] = row["state"]
        }
        return out
    }

    static func waitingLabelKeys(keyByName: [String: String]) -> Set<String> {
        var names = [OHGmailLabels.superhumanAutoLabelPrefix + "Waiting"]
        if let ours = OHGmailLabels.autoLabel("Waiting") { names.append(ours) }
        return Set(names.compactMap { keyByName[$0] })
    }

    static func isAutomated(_ email: String) -> Bool {
        let local = email.lowercased().split(separator: "@").first.map(String.init) ?? ""
        return automatedPrefixes.contains { local.hasPrefix($0) }
    }

    static func waitingSince(tid: Int64, visible: [ThreadAggregator.Message], context: AggregationContext) -> Int64? {
        let override = context.waitingOverrides[tid]
        if override == WaitingOverride.notWaiting.rawValue { return nil }
        guard let last = visible.last, last.isOwn else { return nil }
        if override == WaitingOverride.waiting.rawValue { return last.internalDate }
        let labels = visible.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
        if let muted = context.keyByName[OHGmailLabels.muted], labels.contains(muted) { return nil }
        if !context.waitingLabelKeys.isDisjoint(with: labels) { return last.internalDate }
        let recipients = WireAddress.decode(last.toJSON) + WireAddress.decode(last.ccJSON)
        let someoneElse = recipients.contains { address in
            let email = address.e.lowercased()
            return !email.isEmpty && !context.me.contains(email) && !isAutomated(email)
        }
        return someoneElse ? last.internalDate : nil
    }
}

extension MailStore {
    @discardableResult
    public func setWaitingOverride(_ thread: ThreadRef, _ state: WaitingOverride?) throws -> WaitingOverride? {
        try write { db in
            guard try Int64.fetchOne(db, sql: "SELECT tid FROM threads WHERE tid = ? AND account_id = ?",
                                     arguments: [thread.rowID.rawValue, thread.accountID.rawValue]) != nil else {
                throw StoreError.notFound("thread \(thread.rowID.rawValue)")
            }
            let previous = try String.fetchOne(db, sql: "SELECT state FROM waiting_overrides WHERE tid = ?",
                                               arguments: [thread.rowID.rawValue]).flatMap(WaitingOverride.init(rawValue:))
            if let state {
                try db.execute(sql: """
                    INSERT INTO waiting_overrides (tid, account_id, state, set_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT (tid) DO UPDATE SET state = excluded.state, set_at = excluded.set_at
                    """, arguments: [thread.rowID.rawValue, thread.accountID.rawValue, state.rawValue, nowMillis()])
            } else {
                try db.execute(sql: "DELETE FROM waiting_overrides WHERE tid = ?", arguments: [thread.rowID.rawValue])
            }
            try ThreadAggregator.refresh(tids: [thread.rowID.rawValue], in: db)
            return previous
        }
    }

    public func waitingSince(_ thread: ThreadRef) throws -> Date? {
        try read { db in
            try Int64.fetchOne(db, sql: """
                SELECT tl.sort_at FROM thread_labels tl JOIN labels l ON l.label_rid = tl.label_rid
                WHERE tl.tid = ? AND l.key = 'oh:waiting'
                """, arguments: [thread.rowID.rawValue]).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        }
    }
}
