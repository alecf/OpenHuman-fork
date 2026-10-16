import Foundation
import GRDB
import OpenHumanCore

private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
private func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

extension MailStore: ImportanceRulesStoring {
    public func importanceRules(account: AccountID?) throws -> [ImportanceRule] {
        try read { db in try Self.importanceRuleItems(account: account, in: db) }
    }

    public func observeImportanceRules(account: AccountID?) -> StoreObservation<[ImportanceRule]> {
        observe { db in try Self.importanceRuleItems(account: account, in: db) }
    }

    public func addImportanceRule(_ definition: ImportanceRuleDefinition) throws -> ImportanceRuleReceipt {
        try write { db in try ImportanceRuleWriter.add(definition, in: db) }
    }

    public func updateImportanceRule(_ id: ImportanceRuleID, to definition: ImportanceRuleDefinition) throws -> ImportanceRuleReceipt {
        try write { db in try ImportanceRuleWriter.update(id, to: definition, in: db) }
    }

    public func deleteImportanceRules(_ ids: [ImportanceRuleID]) throws -> ImportanceRuleReceipt {
        try write { db in try ImportanceRuleWriter.delete(ids, in: db) }
    }

    public func undoImportanceRuleEdit(_ receipt: ImportanceRuleReceipt) throws -> ImportanceRuleReceipt? {
        guard receipt.undo != nil else { return nil }
        return try write { db in try ImportanceRuleWriter.undo(receipt, in: db) }
    }

    public func setImportanceSplit(account: AccountID, _ id: SplitID?) throws {
        try write { db in try ImportanceRuleWriter.setImportanceSplit(account: account, id, in: db) }
    }

    public func importanceReason(_ thread: ThreadRef) throws -> ImportanceReason {
        try read { db in try Self.importanceReason(thread, in: db) }
    }

    public func importanceCounts(account: AccountID) throws -> ImportanceCounts {
        try read { db in try Self.importanceCounts(account: account, in: db) }
    }

    public func observeImportanceCounts(account: AccountID) -> StoreObservation<ImportanceCounts> {
        observe { db in try Self.importanceCounts(account: account, in: db) }
    }

    public func exportImportanceRules(account: AccountID?) throws -> ImportanceRulesDocument {
        try read { db in try Self.exportedRules(account: account, in: db) }
    }

    public func importImportanceRules(_ document: ImportanceRulesDocument, dryRun: Bool) throws -> ImportanceImportSummary {
        guard document.version == 1 else {
            throw StoreError.conflict("importance rules version \(document.version) is not supported")
        }
        struct DryRun: Error { var summary: ImportanceImportSummary }
        do {
            return try write { db in
                let summary = try ImportanceRuleWriter.importRules(document, in: db)
                if dryRun { throw DryRun(summary: ImportanceImportSummary(added: summary.added, replaced: summary.replaced,
                                                                           unchanged: summary.unchanged, skipped: summary.skipped)) }
                return summary
            }
        } catch let dry as DryRun {
            return dry.summary
        }
    }

    public func reevaluateImportance(account: AccountID?) throws {
        try write { db in try ImportanceRuleWriter.reevaluate(accounts: [account], in: db) }
    }
}

extension MailStore {
    static func importanceRule(_ r: Row) -> ImportanceRule? {
        guard let kind = ImportanceMatchKind(rawValue: r["kind"]), let effect = ImportanceEffect(rawValue: r["effect"]),
              let source = ImportanceRuleSource(rawValue: r["source"]) else { return nil }
        let account: Int64? = r["account_id"]
        let split: String? = r["split_id"]
        return ImportanceRule(
            id: ImportanceRuleID(rawValue: r["rule_rid"]),
            definition: ImportanceRuleDefinition(accountID: account.map { AccountID($0) }, kind: kind, value: r["value"],
                                                 effect: effect, splitID: split.map { SplitID($0) }, source: source),
            createdAt: date(r["created_at"]), updatedAt: date(r["updated_at"]))
    }

    static func importanceRuleItems(account: AccountID?, in db: Database) throws -> [ImportanceRule] {
        let rows: [Row]
        if let account {
            rows = try Row.fetchAll(db, sql: """
                SELECT * FROM importance_rules WHERE account_id = ? OR account_id IS NULL
                ORDER BY created_at DESC, rule_rid DESC
                """, arguments: [account.rawValue])
        } else {
            rows = try Row.fetchAll(db, sql: "SELECT * FROM importance_rules ORDER BY created_at DESC, rule_rid DESC")
        }
        return rows.compactMap(importanceRule)
    }

