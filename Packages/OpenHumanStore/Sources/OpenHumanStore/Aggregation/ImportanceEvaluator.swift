import Foundation
import GRDB
import OpenHumanCore

struct Placement: Equatable {
    var importance: ThreadImportance = .normal
    var reasonRid: Int64?
    var splitRid: Int64?
    var chipRids: [Int64] = []
    var exemptionRids: [Int64] = []

    var chipText: String { chipRids.map(String.init).joined(separator: ",") }
}

enum ImportanceEvaluator {
    static func place(_ facts: SplitFacts, context: AggregationContext) -> Placement {
        var placement = Placement()
        guard !facts.messages.isEmpty else { return placement }
        let labels = LabelMatcher(context: context)
        var publicFacts: ImportanceFacts?
        func ruleMatches(_ rule: AggregationContext.ImportanceRuleRow) -> Bool {
            guard rule.kind == .matcher else { return matches(rule, facts) }
            if rule.isThreadRule { return !rule.argument.isEmpty && facts.gmailThreadID == rule.argument }
            guard let matcher = rule.matcher else { return false }
            if publicFacts == nil { publicFacts = makeFacts(facts, account: context.account, withText: context.readsText) }
            guard let publicFacts else { return false }
            return matcher.matches(publicFacts, argument: rule.argument)
        }

        if let rule = context.importanceRules.first(where: ruleMatches) {
            placement.importance = rule.effect == .neverImportant ? .suppressed : .important
            placement.reasonRid = rule.rid
        } else if let rule = context.importanceSplit?.rule, SplitEvaluator.matches(rule, facts, labels) {
            placement.importance = .important
        }

        var exemptAll = false
        var exempt = Set<String>()
        for rule in context.exemptionRules where ruleMatches(rule) {
            placement.exemptionRids.append(rule.rid)
            if let split = rule.splitID { exempt.insert(split) } else { exemptAll = true }
        }
        let important = placement.importance == .important
        if important { placement.splitRid = context.importanceSplit?.labelRid }
        guard !exemptAll else { return placement }
        var holderChosen = important
        for split in context.splits where !split.isImportance && !exempt.contains(split.splitID) {
            guard let rule = split.rule, SplitEvaluator.matches(rule, facts, labels) else { continue }
            if holderChosen {
                placement.chipRids.append(split.labelRid)
            } else {
                placement.splitRid = split.labelRid
                holderChosen = true
            }
        }
        return placement
    }

    static func matches(_ rule: AggregationContext.ImportanceRuleRow, _ facts: SplitFacts) -> Bool {
        switch rule.kind {
        case .sender:
            return facts.messages.contains { m in !m.isFromMe && m.fromLower == rule.value }
        case .domain:
            return facts.messages.contains { m in
                !m.isFromMe && (m.fromLower.map { ImportanceRuleValue.domain(ofLowercased: $0, matches: rule.value) } ?? false)
            }
        case .keyword:
            return facts.messages.contains { m in
                guard !m.isFromMe, let text = m.text else { return false }
                return TextSearch.contains(text.foldedSubject, rule.value) || TextSearch.contains(text.foldedBody, rule.value)
            }
        case .label:
            return !rule.labelKeys.isEmpty && facts.messages.contains { !$0.labels.isDisjoint(with: rule.labelKeys) }
        case .matcher:
            return false
        }
    }

    static func makeFacts(_ facts: SplitFacts, account: Int64, withText: Bool) -> ImportanceFacts {
        let ordered = facts.messages.sorted { ($0.internalDate, $0.mid) < ($1.internalDate, $1.mid) }
        return ImportanceFacts(accountID: AccountID(account), messages: ordered.map { m in
            ImportanceMessageFacts(
                from: m.fromEmail.map { EmailAddress(name: m.fromName, email: $0) },
                to: WireAddress.decode(m.toJSON).map { EmailAddress(name: $0.n, email: $0.e) },
                cc: WireAddress.decode(m.ccJSON).map { EmailAddress(name: $0.n, email: $0.e) },
                date: Date(timeIntervalSince1970: Double(m.internalDate) / 1000), isFromMe: m.isFromMe,
                isUnread: m.isUnread, labelIDs: m.labels.sorted().map { GmailLabelID($0) },
                subject: m.text?.subject ?? SearchTextNormalizer.normalizeField(m.subject),
                text: withText ? m.text?.body : nil)
        }, threadID: facts.gmailThreadID.map { GmailThreadID($0) })
    }
}

enum ImportanceText {
    struct Text: Equatable {
        var subject: String
        var body: String
        var foldedSubject: String
        var foldedBody: String
    }

    private static let columns = "m.mid, m.subject, m.snippet, d.subject AS doc_subject, d.body AS doc_body"
    private static let visible = "m.is_draft = 0 AND m.in_trash = 0 AND m.in_spam = 0"

    static func text(_ r: Row) -> Text {
        let docSubject: String? = r["doc_subject"], docBody: String? = r["doc_body"]
        let subject = docSubject ?? SearchTextNormalizer.normalizeField(r["subject"])
        let body = docBody ?? SearchTextNormalizer.normalizeBody(HTMLEntities.decode(r["snippet"]))
        return Text(subject: subject, body: body, foldedSubject: subject.lowercased(), foldedBody: body.lowercased())
    }

    static func load(tid: Int64, in db: Database) throws -> [Int64: Text] {
        var out: [Int64: Text] = [:]
        for r in try Row.fetchAll(db.cached("""
            SELECT \(columns) FROM messages m LEFT JOIN message_search_docs d ON d.mid = m.mid
            WHERE m.tid = ? AND \(visible)
            """), arguments: [tid]) { out[r["mid"]] = text(r) }
        return out
    }

    static func loadInbox(account: Int64, in db: Database) throws -> [Int64: Text] {
        var out: [Int64: Text] = [:]
        for r in try Row.fetchAll(db.cached("""
            SELECT \(columns) FROM messages m JOIN threads t ON t.tid = m.tid
            LEFT JOIN message_search_docs d ON d.mid = m.mid
            WHERE t.account_id = ? AND t.in_inbox = 1 AND \(visible)
            """), arguments: [account]) { out[r["mid"]] = text(r) }
        return out
    }
}

enum TextSearch {
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var h = haystack, n = needle
        return h.withUTF8 { hay in
            n.withUTF8 { pin in
                let count = pin.count
                guard hay.count >= count, let first = pin.first else { return false }
                var i = 0
                let last = hay.count - count
                while i <= last {
                    if hay[i] == first {
                        var j = 1
                        while j < count && hay[i + j] == pin[j] { j += 1 }
                        if j == count { return true }
                    }
                    i += 1
                }
                return false
            }
        }
    }
}
