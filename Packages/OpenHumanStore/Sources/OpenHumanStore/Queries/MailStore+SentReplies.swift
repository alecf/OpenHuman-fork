import Foundation
import GRDB
import OpenHumanCore

public struct SentReplies: Sendable, Hashable {
    public let email: String
    public let name: String?
    public let sentAt: [Date]

    public init(email: String, name: String?, sentAt: [Date]) {
        self.email = email
        self.name = name
        self.sentAt = sentAt
    }
}

extension MailStore {
    public static let sentRepliesScanLimit = 2000

    public func sentReplies(account: AccountID, since: Date, scanLimit: Int = MailStore.sentRepliesScanLimit) throws
        -> [SentReplies] {
        try read { db in try Self.sentReplies(account: account, since: since, scanLimit: scanLimit, in: db) }
    }

    static func sentReplies(account: AccountID, since: Date, scanLimit: Int, in db: Database) throws -> [SentReplies] {
        let mine = try ThreadAggregator.myAddresses(account: account.rawValue, in: db)
        let rows = try Row.fetchAll(db, sql: """
            SELECT internal_date, to_json FROM messages
            WHERE account_id = ?1 AND is_sent = 1 AND internal_date >= ?2
              AND is_draft = 0 AND in_trash = 0 AND in_spam = 0
              AND in_reply_to IS NOT NULL AND in_reply_to != ''
            ORDER BY internal_date DESC LIMIT ?3
            """, arguments: [account.rawValue, Int64((since.timeIntervalSince1970 * 1000).rounded(.down)), max(scanLimit, 0)])
        var dates: [String: [Date]] = [:]
        var names: [String: String] = [:]
        for row in rows {
            let millis: Int64 = row["internal_date"]
            let json: String = row["to_json"]
            let at = Date(timeIntervalSince1970: Double(millis) / 1000)
            var counted: Set<String> = []
            for address in DraftRowCodec.decodeAddresses(json) {
                let email = address.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !email.isEmpty, !mine.contains(email), counted.insert(email).inserted else { continue }
                dates[email, default: []].append(at)
                if names[email] == nil, let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    names[email] = name
                }
            }
        }
        return dates.map { SentReplies(email: $0.key, name: names[$0.key], sentAt: $0.value) }
            .sorted { lhs, rhs in
                if lhs.sentAt.count != rhs.sentAt.count { return lhs.sentAt.count > rhs.sentAt.count }
                let l = lhs.sentAt.first ?? .distantPast, r = rhs.sentAt.first ?? .distantPast
                if l != r { return l > r }
                return lhs.email < rhs.email
            }
    }
}
