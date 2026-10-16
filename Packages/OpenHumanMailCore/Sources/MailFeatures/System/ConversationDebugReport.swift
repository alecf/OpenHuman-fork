import Foundation
import MailModel
import OpenHumanCore

public struct ConversationDebugOptions: Sendable, Hashable {
    public var includeSubjectAndSender = false
    public init(includeSubjectAndSender: Bool = false) { self.includeSubjectAndSender = includeSubjectAndSender }
}

public struct ConversationDebugInput: Sendable {
    public var app: DiagnosticsAppInfo
    public var now: Date
    public var accountIndex: Int
    public var isLiveAccount: Bool
    public var sync: DiagnosticsSnapshot.AccountEntry?
    public var detail: ConversationDetail
    public var row: ThreadRow?
    public var labels: [LabelInfo]
    public var splits: [SplitInfo]
    public var importance: ImportanceExplanation?
    public var ownAddresses: Set<String>
    public var store: ConversationDebugStoreFacts?
    public var logLines: [String]
    public var options: ConversationDebugOptions

    public init(app: DiagnosticsAppInfo, now: Date, accountIndex: Int, isLiveAccount: Bool,
                sync: DiagnosticsSnapshot.AccountEntry? = nil, detail: ConversationDetail, row: ThreadRow? = nil,
                labels: [LabelInfo] = [], splits: [SplitInfo] = [], importance: ImportanceExplanation? = nil,
                ownAddresses: Set<String> = [], store: ConversationDebugStoreFacts? = nil, logLines: [String] = [],
                options: ConversationDebugOptions = ConversationDebugOptions()) {
        self.app = app
        self.now = now
        self.accountIndex = accountIndex
        self.isLiveAccount = isLiveAccount
        self.sync = sync
        self.detail = detail
        self.row = row
        self.labels = labels
        self.splits = splits
        self.importance = importance
        self.ownAddresses = ownAddresses
        self.store = store
        self.logLines = logLines
        self.options = options
    }
}

public enum ConversationDebugReport {
    public static let format = "openhuman.conversation-debug/1"
    public static let maxLogLines = 20

    struct Document: Encodable {
        var format = ConversationDebugReport.format
        var generatedAt: String
        var app: App
        var account: Account
        var thread: Thread
        var splits: [SplitVerdict]
        var importance: Importance?
        var messages: [Message]
        var log: [String]
        var notes: [String]
    }

    struct App: Encodable { var version, build, commit, macOS, dataMode: String }

    struct Account: Encodable {
        var index: Int
        var liveAccount: Bool
        var syncState: String?
        var lastSyncAgeSeconds: Int?
        var consecutiveFailures: Int?
        var threads: Int?
        var messages: Int?
        var pendingOperations: Int?
        var failedOperations: Int?
    }

    struct Thread: Encodable {
        var gmailThreadId: String
        var messageCount: Int
        var unread: Bool?
        var starred: Bool?
        var labels: [LabelEntry]
        var snooze: String
        var reminder: String
        var scheduledSend: Bool?
        var sortAtMinusLastMessageSeconds: Int?
        var draftCount: Int
        var subject: String?
    }

    struct LabelEntry: Encodable { var kind: String; var name: String }

    struct Importance: Encodable { var isImportant: Bool; var placement: String; var reason: String; var ruleSpecificity: String }

    struct SplitVerdict: Encodable {
        var name: String
        var enabled: Bool
        var position: Int
        var rule: String
        var wouldMatch: Bool?
        var terms: [String]
        var filedHere: Bool
    }

    struct Message: Encodable {
        var position: Int
        var date: String
        var sizeBytes: Int?
        var labelIds: [String]?
        var hasAttachments: Bool
        var hasCalendarInvite: Bool
        var mimeParts: [String]?
        var headerNames: [String]?
        var fromDomain: String?
        var fromIsOwn: Bool
        var bodyDownloaded: String
        var bodyHorizon: String
        var aiCache: String
        var unread: Bool
        var fromName: String?
    }

