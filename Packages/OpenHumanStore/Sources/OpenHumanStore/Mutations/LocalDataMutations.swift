import Foundation
import GRDB
import OpenHumanCore

enum SplitRuleText {
    static func parse(_ text: String) throws -> (rule: SplitRule, canonical: String) {
        let rule = try SplitRule.parse(text)
        return (rule, rule.canonicalText)
    }
}

enum LocalDataMutations {
    private struct WireVariable: Encodable {
        var name: String
        var `default`: String?
    }

    @discardableResult
    static func upsertSnippet(_ s: SnippetItem, in db: Database) throws -> [SnippetAttachment] {
        guard !s.id.isEmpty else { throw StoreError.conflict("snippet id is empty") }
        if let account = s.accountID { try MailStore.requireWritableAccount(account, in: db) }
        try SnippetFiles.validate(s.attachments)
        let shortcut = s.shortcut?.trimmingCharacters(in: .whitespaces)
        if let shortcut, !shortcut.isEmpty,
           let owner = try String.fetchOne(db, sql: "SELECT snippet_id FROM snippets WHERE shortcut = ?", arguments: [shortcut]),
           owner != s.id {
            throw StoreError.conflict("snippet shortcut \(shortcut) is already used")
        }
        let before = try String.fetchOne(db, sql: "SELECT attachments_json FROM snippets WHERE snippet_id = ?", arguments: [s.id])
            .map(SnippetFiles.decode) ?? []
        let wire = s.variables.map { WireVariable(name: $0.name, default: $0.defaultValue) }
        let variables = wire.isEmpty ? "[]" : (try? StoreJSON.encoder.encode(wire)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let now = nowMillis()
        try db.execute(sql: """
            INSERT INTO snippets (snippet_id, account_id, name, shortcut, subject, body_html, variables_json, use_count,
                                  to_json, cc_json, bcc_json, attachments_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (snippet_id) DO UPDATE SET account_id = excluded.account_id, name = excluded.name,
                shortcut = excluded.shortcut, subject = excluded.subject, body_html = excluded.body_html,
                variables_json = excluded.variables_json, to_json = excluded.to_json, cc_json = excluded.cc_json,
                bcc_json = excluded.bcc_json, attachments_json = excluded.attachments_json, updated_at = excluded.updated_at
            """, arguments: [s.id, s.accountID?.rawValue, s.name, (shortcut?.isEmpty ?? true) ? nil : shortcut, s.subject,
                             s.bodyHTML, variables, s.useCount, DraftRowCodec.addresses(s.to), DraftRowCodec.addresses(s.cc),
                             DraftRowCodec.addresses(s.bcc), SnippetFiles.encode(s.attachments), now, now])
        let kept = Set(s.attachments.map(SnippetFiles.key))
        return before.filter { !kept.contains(SnippetFiles.key($0)) }
    }

    @discardableResult
    static func deleteSnippet(id: String, in db: Database) throws -> [SnippetAttachment] {
        let files = try String.fetchOne(db, sql: "SELECT attachments_json FROM snippets WHERE snippet_id = ?", arguments: [id])
            .map(SnippetFiles.decode) ?? []
        try db.execute(sql: "DELETE FROM snippets WHERE snippet_id = ?", arguments: [id])
        return files
    }

    static func recordSnippetUse(id: String, in db: Database) throws {
        try db.execute(sql: "UPDATE snippets SET use_count = use_count + 1, last_used_at = ? WHERE snippet_id = ?",
                       arguments: [nowMillis(), id])
        if db.changesCount == 0 { throw StoreError.notFound("snippet \(id)") }
    }

    static func upsertSplit(account: AccountID, id: SplitID?, name: String, ruleText: String, position: Int?,
                            enabled: Bool, in db: Database) throws -> SplitID {
        try MailStore.requireWritableAccount(account, in: db)
        let a = account.rawValue
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw StoreError.conflict("split name is empty") }
        let now = nowMillis()
        let existing = try id.flatMap {
            try Row.fetchOne(db, sql: "SELECT * FROM splits WHERE split_id = ? AND account_id = ?", arguments: [$0.rawValue, a])
        }
        if let clash = try String.fetchOne(db, sql: "SELECT split_id FROM splits WHERE account_id = ? AND name = ?",
                                           arguments: [a, title]), clash != existing?["split_id"] {
            throw StoreError.conflict("a split named \(title) already exists")
        }
        if let existing {
            let splitID: String = existing["split_id"]
            var ruleColumns: [(String, DatabaseValue)] = []
            if ruleText != (existing["rule_text"] as String) {
                let parsed = try SplitRuleText.parse(ruleText)
                ruleColumns = [("rule_text", parsed.canonical.databaseValue), ("rule_json", try ruleJSON(parsed.rule).databaseValue)]
            }
            let columns: [(String, DatabaseValue)] = ruleColumns + [
                ("name", title.databaseValue), ("enabled", enabled.databaseValue),
                ("position", (position ?? existing["position"] as Int).databaseValue), ("updated_at", now.databaseValue),
            ]
            try db.execute(sql: "UPDATE splits SET \(columns.map { "\($0.0) = ?" }.joined(separator: ", ")) WHERE split_id = ?",
                           arguments: StatementArguments(columns.map(\.1) + [splitID.databaseValue]))
            try db.execute(sql: """
                UPDATE labels SET name = ?, display_name = ?, position = ?, updated_at = ? WHERE label_rid = ?
                """, arguments: [title, title, position ?? existing["position"] as Int, now, existing["label_rid"] as Int64])
            try ThreadAggregator.reevaluateSplits(account: a, in: db)
            return SplitID(splitID)
        }
        let parsed = try SplitRuleText.parse(ruleText)
        let splitID = id?.rawValue ?? UUID().uuidString
        let pos = try position ?? (Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position) + 1, 0) FROM splits WHERE account_id = ?",
                                                arguments: [a]) ?? 0)
        try db.execute(sql: """
            INSERT INTO labels (account_id, key, kind, name, display_name, position, updated_at)
            VALUES (?, ?, 'split', ?, ?, ?, ?)
            """, arguments: [a, "oh:split:" + splitID, title, title, pos, now])
        let labelRid = db.lastInsertedRowID
        try db.execute(sql: """
            INSERT INTO splits (split_id, account_id, label_rid, name, position, rule_text, rule_json, enabled, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [splitID, a, labelRid, title, pos, parsed.canonical, try ruleJSON(parsed.rule), enabled, now, now])
        try ThreadAggregator.reevaluateSplits(account: a, in: db)
        return SplitID(splitID)
    }

    static func deleteSplit(_ id: SplitID, in db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT account_id, label_rid FROM splits WHERE split_id = ?",
                                         arguments: [id.rawValue]) else { return }
        try db.execute(sql: "DELETE FROM labels WHERE label_rid = ?", arguments: [row["label_rid"] as Int64])
        try ThreadAggregator.reevaluateSplits(account: row["account_id"], in: db)
    }

    static func reorderSplits(account: AccountID, _ ids: [SplitID], in db: Database) throws {
        let a = account.rawValue
        let current = try String.fetchAll(db, sql: "SELECT split_id FROM splits WHERE account_id = ? ORDER BY position, created_at",
                                          arguments: [a])
        let known = Set(current)
        if let unknown = ids.first(where: { !known.contains($0.rawValue) }) {
            throw StoreError.notFound("split \(unknown.rawValue)")
        }
        var seen = Set<String>()
        let order = (ids.map(\.rawValue) + current).filter { seen.insert($0).inserted }
        let now = nowMillis()
        for (position, splitID) in order.enumerated() {
            try db.execute(sql: "UPDATE splits SET position = ?, updated_at = ? WHERE split_id = ?",
                           arguments: [position, now, splitID])
            try db.execute(sql: """
                UPDATE labels SET position = ?, updated_at = ? WHERE label_rid = (SELECT label_rid FROM splits WHERE split_id = ?)
                """, arguments: [position, now, splitID])
        }
        try ThreadAggregator.reevaluateSplits(account: a, in: db)
    }

    private static func ruleJSON(_ rule: SplitRule) throws -> String {
        String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
    }
}

extension MailStore {
    public func upsertSnippet(_ s: SnippetItem) throws {
        if !s.attachments.isEmpty { try requireSnippetFiles(s.attachments) }
        let dropped = try write { db in try LocalDataMutations.upsertSnippet(s, in: db) }
        if !dropped.isEmpty || !s.attachments.isEmpty { removeUnreferencedSnippetFiles(dropped) }
    }

    public func deleteSnippet(id: String) throws {
        let files = try write { db in try LocalDataMutations.deleteSnippet(id: id, in: db) }
        removeUnreferencedSnippetFiles(files)
    }

    public func recordSnippetUse(id: String) throws {
        try write { db in try LocalDataMutations.recordSnippetUse(id: id, in: db) }
    }

    public func upsertSplit(account: AccountID, id: SplitID?, name: String, ruleText: String, position: Int?,
                            enabled: Bool) throws -> SplitID {
        try write { db in
            try LocalDataMutations.upsertSplit(account: account, id: id, name: name, ruleText: ruleText, position: position,
                                               enabled: enabled, in: db)
        }
    }

    public func deleteSplit(_ id: SplitID) throws {
        try write { db in try LocalDataMutations.deleteSplit(id, in: db) }
    }

    public func reorderSplits(account: AccountID, _ ids: [SplitID]) throws {
        try write { db in try LocalDataMutations.reorderSplits(account: account, ids, in: db) }
    }
}
