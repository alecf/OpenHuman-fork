import Foundation
import MailModel
import OpenHumanCore

enum FakeLabels {
    static let inbox = GmailLabelID("INBOX")
    static let unread = GmailLabelID("UNREAD")
    static let starred = GmailLabelID("STARRED")
    static let important = GmailLabelID("IMPORTANT")
    static let sent = GmailLabelID("SENT")
    static let draft = GmailLabelID("DRAFT")
    static let trash = GmailLabelID("TRASH")
    static let spam = GmailLabelID("SPAM")
    static let promotions = GmailLabelID("CATEGORY_PROMOTIONS")
    static let social = GmailLabelID("CATEGORY_SOCIAL")
    static let updates = GmailLabelID("CATEGORY_UPDATES")
    static let forums = GmailLabelID("CATEGORY_FORUMS")
    static let personal = GmailLabelID("CATEGORY_PERSONAL")

    static let categories: [String: GmailLabelID] = [
        "promotions": promotions, "social": social, "updates": updates, "forums": forums, "personal": personal,
    ]

    static func standard(account: AccountID, ids: inout FakeIDs) -> [LabelInfo] {
        let system: [(String, String)] = [
            ("INBOX", "Inbox"), ("STARRED", "Starred"), ("IMPORTANT", "Important"), ("UNREAD", "Unread"),
            ("SENT", "Sent"), ("DRAFT", "Drafts"), ("TRASH", "Trash"), ("SPAM", "Spam"),
        ]
        let category: [(String, String)] = [
            ("CATEGORY_PERSONAL", "Personal"), ("CATEGORY_SOCIAL", "Social"), ("CATEGORY_PROMOTIONS", "Promotions"),
            ("CATEGORY_UPDATES", "Updates"), ("CATEGORY_FORUMS", "Forums"),
        ]
        let virtual: [(String, String)] = [
            ("oh:allmail", "All mail"), ("oh:snoozed", "Snoozed"), ("oh:scheduled", "Scheduled"),
            ("oh:reminders", "Reminders"), ("oh:waiting", "Waiting"),
        ]
        var labels: [LabelInfo] = []
        var position = 0
        for (list, kind) in [(system, LabelInfo.Kind.system), (category, .category), (virtual, .virtual)] {
            for (id, name) in list {
                labels.append(LabelInfo(id: ids.nextLabelRow(), account: account, labelID: GmailLabelID(id), kind: kind,
                                        name: name, displayName: name, isHidden: kind == .category, position: position))
                position += 1
            }
        }
        return labels
    }

    static func user(_ name: String, account: AccountID, position: Int, color: (String, String)? = nil,
                     ids: inout FakeIDs) -> LabelInfo {
        let row = ids.nextLabelRow()
        let hidden: Bool = if case .schedule = ScheduleLabel.parse(name) { true } else { false }
        return LabelInfo(id: row, account: account, labelID: GmailLabelID("Label_\(row)"), kind: .user, name: name,
                         displayName: String(name.split(separator: "/").last ?? Substring(name)),
                         colorBackground: color?.0, colorText: color?.1, isHidden: hidden, position: position)
    }

    static func importantSplit(account: AccountID, ids: inout FakeIDs) -> SplitInfo {
        SplitInfo(id: ids.nextSplit(), account: account, name: "Important", position: 0, ruleText: "is:important")
    }

    static func placesInImportant(_ split: SplitInfo?) -> Bool {
        split?.ruleText.trimmingCharacters(in: .whitespaces).lowercased() == "is:important"
    }

    static func calendarSplit(account: AccountID, ids: inout FakeIDs) -> SplitInfo {
        SplitInfo(id: ids.nextSplit(), account: account, name: "Calendar", position: 1, ruleText: "is:event")
    }
}

struct FakeIDs: Sendable {
    var labelRow: Int64 = 1
    var split = 1
    var draft = 1
    var reminder = 1
    var snippet = 1

    mutating func nextLabelRow() -> Int64 {
        defer { labelRow += 1 }
        return labelRow
    }

    mutating func nextSplit() -> SplitKey {
        defer { split += 1 }
        return SplitKey("split-\(split)")
    }

    mutating func nextDraft() -> DraftKey {
        defer { draft += 1 }
        return DraftKey(String(format: "00000000-0000-4000-8000-%012d", draft))
    }

    mutating func nextReminder() -> String {
        defer { reminder += 1 }
        return String(format: "00000000-0000-4000-9000-%012d", reminder)
    }

    mutating func nextSnippet() -> String {
        defer { snippet += 1 }
        return String(format: "00000000-0000-4000-a000-%012d", snippet)
    }
}

enum FakeAggregator {
    struct MessageView: Sendable {
        let summary: MessageSummary
        let labels: Set<GmailLabelID>
        let isFromMe: Bool
    }

    static func isVisible(_ labels: Set<GmailLabelID>) -> Bool {
        !labels.contains(FakeLabels.trash) && !labels.contains(FakeLabels.spam)
    }

