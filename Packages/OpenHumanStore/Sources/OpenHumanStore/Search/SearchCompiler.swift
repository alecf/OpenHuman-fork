import Foundation
import GRDB
import OpenHumanCore

struct CompiledSearch {
    var predicate: String
    var arguments: [DatabaseValue]
    var ftsMatch: String?
    var usesShortTermScan: Bool
}

enum SearchCompiler {
    static let minimumTrigramLength = 3

    static func compile(_ query: SearchQuery, accounts: [AccountID]?) -> CompiledSearch {
        var context = Context()
        var topLevelMatches: [String] = []
        var filters: [String] = []
        for term in query.terms {
            if let expression = ftsExpression(term) {
                topLevelMatches.append(expression)
            } else {
                filters.append(context.sql(term))
            }
        }
        var scope: [String] = []
        let open = Scope(query.terms)
        if !open.trash { scope.append("m.in_trash = 0") }
        if !open.spam { scope.append("m.in_spam = 0") }
        if !open.drafts { scope.append("m.is_draft = 0") }
        if let accounts {
            scope.append("m.account_id IN (\(accounts.map { _ in "?" }.joined(separator: ", ")))")
            context.args += accounts.map { $0.rawValue.databaseValue }
        } else {
            scope.append("m.account_id IN (SELECT account_id FROM accounts WHERE status <> 'removing')")
        }
        let predicate = (filters + scope).joined(separator: " AND ")
        return CompiledSearch(
            predicate: predicate.isEmpty ? "1" : predicate, arguments: context.args,
            ftsMatch: topLevelMatches.isEmpty ? nil : topLevelMatches.joined(separator: " AND "),
            usesShortTermScan: context.usedShortTerm)
    }

    private struct Scope {
        var trash = false, spam = false, drafts = false
        init(_ terms: [SearchTerm]) { for term in terms { visit(term) } }
        mutating func visit(_ term: SearchTerm) {
            switch term {
            case .anywhere: trash = true; spam = true; drafts = true
            case .mailbox(.trash): trash = true
            case .mailbox(.spam): spam = true
            case .mailbox(.drafts), .isFlag(.draft): drafts = true
            case let .or(items), let .and(items): for item in items { visit(item) }
            default: break
            }
        }
    }

    static func ftsExpression(_ term: SearchTerm) -> String? {
        switch term {
        case let .text(text, field):
            guard isIndexable(text) else { return nil }
            return column(field) + phrase(text)
        case let .filename(name):
            guard isIndexable(name) else { return nil }
            return "attachment_names : " + phrase(name)
        case let .or(items):
            let parts = items.map(ftsExpression)
            return parts.contains(where: { $0 == nil }) || parts.isEmpty ? nil : "(" + parts.compactMap { $0 }.joined(separator: " OR ") + ")"
        case let .and(items):
            let parts = items.map(ftsExpression)
            return parts.contains(where: { $0 == nil }) || parts.isEmpty ? nil : "(" + parts.compactMap { $0 }.joined(separator: " AND ") + ")"
        default:
            return nil
        }
    }

    static func isIndexable(_ text: String) -> Bool { text.unicodeScalars.count >= minimumTrigramLength }