    static func importanceCounts(account: AccountID, in db: Database) throws -> ImportanceCounts {
        var counts = ImportanceCounts(accountID: account, important: 0, importantUnread: 0, normal: 0, suppressed: 0)
        for r in try Row.fetchAll(db, sql: """
            SELECT importance, count(*) AS n, sum(unread_count > 0) AS u FROM threads
            WHERE account_id = ? AND in_inbox = 1 GROUP BY importance
            """, arguments: [account.rawValue]) {
            let n: Int = r["n"], u: Int = r["u"]
            switch ThreadImportance(rawValue: r["importance"]) {
            case .important: counts.important = n; counts.importantUnread = u
            case .normal: counts.normal = n
            case .suppressed: counts.suppressed = n
            case nil: break
            }
        }
        return counts
    }

    static func importanceReason(_ ref: ThreadRef, in db: Database) throws -> ImportanceReason {
        let row = try requireThread(ref, in: db)
        let tid = ref.rowID.rawValue
        let context = try AggregationContext.load(account: ref.accountID.rawValue, in: db)
        let visible = try ThreadAggregator.loadMessages(tid: tid, in: db).filter(\.visible)
        let live = ImportanceEvaluator.place(try ThreadAggregator.placementFacts(visible: visible, tid: tid,
                                                                                 gmailThreadID: row["gmail_thread_id"],
                                                                                 context: context, in: db),
                                             context: context)
        let inInbox: Bool = row["in_inbox"]
        var splits: [Int64: (id: String, name: String, ruleText: String, isImportance: Bool)] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT split_id, label_rid, name, rule_text, role FROM splits WHERE account_id = ?",
                                  arguments: [ref.accountID.rawValue]) {
            let role: String? = r["role"]
            splits[r["label_rid"]] = (r["split_id"], r["name"], r["rule_text"], role == "important")
        }

        let importance: ThreadImportance
        let reasonRid: Int64?
        var placementID: SplitID?
        var placementName = ""
        var chips: [SplitID] = []
        if inInbox {
            importance = ThreadImportance(rawValue: row["importance"]) ?? .normal
            reasonRid = row["importance_reason_rid"]
            let splitRid: Int64? = row["split_rid"]
            if let splitRid, let split = splits[splitRid] {
                placementID = SplitID(split.id)
                placementName = split.name
            } else {
                placementName = try String.fetchOne(db, sql: "SELECT name FROM labels WHERE account_id = ? AND key = 'oh:split:other'",
                                                    arguments: [ref.accountID.rawValue]) ?? "Other"
            }
            chips = (row["split_chip_rids"] as String).split(separator: ",").compactMap { Int64($0) }
                .compactMap { splits[$0].map { SplitID($0.id) } }
        } else {
            importance = live.importance
            reasonRid = live.reasonRid
        }

