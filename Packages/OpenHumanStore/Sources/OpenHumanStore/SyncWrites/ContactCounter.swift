import Foundation
import GRDB

enum ContactCounter {
    static func count(account: Int64, from: (name: String?, email: String)?, recipients: [(name: String?, email: String)],
                      date: Int64, isFromMe: Bool, labels: Set<String>, me: Set<String>, in db: Database) throws {
        if labels.contains("DRAFT") || labels.contains("SPAM") { return }
        if isFromMe {
            var seen = Set<String>()
            for r in recipients {
                let email = r.email.trimmingCharacters(in: .whitespaces).lowercased()
                guard !email.isEmpty, !me.contains(email), seen.insert(email).inserted else { continue }
                try db.cached("""
                    INSERT INTO contacts (account_id, email, name, sent_count, last_sent_at) VALUES (?, ?, ?, 1, ?)
                    ON CONFLICT (account_id, email) DO UPDATE SET sent_count = sent_count + 1,
                        last_sent_at = max(COALESCE(last_sent_at, 0), excluded.last_sent_at),
                        name = COALESCE(excluded.name, name)
                    """).execute(arguments: [account, email, clean(r.name), date])
            }
        } else if let from {
            let email = from.email.trimmingCharacters(in: .whitespaces).lowercased()
            guard !email.isEmpty, !me.contains(email) else { return }
            try db.cached("""
                INSERT INTO contacts (account_id, email, name, received_count, last_received_at) VALUES (?, ?, ?, 1, ?)
                ON CONFLICT (account_id, email) DO UPDATE SET received_count = received_count + 1,
                    last_received_at = max(COALESCE(last_received_at, 0), excluded.last_received_at),
                    name = COALESCE(excluded.name, name)
                """).execute(arguments: [account, email, clean(from.name), date])
        }
    }

    private static func clean(_ name: String?) -> String? {
        guard let t = name?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