    static func phrase(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private static func column(_ field: SearchField?) -> String {
        switch field {
        case nil: return ""
        case .subject: return "subject : "
        case .body: return "body : "
        case .participants: return "participants : "
        case .attachments: return "attachment_names : "
        }
    }

    private struct Context {
        var args: [DatabaseValue] = []
        var usedShortTerm = false

        mutating func add(_ value: String) { args.append(value.databaseValue) }
        mutating func add(_ value: Int64) { args.append(value.databaseValue) }

        mutating func sql(_ term: SearchTerm) -> String {
            switch term {
            case let .and(items): return items.isEmpty ? "1" : "(" + items.map { sql($0) }.joined(separator: " AND ") + ")"
            case let .or(items): return items.isEmpty ? "0" : "(" + items.map { sql($0) }.joined(separator: " OR ") + ")"
            case let .not(inner): return "NOT " + sql(inner)
            default: return "COALESCE(" + leaf(term) + ", 0)"
            }
        }

        func like(_ text: String, contains: Bool = true) -> String {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            return contains ? "%" + escaped + "%" : escaped
        }

        mutating func leaf(_ term: SearchTerm) -> String {
            switch term {
            case let .text(text, field):
                return textSQL(text, columns: columns(for: field), expression: ftsExpression(term))
            case let .filename(name):
                return textSQL(name, columns: ["d.attachment_names"], expression: ftsExpression(term))
            case let .address(field, value): return address(field, value)
            case let .label(name): return label(name)
            case let .mailbox(box): return mailbox(box)
            case let .isFlag(flag): return flagSQL(flag)
            case let .has(has):
                switch has {
                case .attachment: return "m.has_attachments = 1"
                case .invite: return "m.has_calendar_invite = 1"
                case .userLabels:
                    return """
                        EXISTS (SELECT 1 FROM labels l WHERE l.account_id = m.account_id AND l.kind = 'user' \
                        AND instr(',' || m.label_ids || ',', ',' || l.key || ',') > 0)
                        """
                }
            case let .before(date): add(ms(date)); return "m.internal_date < ?"
            case let .after(date): add(ms(date)); return "m.internal_date >= ?"
            case let .larger(n): add(Int64(n)); return "m.size_estimate > ?"
            case let .smaller(n): add(Int64(n)); return "m.size_estimate < ?"
            case let .listID(id): add(like(id)); return "m.list_id LIKE ? ESCAPE '\\'"
            case let .rfc822msgid(id): add(id); return "m.rfc822_message_id = ? COLLATE NOCASE"
            case .anywhere: return "1"
            case .not, .or, .and: return sql(term)
            }
        }

        func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

        func columns(for field: SearchField?) -> [String] {
            switch field {
            case nil: return ["d.subject", "d.participants", "d.body", "d.attachment_names"]
            case .subject: return ["d.subject"]
            case .body: return ["d.body"]
            case .participants: return ["d.participants"]
            case .attachments: return ["d.attachment_names"]
            }
        }

        mutating func textSQL(_ text: String, columns: [String], expression: String?) -> String {
            if let expression {
                add(expression)
                return "m.mid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)"
            }
            usedShortTerm = true
            let pattern = like(text)
            for _ in columns { add(pattern) }
            return "(" + columns.map { "\($0) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")"
        }

        mutating func address(_ field: AddressField, _ value: String) -> String {
            let isMe = value.lowercased() == "me"
            switch field {
            case .from:
                if isMe { return "m.is_from_me = 1" }
                if value.contains("@"), !value.hasPrefix("@") {
                    add(value); return "m.from_email = ?"
                }
                add(like(value)); add(like(value))
                return "(m.from_email LIKE ? ESCAPE '\\' OR m.from_name LIKE ? ESCAPE '\\')"
            case .to, .cc, .bcc:
                let column = "m.\(field.rawValue)_json"
                if isMe {
                    return """
                        EXISTS (SELECT 1 FROM json_each(\(column)) j, accounts a WHERE a.account_id = m.account_id \
                        AND json_extract(j.value, '$.e') = a.email COLLATE NOCASE)
                        """
                }
                add(like(value)); add(like(value))
                return """
                    EXISTS (SELECT 1 FROM json_each(\(column)) j WHERE json_extract(j.value, '$.e') LIKE ? ESCAPE '\\' \
                    OR json_extract(j.value, '$.n') LIKE ? ESCAPE '\\')
                    """
            }
        }

        mutating func label(_ name: String) -> String {
            add(name); add(name); add(name); add(like(name, contains: false) + "/%")
            return """
                EXISTS (SELECT 1 FROM labels l WHERE l.account_id = m.account_id \
                AND (l.key = ? COLLATE NOCASE OR l.name = ? COLLATE NOCASE \
                OR replace(replace(l.name, ' ', '-'), '/', '-') = ? COLLATE NOCASE OR l.name LIKE ? ESCAPE '\\' ) \
                AND instr(',' || m.label_ids || ',', ',' || l.key || ',') > 0)
                """
        }

        func hasLabel(_ key: String) -> String { "instr(',' || m.label_ids || ',', ',\(key),') > 0" }

        func thread(_ column: String) -> String {
            "EXISTS (SELECT 1 FROM threads t WHERE t.tid = m.tid AND t.\(column) IS NOT NULL)"
        }

        func mailbox(_ box: SystemMailbox) -> String {
            switch box {
            case .inbox: return hasLabel("INBOX")
            case .starred: return "m.is_starred = 1"
            case .important: return hasLabel("IMPORTANT")
            case .unread: return "m.is_unread = 1"
            case .sent: return "m.is_sent = 1"
            case .drafts: return "m.is_draft = 1"
            case .allMail: return "1"
            case .trash: return "m.in_trash = 1"
            case .spam: return "m.in_spam = 1"
            case .snoozed: return thread("snoozed_until")
            case .scheduled: return thread("scheduled_send_at")
            case .reminders: return thread("reminder_at")
            case .done:
                return "m.in_trash = 0 AND m.in_spam = 0 AND m.is_draft = 0 "
                    + "AND EXISTS (SELECT 1 FROM threads t WHERE t.tid = m.tid AND t.in_inbox = 0)"
            case .waiting:
                return "m.in_trash = 0 AND m.in_spam = 0 AND m.is_draft = 0 AND EXISTS (SELECT 1 FROM thread_labels tw "
                    + "JOIN labels lw ON lw.label_rid = tw.label_rid WHERE tw.tid = m.tid AND lw.key = 'oh:waiting')"
            }
        }

        func flagSQL(_ flag: SearchFlag) -> String {
            switch flag {
            case .unread: return "m.is_unread = 1"
            case .read: return "m.is_unread = 0"
            case .starred: return "m.is_starred = 1"
            case .important: return hasLabel("IMPORTANT")
            case .draft: return "m.is_draft = 1"
            case .snoozed: return thread("snoozed_until")
            case .event: return SearchCompiler.eventSQL
            }
        }
    }

    static let eventSQL: String = {
        func literal(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        let from = "lower(COALESCE(m.from_email, ''))"
        let subject = "ltrim(lower(COALESCE(m.subject, '')), ' ')"
        var parts = ["m.has_calendar_invite = 1"]
        parts.append(from + " IN (" + EventMailSignals.calendarSenders.sorted().map(literal).joined(separator: ", ") + ")")
        for marker in EventMailSignals.replyMarkers {
            for prefix in EventMailSignals.invitationSubjectPrefixes {
                parts.append("substr(\(subject), 1, \((marker + prefix).count)) = " + literal(marker + prefix))
            }
        }
        for domain in EventMailSignals.platformDomains {
            parts.append("substr(\(from), -\(domain.count + 1)) IN (" + literal("@" + domain) + ", " + literal("." + domain) + ")")
        }
        for phrase in EventMailSignals.subjectPhrases {
            parts.append("instr(lower(COALESCE(m.subject, '')), " + literal(phrase) + ") > 0")
        }
        let names = EventMailSignals.labelNames.map(literal).joined(separator: ", ")
        parts.append("""
            EXISTS (SELECT 1 FROM labels l WHERE l.account_id = m.account_id AND lower(l.name) IN (\(names.lowercased())) \
            AND instr(',' || m.label_ids || ',', ',' || l.key || ',') > 0)
            """)
        return "(" + parts.joined(separator: " OR ") + ")"
    }()
}