    public static func build(_ input: ConversationDebugInput) -> String {
        let document = document(input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(document), let text = String(data: data, encoding: .utf8) else {
            return "{\"format\":\"\(format)\",\"error\":\"could not encode\"}"
        }
        return text
    }

    static func document(_ input: ConversationDebugInput) -> Document {
        let detail = input.detail
        let optIn = input.options.includeSubjectAndSender
        let own = Set(input.ownAddresses.map { $0.lowercased() })
        let byKey = Dictionary(input.store?.messages.map { ($0.message.rowID, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        let labelByGmailID = Dictionary(input.labels.map { ($0.labelID.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        let labelByRow = Dictionary(input.labels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let threadLabelKeys = threadLabelKeys(input, labelByRow: labelByRow)

        let iso = ISO8601DateFormatter()
        var messages: [Message] = []
        var facts: [SplitFacts.Message] = []
        for (offset, message) in detail.messages.enumerated() {
            let extra = byKey[message.id.rowID]
            let parts = extra?.mimeParts.map { $0.map(describe) }
                ?? (message.attachments.isEmpty ? nil : message.attachments.map {
                    describe(ConversationDebugMimePart(contentType: $0.mimeType, size: $0.size, fileExtension: fileExtension($0.filename)))
                })
            let fromAddress = message.from?.email.lowercased()
            let isOwn = fromAddress.map(own.contains) ?? false
            messages.append(Message(
                position: offset + 1, date: iso.string(from: message.date), sizeBytes: extra?.sizeBytes,
                labelIds: extra?.labelIDs,
                hasAttachments: extra?.hasAttachments ?? !message.attachments.isEmpty,
                hasCalendarInvite: message.hasCalendarInvite,
                mimeParts: parts, headerNames: extra?.headerNames.map { $0.map(safeToken).sorted() },
                fromDomain: fromAddress.flatMap(domain), fromIsOwn: isOwn,
                bodyDownloaded: bodyDescription(extra?.bodyState), bodyHorizon: extra?.horizon.map(safeToken) ?? "unknown",
                aiCache: aiDescription(extra?.aiCache ?? input.store?.aiCache),
                unread: message.isUnread, fromName: optIn ? message.from?.name.map { optInScrub($0, input: input) } : nil))
            let keys = extra.map { Set($0.labelIDs) } ?? threadLabelKeys
            facts.append(SplitFacts.Message(
                from: message.from, recipients: message.to + message.cc, labels: keys, unread: message.isUnread,
                hasAttachments: extra?.hasAttachments ?? !message.attachments.isEmpty,
                hasInvite: message.hasCalendarInvite))
        }

        let evaluator = SplitFacts(messages: facts, labels: input.labels)
        let filedIn = input.importance?.placement
        let splits = input.splits.sorted { $0.position < $1.position }.map { split -> SplitVerdict in
            let outcome = SplitRuleEvaluator.evaluate(split.ruleText, facts: evaluator)
            return SplitVerdict(name: split.name, enabled: split.enabled, position: split.position, rule: outcome.rule,
                                wouldMatch: outcome.matches, terms: outcome.terms,
                                filedHere: filedIn.map { $0.caseInsensitiveCompare(split.name) == .orderedSame } ?? false)
        }

        let row = input.row
        var labelEntries: [LabelEntry] = []
        var seen = Set<String>()
        func add(_ info: LabelInfo) {
            guard info.kind != .virtual, info.kind != .split, seen.insert(info.labelID.rawValue).inserted else { return }
            labelEntries.append(LabelEntry(kind: info.kind.rawValue, name: info.name))
        }
        for id in detail.userLabelIDs + (row?.userLabelIDs ?? []) + (row?.categoryLabelIDs ?? []) {
            if let info = labelByRow[id] { add(info) }
        }
        for extra in input.store?.messages ?? [] {
            for id in extra.labelIDs { if let info = labelByGmailID[id] { add(info) } }
        }
        labelEntries.sort { ($0.kind, $0.name) < ($1.kind, $1.name) }

        let thread = Thread(
            gmailThreadId: safeToken(detail.id.gmailThreadID.rawValue), messageCount: detail.messages.count,
            unread: row?.isUnread ?? (detail.messages.isEmpty ? nil : detail.messages.contains(where: \.isUnread)),
            starred: row?.isStarred ?? detail.isStarred, labels: labelEntries,
            snooze: snoozeText(detail.snooze, iso: iso), reminder: detail.reminder.map { "due \(iso.string(from: $0.dueAt))" } ?? "none",
            scheduledSend: row.map { $0.scheduledSendAt != nil },
            sortAtMinusLastMessageSeconds: row.map { Int($0.sortAt.timeIntervalSince($0.lastMessageAt)) },
            draftCount: detail.drafts.count, subject: optIn ? optInScrub(detail.subject, input: input) : nil)

        let id = detail.id.gmailThreadID.rawValue
        let log = scrubbedLog(input, threadID: id, optIn: optIn)

        var notes: [String] = []
        if input.store == nil { notes.append("store facts unavailable in this build: label ids, sizes, MIME parts, header names, body state, horizon and AI cache show unknown") }
        if input.importance == nil { notes.append("importance explanation unavailable") }
        notes.append("split verdicts are evaluated here from the thread's facts (no sender list-id); wouldMatch is the rule alone, filedHere comes from the importance placement")

        let sync = input.sync
        return Document(
            generatedAt: iso.string(from: input.now),
            app: App(version: safeToken(input.app.version), build: safeToken(input.app.build), commit: safeToken(input.app.gitCommit),
                     macOS: safeText(input.app.os), dataMode: safeToken(input.app.dataMode)),
            account: Account(index: input.accountIndex, liveAccount: input.isLiveAccount,
                             syncState: sync.map { safeToken($0.connectivity) },
                             lastSyncAgeSeconds: sync?.lastSyncAt.map { max(0, Int(input.now.timeIntervalSince($0))) },
                             consecutiveFailures: sync?.consecutiveFailures, threads: sync?.threadCount,
                             messages: sync?.messageCount, pendingOperations: sync?.pendingOperations,
                             failedOperations: sync?.failedOperations),
            thread: thread, splits: splits,
            importance: input.importance.map {
                Importance(isImportant: $0.isImportant, placement: safeText($0.placement),
                           reason: safeReason($0.reason, input: input), ruleSpecificity: specificity($0))
            },
            messages: messages, log: log, notes: notes)
    }

    private static func threadLabelKeys(_ input: ConversationDebugInput, labelByRow: [Int64: LabelInfo]) -> Set<String> {
        var keys = Set<String>()
        for id in input.detail.userLabelIDs + (input.row?.userLabelIDs ?? []) + (input.row?.categoryLabelIDs ?? []) {
            if let info = labelByRow[id] { keys.insert(info.labelID.rawValue) }
        }
        if input.row?.isStarred ?? input.detail.isStarred { keys.insert("STARRED") }
        if input.row?.isImportant == true { keys.insert("IMPORTANT") }
        return keys
    }

    static func describe(_ part: ConversationDebugMimePart) -> String {
        var text = "\(safeToken(part.contentType)) \(part.size)B"
        if let ext = part.fileExtension, !ext.isEmpty { text += " .\(safeToken(ext))" }
        return text
    }

    static func fileExtension(_ filename: String) -> String? {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return nil }
        let ext = String(filename[filename.index(after: dot)...]).lowercased()
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return ext
    }

    static func domain(_ address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let value = String(address[address.index(after: at)...]).lowercased()
        return value.isEmpty ? nil : safeToken(value)
    }

    static func bodyDescription(_ state: String?) -> String {
        switch state {
        case "full": "yes (full)"
        case "metadata": "no (format metadata only)"
        case let other?: safeToken(other)
        case nil: "unknown"
        }
    }

    static func aiDescription(_ cache: [String: String]?) -> String {
        guard let cache else { return "unknown" }
        return ["summary", "replies", "classification"].map { kind in
            cache[kind].map { "\(kind)=yes(v\(safeToken($0)))" } ?? "\(kind)=no"
        }.joined(separator: " ")
    }

    static func snoozeText(_ state: SnoozeState?, iso: ISO8601DateFormatter) -> String {
        switch state {
        case nil: "none"
        case .until(let date, let count)?: "until \(iso.string(from: date)) stamps=\(count)"
        case .wakeTimeUnknown?: "wake time unknown"
        }
    }

    static func specificity(_ explanation: ImportanceExplanation) -> String {
        guard explanation.ruleID != nil else { return "none (Gmail's marker or no rule)" }
        let reason = explanation.reason.lowercased()
        if reason.contains("this conversation") || reason.contains("thread") { return "conversation" }
        if reason.contains("domain") { return "domain" }
        if reason.contains("sender") || reason.contains("from ") { return "sender" }
        if reason.contains("label") { return "label" }
        if reason.contains("word") || reason.contains("keyword") { return "keyword" }
        return "other"
    }

    private static func safeReason(_ reason: String, input: ConversationDebugInput) -> String {
        scrub(reason, denylist: knownStrings(input, includeSubject: !input.options.includeSubjectAndSender))
    }

    private static func knownStrings(_ input: ConversationDebugInput, includeSubject: Bool, names: Bool = true) -> [String] {
        var strings: [String] = Array(input.ownAddresses)
        for message in input.detail.messages {
            for address in [message.from].compactMap({ $0 }) + message.to + message.cc + message.bcc {
                strings.append(address.email)
                if names, let name = address.name {
                    strings.append(name)
                    strings.append(contentsOf: name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                        .filter { $0.count >= 4 })
                }
                if let local = address.email.split(separator: "@").first { strings.append(String(local)) }
            }
            strings.append(message.snippet)
        }
        if includeSubject {
            strings.append(input.detail.subject)
            if let subject = input.row?.subject { strings.append(subject) }
        }
        return strings
    }

    static func scrubbedLog(_ input: ConversationDebugInput, threadID: String, optIn: Bool) -> [String] {
        let denylist = knownStrings(input, includeSubject: !optIn)
        let matching = input.logLines.filter { $0.contains(threadID) }.suffix(maxLogLines)
        return matching.map { scrub($0, denylist: denylist) }
    }

    static func optInScrub(_ text: String, input: ConversationDebugInput) -> String {
        scrub(text, denylist: knownStrings(input, includeSubject: false, names: false))
    }

    static func scrub(_ text: String, denylist: [String]) -> String {
        var out = text
        let entries = Set(denylist.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= DevFeedbackRedactor.minimumDenylistLength })
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        for entry in entries where out.range(of: entry, options: .caseInsensitive) != nil {
            out = out.replacingOccurrences(of: entry, with: "<content>", options: .caseInsensitive)
        }
        return DevFeedbackRedactor(denylist: entries).scrub(out)
    }

    static func safeToken(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-/+:()=|")
        guard value.count <= 80, value.unicodeScalars.allSatisfy(allowed.contains) else { return "<redacted>" }
        return value
    }

    static func safeText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 120 else { return "<redacted>" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-/+:()= ")
        return trimmed.unicodeScalars.allSatisfy(allowed.contains) ? trimmed : "<redacted>"
    }
}

struct SplitFacts {
    struct Message {
        var from: EmailAddress?
        var recipients: [EmailAddress]
        var labels: Set<String>
        var unread: Bool
        var hasAttachments: Bool
        var hasInvite: Bool
    }
    var messages: [Message]
    var labels: [LabelInfo]
}

enum SplitRuleEvaluator {
    struct Outcome { var rule: String; var matches: Bool?; var terms: [String] }

    indirect enum Node {
        case term(name: String, value: String)
        case and([Node]), or([Node]), not(Node)
    }

    static func evaluate(_ text: String, facts: SplitFacts) -> Outcome {
        var parser = Parser(Array(text))
        guard let node = parser.parseExpression(), parser.atEnd else {
            return Outcome(rule: "<unparsed>", matches: nil, terms: ["rule text not understood"])
        }
        var terms: [String] = []
        var unknown = false
        let value = eval(node, facts, &terms, &unknown)
        return Outcome(rule: render(node), matches: unknown ? nil : value, terms: terms)
    }

    private static func eval(_ node: Node, _ facts: SplitFacts, _ terms: inout [String], _ unknown: inout Bool) -> Bool {
        switch node {
        case let .and(items):
            return items.map { eval($0, facts, &terms, &unknown) }.allSatisfy { $0 }
        case let .or(items):
            return items.map { eval($0, facts, &terms, &unknown) }.contains(true)
        case let .not(inner):
            return !eval(inner, facts, &terms, &unknown)
        case let .term(name, value):
            guard let result = leaf(name, value, facts) else {
                unknown = true
                terms.append("\(display(name, value))=unknown")
                return false
            }
            terms.append("\(display(name, value))=\(result)")
            return result
        }
    }

    private static func leaf(_ name: String, _ value: String, _ facts: SplitFacts) -> Bool? {
        let messages = facts.messages
        switch name {
        case "is":
            switch value.lowercased() {
            case "important": return messages.contains { $0.labels.contains("IMPORTANT") }
            case "starred": return messages.contains { $0.labels.contains("STARRED") }
            case "unread": return messages.contains(where: \.unread)
            default: return nil
            }
        case "has":
            switch value.lowercased() {
            case "attachment": return messages.contains(where: \.hasAttachments)
            case "invite": return messages.contains(where: \.hasInvite)
            default: return nil
            }
        case "label":
            let wanted = value.lowercased()
            var keys = Set<String>()
            for info in facts.labels where !info.isHidden && info.kind != .virtual && info.kind != .split {
                if info.labelID.rawValue.lowercased() == wanted || info.name.lowercased() == wanted { keys.insert(info.labelID.rawValue) }
            }
            return !keys.isEmpty && messages.contains { !$0.labels.isDisjoint(with: keys) }
        case "category":
            let n = value.lowercased()
            return messages.contains { $0.labels.contains("CATEGORY_" + (n == "primary" ? "PERSONAL" : n.uppercased())) }
        case "from":
            return alternatives(value).contains { p in messages.contains { m in m.from.map { matches(p, $0) } ?? false } }
        case "to":
            return alternatives(value).contains { p in messages.contains { m in m.recipients.contains { matches(p, $0) } } }
        case "list", "subject":
            return nil
        default:
            return nil
        }
    }

    private static func alternatives(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter { $0 != "OR" }
    }

    private static func matches(_ raw: String, _ address: EmailAddress) -> Bool {
        let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let e = address.email.lowercased()
        if p.isEmpty || p == "@" { return false }
        if p.hasPrefix("@") || (!p.contains("@") && p.contains(".")) {
            let d = p.hasPrefix("@") ? String(p.dropFirst()) : p
            guard let at = e.lastIndex(of: "@") else { return false }
            let domain = e[e.index(after: at)...]
            return domain == d || domain.hasSuffix("." + d)
        }
        if p.contains("@") { return e == p }
        return e.contains(p) || (address.name?.lowercased().contains(p) ?? false)
    }

    static func display(_ name: String, _ value: String) -> String {
        switch name {
        case "has":
            switch value.lowercased() {
            case "invite": return "has_calendar_invite"
            case "attachment": return "has_attachment"
            default: return "has:" + token(value)
            }
        case "is": return "is_" + token(value.lowercased())
        case "from", "to":
            let shown = alternatives(value).map { v -> String in
                let p = v.lowercased()
                if p.hasPrefix("@") { return "@" + token(String(p.dropFirst())) }
                if !p.contains("@"), p.contains(".") { return token(p) }
                return "<value>"
            }
            return "\(name):" + shown.joined(separator: ",")
        case "subject": return "subject:<value>"
        default: return "\(name):" + token(value)
        }
    }

    private static func token(_ value: String) -> String { ConversationDebugReport.safeToken(value) }

    static func render(_ node: Node) -> String {
        switch node {
        case let .term(name, value): return display(name, value)
        case let .and(items): return "(" + items.map(render).joined(separator: " AND ") + ")"
        case let .or(items): return "(" + items.map(render).joined(separator: " OR ") + ")"
        case let .not(inner): return "NOT " + render(inner)
        }
    }

    struct Parser {
        let chars: [Character]
        var i = 0
        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { mutating get { skipSpaces(); return i >= chars.count } }

        mutating func skipSpaces() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        mutating func parseExpression() -> Node? {
            guard let first = parseAnd() else { return nil }
            var items = [first]
            while true {
                skipSpaces()
                guard matchWord("OR") else { break }
                guard let next = parseAnd() else { return nil }
                items.append(next)
            }
            return items.count == 1 ? first : .or(items)
        }

        mutating func parseAnd() -> Node? {
            var items: [Node] = []
            while true {
                skipSpaces()
                if i >= chars.count || chars[i] == ")" || chars[i] == "}" || peekWord("OR") { break }
                guard let node = parseUnary() else { return nil }
                items.append(node)
            }
            guard !items.isEmpty else { return nil }
            return items.count == 1 ? items[0] : .and(items)
        }

        mutating func parseUnary() -> Node? {
            skipSpaces()
            guard i < chars.count else { return nil }
            if chars[i] == "-" { i += 1; return parseUnary().map(Node.not) }
            if chars[i] == "(" {
                i += 1
                guard let inner = parseExpression() else { return nil }
                skipSpaces()
                guard i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                return inner
            }
            if chars[i] == "{" {
                i += 1
                var items: [Node] = []
                while true {
                    skipSpaces()
                    if i < chars.count, chars[i] == "}" { i += 1; break }
                    guard let node = parseUnary() else { return nil }
                    items.append(node)
                }
                return items.isEmpty ? nil : .or(items)
            }
            var name = ""
            while i < chars.count, chars[i] != ":", !chars[i].isWhitespace, chars[i] != "(", chars[i] != ")" { name.append(chars[i]); i += 1 }
            guard i < chars.count, chars[i] == ":", !name.isEmpty else { return nil }
            i += 1
            return readValue().map { .term(name: name.lowercased(), value: $0) }
        }

        mutating func readValue() -> String? {
            guard i < chars.count else { return nil }
            var value = ""
            if chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" { value.append(chars[i]); i += 1 }
                guard i < chars.count else { return nil }
                i += 1
            } else if chars[i] == "(" {
                var depth = 0
                i += 1
                depth = 1
                while i < chars.count {
                    if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1; if depth == 0 { break } }
                    value.append(chars[i]); i += 1
                }
                guard i < chars.count else { return nil }
                i += 1
            } else {
                while i < chars.count, !chars[i].isWhitespace, chars[i] != ")" { value.append(chars[i]); i += 1 }
            }
            return value
        }

        func peekWord(_ word: String) -> Bool {
            let end = i + word.count
            guard end <= chars.count, String(chars[i..<end]) == word else { return false }
            return end == chars.count || chars[end].isWhitespace || chars[end] == "("
        }

        mutating func matchWord(_ word: String) -> Bool {
            guard peekWord(word) else { return false }
            i += word.count
            return true
        }
    }
}