    static func scope(_ messages: [MessageView]) -> [MessageView] {
        let visible = messages.filter { isVisible($0.labels) }
        return visible.isEmpty ? messages : visible
    }

    static func row(key: ThreadKey, subject: String, messages: [MessageView], me: Set<String>,
                    userLabelRows: [GmailLabelID: Int64], categoryLabelRows: [GmailLabelID: Int64] = [:],
                    draftCount: Int = 0, sortAt: Date? = nil,
                    snoozedUntil: Date? = nil, reminderAt: Date? = nil, scheduledSendAt: Date? = nil,
                    hasPendingChanges: Bool = false, returnedByReminder: Bool = false) -> ThreadRow {
        let scope = scope(messages)
        let (display, participants) = Self.participants(scope: scope, me: me)
        var unread = 0, attachments = 0
        var starred = false, important = false
        var labelRows = Set<Int64>(), categoryRows = Set<Int64>()
        for m in scope {
            if m.labels.contains(FakeLabels.unread) { unread += 1 }
            if m.labels.contains(FakeLabels.starred) { starred = true }
            if m.labels.contains(FakeLabels.important) { important = true }
            attachments += m.summary.attachments.lazy.filter { !$0.isInline }.count
            for label in m.labels {
                if let row = userLabelRows[label] { labelRows.insert(row) }
                if let row = categoryLabelRows[label] { categoryRows.insert(row) }
            }
        }
        let last = scope.last?.summary
        let lastAt = last?.date ?? Date(timeIntervalSince1970: 0)
        return ThreadRow(
            id: key, subject: subject, snippet: last?.snippet ?? "", participantsDisplay: display,
            participants: participants, messageCount: scope.count, unreadCount: unread, draftCount: draftCount,
            attachmentCount: attachments, isUnread: unread > 0, isStarred: starred, isImportant: important,
            userLabelIDs: labelRows.sorted(), lastMessageAt: lastAt, sortAt: sortAt ?? lastAt,
            snoozedUntil: snoozedUntil, reminderAt: reminderAt, scheduledSendAt: scheduledSendAt,
            hasPendingChanges: hasPendingChanges, categoryLabelIDs: categoryRows.sorted(),
            returnedByReminder: returnedByReminder)
    }

    static func participants(scope: [MessageView], me: Set<String>) -> (String, [Participant]) {
        func mine(_ m: MessageView) -> Bool { m.isFromMe || (m.summary.from.map { me.contains($0.email.lowercased()) } ?? false) }
        func clean(_ n: String?) -> String? { (n?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) ? nil : n }
        var unread = Set<String>()
        for m in scope where m.labels.contains(FakeLabels.unread) { if let f = m.summary.from { unread.insert(f.email.lowercased()) } }
        var others: [Participant] = []
        var authorWrote = false
        for m in scope.reversed() {
            guard let from = m.summary.from, !from.email.isEmpty else { continue }
            if mine(m) { authorWrote = true; continue }
            let key = from.email.lowercased()
            if let i = others.firstIndex(where: { $0.email.lowercased() == key }) {
                if others[i].name == nil { others[i] = Participant(name: clean(from.name), email: others[i].email, isMe: false, hasUnread: others[i].hasUnread) }
            } else {
                others.append(Participant(name: clean(from.name), email: from.email, isMe: false, hasUnread: unread.contains(key)))
            }
        }
        var shown = others
        var toMode = false
        if shown.isEmpty, authorWrote, let last = scope.last(where: { mine($0) && ($0.summary.from?.email.isEmpty == false) }) {
            var rec: [Participant] = []
            for r in last.summary.to + last.summary.cc where !r.email.isEmpty {
                let key = r.email.lowercased()
                if me.contains(key) || rec.contains(where: { $0.email.lowercased() == key }) { continue }
                rec.append(Participant(name: clean(r.name), email: r.email, isMe: false, hasUnread: false))
            }
            if !rec.isEmpty { shown = rec; toMode = true }
        }
        var display = ""
        if shown.isEmpty {
            if authorWrote { display = "me" }
        } else {
            let names: [String] = shown.map { p in
                if let n = p.name {
                    if shown.count > 1, let first = n.split(separator: " ").first { return String(first) }
                    return n
                }
                return String(p.email.split(separator: "@").first ?? Substring(p.email))
            }
            display = (toMode ? "To: " : "") + names.prefix(3).joined(separator: ", ")
            if names.count > 3 { display += " +\(names.count - 3)" }
        }
        if !display.isEmpty, scope.count > 1 { display += " (\(scope.count))" }
        var list = shown
        if authorWrote, let m = scope.first(where: { mine($0) && $0.summary.from != nil }), let f = m.summary.from {
            list.append(Participant(name: clean(f.name), email: f.email, isMe: true,
                                    hasUnread: scope.contains { mine($0) && $0.labels.contains(FakeLabels.unread) }))
        }
        return (display, Array(list.prefix(6)))
    }
}
