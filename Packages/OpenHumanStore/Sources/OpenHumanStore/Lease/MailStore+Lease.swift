import Foundation
import GRDB
import OpenHumanCore
#if canImport(Darwin)
import Darwin
#endif

extension MailStore: LeaseStoring {
    public func acquireLease(account: AccountID, ownerID: String, kind: String, pid: Int32, host: String,
                             now: Date, ttl: Duration) throws -> LeaseInfo? {
        let nowMs = Self.millis(now)
        let expires = nowMs + Self.millis(ttl)
        return try write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_lease WHERE account_id = ?",
                                          arguments: [account.rawValue]) {
                let heldBySelf = (row["owner_id"] as String) == ownerID
                let expired = (row["expires_at"] as Int64) <= nowMs
                let deadLocal = (row["host"] as String) == host && !Self.processIsAlive(row["owner_pid"] as Int32)
                guard heldBySelf || expired || deadLocal else { return nil }
                try db.execute(sql: """
                    UPDATE sync_lease SET owner_id = ?, owner_kind = ?, owner_pid = ?, host = ?, acquired_at = ?,
                           heartbeat_at = ?, expires_at = ?, takeover_requested_by = NULL, takeover_requested_at = NULL
                    WHERE account_id = ?
                    """, arguments: [ownerID, kind, pid, host, heldBySelf ? row["acquired_at"] as Int64 : nowMs,
                                     nowMs, expires, account.rawValue])
            } else {
                try db.execute(sql: """
                    INSERT INTO sync_lease (account_id, owner_id, owner_kind, owner_pid, host, acquired_at, heartbeat_at, expires_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [account.rawValue, ownerID, kind, pid, host, nowMs, nowMs, expires])
            }
            return LeaseInfo(ownerID: ownerID, kind: kind, pid: pid, heartbeatAt: now, isLive: true)
        }
    }

    public func renewLease(account: AccountID, ownerID: String, now: Date, ttl: Duration) throws -> Bool {
        let nowMs = Self.millis(now)
        return try write(countsAsActivity: false) { db in
            try db.execute(sql: """
                UPDATE sync_lease SET heartbeat_at = ?, expires_at = ? WHERE account_id = ? AND owner_id = ?
                """, arguments: [nowMs, nowMs + Self.millis(ttl), account.rawValue, ownerID])
            return db.changesCount > 0
        }
    }

    public func releaseLease(account: AccountID, ownerID: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM sync_lease WHERE account_id = ? AND owner_id = ?",
                           arguments: [account.rawValue, ownerID])
        }
    }

    public func requestTakeover(account: AccountID, requesterID: String, now: Date) throws {
        try write { db in
            try db.execute(sql: """
                UPDATE sync_lease SET takeover_requested_by = ?, takeover_requested_at = ?
                WHERE account_id = ? AND owner_id <> ?
                """, arguments: [requesterID, Self.millis(now), account.rawValue, requesterID])
        }
    }

    public func lease(account: AccountID) throws -> LeaseInfo? {
        try read { db in try Self.leaseInfo(account: account.rawValue, in: db) }
    }

    static func leaseInfo(account: Int64, in db: Database) throws -> LeaseInfo? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_lease WHERE account_id = ?",
                                         arguments: [account]) else { return nil }
        let pid: Int32 = row["owner_pid"]
        let sameHost = (row["host"] as String) == ProcessIdentity.localHostName
        let live = (row["expires_at"] as Int64) > nowMillis() && (!sameHost || processIsAlive(pid))
        return LeaseInfo(ownerID: row["owner_id"], kind: row["owner_kind"], pid: pid,
                         heartbeatAt: Date(timeIntervalSince1970: Double(row["heartbeat_at"] as Int64) / 1000),
                         isLive: live)
    }

    func takeoverRequester(account: AccountID) throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT takeover_requested_by FROM sync_lease WHERE account_id = ?",
                                arguments: [account.rawValue])
        }
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func millis(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        #if canImport(Darwin)
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
        #else
        return true
        #endif
    }
}
