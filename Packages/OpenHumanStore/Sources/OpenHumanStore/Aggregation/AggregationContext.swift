import Foundation
import GRDB
import OpenHumanCore

struct AggregationContext {
    struct LabelInfo {
        var rid: Int64
        var key: String
        var kind: String
        var name: String
        var hidden: Bool
    }

    struct Split {
        var labelRid: Int64
        var rule: SplitRule?
        var splitID: String = ""
        var isImportance = false
    }

    struct ImportanceRuleRow {
        var rid: Int64
        var kind: ImportanceMatchKind
        var value: String
        var effect: ImportanceEffect
        var splitID: String?
        var source: ImportanceRuleSource
        var labelKeys: Set<String> = []
        var matcher: (any ImportanceMatcher)?
        var argument = ""
        var isThreadRule = false

        var order: (Int, Int, Int, Int64) {
            (source == .user ? 0 : 1, isThreadRule ? Self.threadRank : Self.kindRank(kind), effect == .neverImportant ? 0 : 1, rid)
        }

        static let threadRank = 1

        static func kindRank(_ kind: ImportanceMatchKind) -> Int {
            switch kind {
            case .sender: 0
            case .domain: 2
            case .label: 3
            case .keyword: 4
            case .matcher: 5
            }
        }
    }

    let account: Int64
    let byKey: [String: LabelInfo]
    let ridByKey: [String: Int64]
    let keyByName: [String: String]
    let me: Set<String>
    let splits: [Split]
    let otherSplitRid: Int64?
    var hasPendingAddNames = true
    var importanceRules: [ImportanceRuleRow] = []
    var exemptionRules: [ImportanceRuleRow] = []
    var readsText = false
    var hasMatcherRules = false
    var readsSenders = false
    private(set) var importanceSplit: Split?
    var alsoShowInInboxRids: Set<Int64> = []
    var eventSplitRids: Set<Int64> = []
    var eventLabelKeys: Set<String> = []
    var superhumanReminders = SuperhumanReminderRule()
    var waitingOverrides: [Int64: String] = [:]
    var waitingLabelKeys: Set<String> = []

    private static let log = Log(.store)

    static func load(account: Int64, in db: Database) throws -> AggregationContext {
        var byKey: [String: LabelInfo] = [:]
        var keyByName: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT label_rid, key, kind, name, is_hidden FROM labels WHERE account_id = ?
            """, arguments: [account]) {
            let info = LabelInfo(rid: row["label_rid"], key: row["key"], kind: row["kind"], name: row["name"],
                                 hidden: row["is_hidden"])
            byKey[info.key] = info
            if info.kind != "virtual" && info.kind != "split" { keyByName[info.name] = info.key }
        }
        var splits: [Split] = []
        for row in try Row.fetchAll(db, sql: """
            SELECT split_id, label_rid, rule_json, role FROM splits WHERE account_id = ? AND enabled = 1
            ORDER BY position, created_at, split_id
            """, arguments: [account]) {
            let json: String = row["rule_json"]
            let rule = try? JSONDecoder().decode(SplitRule.self, from: Data(json.utf8))
            if rule == nil { log.error("split rule_json does not decode (account \(account)); the split matches nothing") }
            let role: String? = row["role"]
            splits.append(Split(labelRid: row["label_rid"], rule: rule, splitID: row["split_id"], isImportance: role == "important"))
        }
        var context = AggregationContext(account: account, byKey: byKey, ridByKey: byKey.mapValues(\.rid),
                                         keyByName: keyByName, me: try ThreadAggregator.myAddresses(account: account, in: db),
                                         splits: splits, otherSplitRid: byKey["oh:split:other"]?.rid)
        context.hasPendingAddNames = try Bool.fetchOne(db.cached("""
            SELECT EXISTS (SELECT 1 FROM pending_operations
                           WHERE account_id = ? AND status IN ('pending', 'in_flight') AND kind = 'modify_labels'
                             AND instr(payload_json, '"addNames"') > 0)
            """), arguments: [account]) ?? true
        context.importanceSplit = splits.first(where: \.isImportance)
        let alsoShow = try alsoShowSplitIDs(account: account, in: db)
        if !alsoShow.isEmpty {
            context.alsoShowInInboxRids = Set(splits.filter { alsoShow.contains($0.splitID) && !$0.isImportance }.map(\.labelRid))
        }
        context.eventSplitRids = Set(splits.filter { !$0.isImportance && ($0.rule?.isEventsOnlyRule ?? false) }.map(\.labelRid))
        context.eventLabelKeys = Set(byKey.values.filter { $0.kind != "split" && $0.kind != "virtual"
            && EventMailSignals.isEventLabelName($0.name) }.map(\.key))
        try context.loadImportanceRules(in: db)
        context.superhumanReminders = try SuperhumanReminderRule.load(account: account, in: db)
        context.waitingOverrides = try WaitingRule.overrides(account: account, in: db)
        context.waitingLabelKeys = WaitingRule.waitingLabelKeys(keyByName: keyByName)
        return context
    }

    static func alsoShowSplitIDs(account: Int64, in db: Database) throws -> Set<String> {
        guard let json = try String.fetchOne(db.cached("SELECT value_json FROM settings WHERE scope = ? AND key = ?"),
                                             arguments: [MailStore.scopeString(.account(AccountID(account))),
                                                         SettingKey<[String]>.alsoShowSplitInInbox.name]),
              let ids = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return Set(ids)
    }

    mutating func loadImportanceRules(in db: Database) throws {
        var rules: [ImportanceRuleRow] = []
        var exemptions: [ImportanceRuleRow] = []
        var unknownMatchers = Set<String>()
        let matcher = LabelMatcher(context: self)
        for row in try Row.fetchAll(db.cached("""
            SELECT rule_rid, kind, value, effect, split_id, source FROM importance_rules
            WHERE account_id = ? OR account_id IS NULL
            """), arguments: [account]) {
            guard let kind = ImportanceMatchKind(rawValue: row["kind"]), let effect = ImportanceEffect(rawValue: row["effect"]),
                  let source = ImportanceRuleSource(rawValue: row["source"]) else { continue }
            var rule = ImportanceRuleRow(rid: row["rule_rid"], kind: kind, value: row["value"], effect: effect,
                                         splitID: row["split_id"], source: source)
            switch kind {
            case .label:
                rule.labelKeys = matcher.keys(matching: rule.value)
            case .keyword:
                readsText = true
            case .matcher:
                hasMatcherRules = true
                let (id, argument) = ImportanceRuleValue.matcherParts(rule.value)
                rule.argument = argument
                rule.isThreadRule = id == ThreadImportanceMatcher.matcherID
                rule.matcher = ImportanceMatchers.matcher(id: id)
                if let m = rule.matcher { if m.readsText { readsText = true } } else { unknownMatchers.insert(id) }
            case .sender, .domain:
                readsSenders = true
            }
            if effect == .exemptFromSplit { exemptions.append(rule) } else { rules.append(rule) }
        }
        if !unknownMatchers.isEmpty {
            Self.log.error("importance rules name \(unknownMatchers.count) unregistered matcher(s) (account \(account)); they match nothing")
        }
        importanceRules = rules.sorted { $0.order < $1.order }
        exemptionRules = exemptions.sorted { $0.order < $1.order }
    }

    func names(of keys: Set<String>) -> [String] {
        keys.compactMap { byKey[$0]?.name }
    }
}

enum LabelVisibility {
    static func isHidden(name: String) -> Bool {
        switch ScheduleLabel.parse(name) {
        case .schedule, .marker: return true
        case .malformed, .notOurs: return false
        }
    }
}