        var basis = ImportanceBasis.none
        var rule: ImportanceRule?
        var splitRuleText: String?
        if let reasonRid {
            rule = try fetchImportanceRule(reasonRid, in: db)
            basis = rule == nil ? .none : .rule
        } else if importance == .important {
            basis = .importanceSplit
            splitRuleText = context.importanceSplit.flatMap { splits[$0.labelRid]?.ruleText }
        }
        let exemptions = try live.exemptionRids.compactMap { try fetchImportanceRule($0, in: db) }
        let sender = visible.last { !$0.isFromMe && $0.fromEmail != nil }?.fromEmail?.lowercased()
        return ImportanceReason(thread: ref, importance: importance, basis: basis, rule: rule,
                                importanceSplitRuleText: splitRuleText, isInInbox: inInbox, placementSplitID: placementID,
                                placementName: placementName, chipSplitIDs: chips, exemptions: exemptions, sender: sender,
                                gmailImportant: row["is_important"] as Bool)
    }

    static func fetchImportanceRule(_ rid: Int64, in db: Database) throws -> ImportanceRule? {
        try Row.fetchOne(db, sql: "SELECT * FROM importance_rules WHERE rule_rid = ?", arguments: [rid]).flatMap(importanceRule)
    }

    static func exportedRules(account: AccountID?, in db: Database) throws -> ImportanceRulesDocument {
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.*, a.email AS account_email, s.name AS split_name FROM importance_rules r
            LEFT JOIN accounts a ON a.account_id = r.account_id LEFT JOIN splits s ON s.split_id = r.split_id
            WHERE ?1 IS NULL OR r.account_id = ?1 OR r.account_id IS NULL
            ORDER BY r.rule_rid
            """, arguments: [account?.rawValue])
        return ImportanceRulesDocument(rules: rows.compactMap { r in
            guard let rule = importanceRule(r) else { return nil }
            let d = rule.definition
            return ExportedImportanceRule(account: r["account_email"], kind: d.kind, value: d.value, effect: d.effect,
                                          split: r["split_name"], source: d.source, createdAt: rule.createdAt)
        })
    }
}

enum ImportanceRuleWriter {
    static func validate(_ definition: ImportanceRuleDefinition, in db: Database) throws -> ImportanceRuleDefinition {
        var d = definition
        d.value = try ImportanceRuleValue.normalize(d.kind, d.value)
        if let account = d.accountID { try MailStore.requireWritableAccount(account, in: db) }
        if let split = d.splitID {
            guard d.effect == .exemptFromSplit else { throw StoreError.conflict("only an exemption names a split") }
            guard let account = d.accountID else { throw StoreError.conflict("an exemption from a split needs an account") }
            guard let row = try Row.fetchOne(db, sql: "SELECT role FROM splits WHERE split_id = ? AND account_id = ?",
                                             arguments: [split.rawValue, account.rawValue]) else {
                throw StoreError.notFound("split \(split.rawValue)")
            }
            if (row["role"] as String?) == "important" {
                throw StoreError.conflict("the importance split cannot be exempted from; use never important")
            }
        }
        return d
    }

    static func colliding(_ definition: ImportanceRuleDefinition, excluding: Int64? = nil,
                          in db: Database) throws -> [ImportanceRule] {
        try Row.fetchAll(db, sql: """
            SELECT * FROM importance_rules WHERE COALESCE(account_id, 0) = ? AND kind = ? AND value = ? AND source = ?
            ORDER BY rule_rid
            """, arguments: [definition.accountID?.rawValue ?? 0, definition.kind.rawValue, definition.value,
                             definition.source.rawValue])
            .compactMap(MailStore.importanceRule)
            .filter { $0.id.rawValue != excluding && keyGroup($0.definition) == keyGroup(definition) }
    }

    static func keyGroup(_ d: ImportanceRuleDefinition) -> String {
        d.effect == .exemptFromSplit ? "x:" + (d.splitID?.rawValue ?? "*") : "i"
    }

    static func add(_ definition: ImportanceRuleDefinition, in db: Database) throws -> ImportanceRuleReceipt {
        let d = try validate(definition, in: db)
        let collisions = try colliding(d, in: db)
        if let same = collisions.first(where: { $0.definition == d }) {
            return ImportanceRuleReceipt(ruleIDs: [same.id], undo: nil)
        }
        for rule in collisions { try deleteRow(rule.id, in: db) }
        let rule = try insertNew(d, createdAt: nowMillis(), in: db)
        try reevaluate(accounts: Set([d.accountID] + collisions.map(\.definition.accountID)), in: db)
        return ImportanceRuleReceipt(ruleIDs: [rule.id], undo: ImportanceRuleEdit(insert: collisions, delete: [rule]))
    }

    static func update(_ id: ImportanceRuleID, to definition: ImportanceRuleDefinition,
                       in db: Database) throws -> ImportanceRuleReceipt {
        guard let old = try MailStore.fetchImportanceRule(id.rawValue, in: db) else {
            throw StoreError.notFound("importance rule \(id.rawValue)")
        }
        let d = try validate(definition, in: db)
        if d == old.definition { return ImportanceRuleReceipt(ruleIDs: [id], undo: nil) }
        let collisions = try colliding(d, excluding: id.rawValue, in: db)
        for rule in collisions { try deleteRow(rule.id, in: db) }
        try db.execute(sql: """
            UPDATE importance_rules SET account_id = ?, kind = ?, value = ?, effect = ?, split_id = ?, source = ?,
                   updated_at = ? WHERE rule_rid = ?
            """, arguments: [d.accountID?.rawValue, d.kind.rawValue, d.value, d.effect.rawValue, d.splitID?.rawValue,
                             d.source.rawValue, max(nowMillis(), millis(old.updatedAt) + 1), id.rawValue])
        guard let new = try MailStore.fetchImportanceRule(id.rawValue, in: db) else {
            throw StoreError.integrity("importance rule \(id.rawValue) vanished")
        }
        try reevaluate(accounts: Set([old.definition.accountID, d.accountID] + collisions.map(\.definition.accountID)), in: db)
        return ImportanceRuleReceipt(ruleIDs: [id], undo: ImportanceRuleEdit(insert: [old] + collisions, delete: [new]))
    }

    static func delete(_ ids: [ImportanceRuleID], in db: Database) throws -> ImportanceRuleReceipt {
        var seen = Set<ImportanceRuleID>()
        let rows = try ids.filter { seen.insert($0).inserted }.compactMap { try MailStore.fetchImportanceRule($0.rawValue, in: db) }
        guard !rows.isEmpty else { return ImportanceRuleReceipt(ruleIDs: [], undo: nil) }
        for rule in rows { try deleteRow(rule.id, in: db) }
        try reevaluate(accounts: Set(rows.map(\.definition.accountID)), in: db)
        return ImportanceRuleReceipt(ruleIDs: [], undo: ImportanceRuleEdit(insert: rows, delete: []))
    }

    static func undo(_ receipt: ImportanceRuleReceipt, in db: Database) throws -> ImportanceRuleReceipt? {
        guard let edit = receipt.undo, try apply(edit, in: db) else { return nil }
        return ImportanceRuleReceipt(ruleIDs: edit.insert.map(\.id), undo: ImportanceRuleEdit(insert: edit.delete, delete: edit.insert))
    }

    static func apply(_ edit: ImportanceRuleEdit, in db: Database) throws -> Bool {
        for rule in edit.delete {
            guard let current = try MailStore.fetchImportanceRule(rule.id.rawValue, in: db), sameRow(current, rule) else { return false }
        }
        let deleting = Set(edit.delete.map(\.id))
        var keys = Set<String>()
        for rule in edit.insert {
            let d = rule.definition
            if !deleting.contains(rule.id), try MailStore.fetchImportanceRule(rule.id.rawValue, in: db) != nil { return false }
            if let account = d.accountID,
               try Int.fetchOne(db, sql: "SELECT 1 FROM accounts WHERE account_id = ?", arguments: [account.rawValue]) == nil {
                return false
            }
            if let split = d.splitID, try Int.fetchOne(db, sql: "SELECT 1 FROM splits WHERE split_id = ? AND account_id = ?",
                                                       arguments: [split.rawValue, d.accountID?.rawValue]) == nil {
                return false
            }
            let key = "\(d.accountID?.rawValue ?? 0)|\(d.kind.rawValue)|\(d.value)|\(d.source.rawValue)|\(keyGroup(d))"
            guard keys.insert(key).inserted else { return false }
            if try colliding(d, in: db).contains(where: { !deleting.contains($0.id) }) { return false }
        }
        for rule in edit.delete { try deleteRow(rule.id, in: db) }
        for rule in edit.insert { try insertExact(rule, in: db) }
        try reevaluate(accounts: Set((edit.insert + edit.delete).map(\.definition.accountID)), in: db)
        return true
    }

    static func setImportanceSplit(account: AccountID, _ id: SplitID?, in db: Database) throws {
        try MailStore.requireWritableAccount(account, in: db)
        if let id, try Int.fetchOne(db, sql: "SELECT 1 FROM splits WHERE split_id = ? AND account_id = ?",
                                    arguments: [id.rawValue, account.rawValue]) == nil {
            throw StoreError.notFound("split \(id.rawValue)")
        }
        let now = nowMillis()
        try db.execute(sql: "UPDATE splits SET role = NULL, updated_at = ? WHERE account_id = ? AND role = 'important'",
                       arguments: [now, account.rawValue])
        if let id {
            try db.execute(sql: "UPDATE splits SET role = 'important', updated_at = ? WHERE split_id = ?", arguments: [now, id.rawValue])
        }
        try ThreadAggregator.reevaluateSplits(account: account.rawValue, in: db)
    }

    static func importRules(_ document: ImportanceRulesDocument, in db: Database) throws -> ImportanceImportSummary {
        var summary = ImportanceImportSummary(added: 0, replaced: 0, unchanged: 0, skipped: 0)
        var inserted: [ImportanceRuleID] = []
        var deletedOriginals: [ImportanceRule] = []
        var touched = Set<AccountID?>()
        for entry in document.rules {
            var accountID: AccountID?
            if let email = entry.account {
                guard let id = try Int64.fetchOne(db, sql: "SELECT account_id FROM accounts WHERE email = ?", arguments: [email]) else {
                    summary.skipped += 1
                    continue
                }
                accountID = AccountID(id)
            }
            var splitID: SplitID?
            if let name = entry.split {
                guard let accountID, let id = try String.fetchOne(db, sql: "SELECT split_id FROM splits WHERE account_id = ? AND name = ?",
                                                                  arguments: [accountID.rawValue, name]) else {
                    summary.skipped += 1
                    continue
                }
                splitID = SplitID(id)
            }
            let definition = ImportanceRuleDefinition(accountID: accountID, kind: entry.kind, value: entry.value,
                                                      effect: entry.effect, splitID: splitID, source: entry.source)
            guard let d = try? validate(definition, in: db) else {
                summary.skipped += 1
                continue
            }
            let collisions = try colliding(d, in: db)
            if collisions.contains(where: { $0.definition == d }) {
                summary.unchanged += 1
                continue
            }
            for rule in collisions {
                try deleteRow(rule.id, in: db)
                if let i = inserted.firstIndex(of: rule.id) { inserted.remove(at: i) } else { deletedOriginals.append(rule) }
            }
            let rule = try insertNew(d, createdAt: millis(entry.createdAt), in: db)
            inserted.append(rule.id)
            touched.insert(d.accountID)
            if collisions.isEmpty { summary.added += 1 } else { summary.replaced += 1 }
        }
        guard !inserted.isEmpty || !deletedOriginals.isEmpty else { return summary }
        try reevaluate(accounts: touched.union(deletedOriginals.map(\.definition.accountID)), in: db)
        let insertedRows = try inserted.compactMap { try MailStore.fetchImportanceRule($0.rawValue, in: db) }
        summary.receipt = ImportanceRuleReceipt(ruleIDs: inserted, undo: ImportanceRuleEdit(insert: deletedOriginals, delete: insertedRows))
        return summary
    }

    static func reevaluate(accounts: Set<AccountID?>, in db: Database) throws {
        let ids: [Int64]
        if accounts.contains(where: { $0 == nil }) {
            ids = try Int64.fetchAll(db, sql: "SELECT account_id FROM accounts ORDER BY account_id")
        } else {
            ids = accounts.compactMap { $0?.rawValue }.sorted()
        }
        for id in ids { try ThreadAggregator.reevaluateSplits(account: id, in: db) }
    }

    private static func sameRow(_ a: ImportanceRule, _ b: ImportanceRule) -> Bool {
        a.id == b.id && a.definition == b.definition && millis(a.createdAt) == millis(b.createdAt)
            && millis(a.updatedAt) == millis(b.updatedAt)
    }

    private static func insertNew(_ d: ImportanceRuleDefinition, createdAt: Int64, in db: Database) throws -> ImportanceRule {
        let now = nowMillis()
        try db.execute(sql: """
            INSERT INTO importance_rules (account_id, kind, value, effect, split_id, source, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [d.accountID?.rawValue, d.kind.rawValue, d.value, d.effect.rawValue, d.splitID?.rawValue,
                             d.source.rawValue, createdAt, now])
        return ImportanceRule(id: ImportanceRuleID(rawValue: db.lastInsertedRowID), definition: d, createdAt: date(createdAt),
                              updatedAt: date(now))
    }

    private static func insertExact(_ rule: ImportanceRule, in db: Database) throws {
        let d = rule.definition
        try db.execute(sql: """
            INSERT INTO importance_rules (rule_rid, account_id, kind, value, effect, split_id, source, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [rule.id.rawValue, d.accountID?.rawValue, d.kind.rawValue, d.value, d.effect.rawValue,
                             d.splitID?.rawValue, d.source.rawValue, millis(rule.createdAt), millis(rule.updatedAt)])
    }

    private static func deleteRow(_ id: ImportanceRuleID, in db: Database) throws {
        try db.execute(sql: "DELETE FROM importance_rules WHERE rule_rid = ?", arguments: [id.rawValue])
    }
}
