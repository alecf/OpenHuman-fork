import Foundation
import MailModel
import OpenHumanCore

struct DerivedThread: Sendable {
    var row: ThreadRow
    var lastAt: Date
    var hasVisible: Bool
    var inInbox: Bool
    var inboxSortAt: Date
    var visibleLabels: Set<GmailLabelID>
    var sentAt: Date?
    var trashAt: Date?
    var spamAt: Date?
    var snooze: SnoozeState?
    var split: SplitKey?
    var draftAt: Date?
    var reviewAt: Date?
    var drafts: Set<DraftKey>
    var pendingReview: Set<DraftKey>
    var scheduledSendAt: Date?
    var waitingAt: Date? = nil
}

struct WindowEntry: Sendable, Hashable {
    var sortAt: Date
    var key: ThreadKey
    var match: SearchMatchKind? = nil
}

extension ThreadRow {
    func with(sortAt: Date) -> ThreadRow {
        sortAt == self.sortAt ? self : ThreadRow(
            id: id, subject: subject, snippet: snippet, participantsDisplay: participantsDisplay,
            participants: participants, messageCount: messageCount, unreadCount: unreadCount, draftCount: draftCount,
            attachmentCount: attachmentCount, isUnread: isUnread, isStarred: isStarred, isImportant: isImportant,
            userLabelIDs: userLabelIDs, lastMessageAt: lastMessageAt, sortAt: sortAt, snoozedUntil: snoozedUntil,
            reminderAt: reminderAt, scheduledSendAt: scheduledSendAt, hasPendingChanges: hasPendingChanges,
            categoryLabelIDs: categoryLabelIDs, searchMatch: searchMatch)
    }
}

extension State {
    func effectiveLabels(_ message: FakeMessage) -> Set<GmailLabelID> {
        guard let ids = pendingByMessage[message.summary.id], !ids.isEmpty else { return message.labels }
        var labels = message.labels
        for id in ids.sorted() {
            if let op = operations[id], op.status == .pending, let edit = op.edits[message.summary.id] {
                labels = edit.applied(to: labels)
            }
        }
        return labels
    }

    func views(_ thread: FakeThread) -> [FakeAggregator.MessageView] {
        thread.messages.map { m in
            let labels = effectiveLabels(m)
            let summary = m.summary.isUnread == labels.contains(FakeLabels.unread) ? m.summary : MessageSummary(
                id: m.summary.id, from: m.summary.from, to: m.summary.to, cc: m.summary.cc, bcc: m.summary.bcc,
                date: m.summary.date, snippet: m.summary.snippet, isUnread: labels.contains(FakeLabels.unread),
                attachments: m.summary.attachments, hasCalendarInvite: m.summary.hasCalendarInvite)
            return FakeAggregator.MessageView(summary: summary, labels: labels, isFromMe: m.isFromMe)
        }
    }

    mutating func invalidate<S: Sequence>(_ keys: S) where S.Element == ThreadKey {
        for key in keys { derived.removeValue(forKey: key) }
    }

    mutating func invalidateAccount(_ account: AccountID) {
        for key in threadOrder[account] ?? [] { derived.removeValue(forKey: key) }
    }

    mutating func derived(_ key: ThreadKey) -> DerivedThread? {
        if let cached = derived[key] { return cached }
        guard let value = derive(key) else { return nil }
        derived[key] = value
        return value
    }

    func derive(_ key: ThreadKey) -> DerivedThread? {
        guard let thread = threads[key], let account = accounts[key.account] else { return nil }
        let views = views(thread)
        let visible = views.filter { FakeAggregator.isVisible($0.labels) }
        let scope = visible.isEmpty ? views : visible
        let lastAt = scope.last?.summary.date ?? Date(timeIntervalSince1970: 0)
        var visibleLabels = Set<GmailLabelID>()
        for v in visible { visibleLabels.formUnion(v.labels) }
        let inInbox = visibleLabels.contains(FakeLabels.inbox)
        let boost = thread.boostAt.flatMap { inInbox && $0 > lastAt ? $0 : nil }
        let inboxSortAt = boost ?? lastAt

        let sentAt = views.filter { $0.labels.contains(FakeLabels.sent) && FakeAggregator.isVisible($0.labels) }
            .map(\.summary.date).max()
        let trashAt = views.filter { $0.labels.contains(FakeLabels.trash) }.map(\.summary.date).max()
        let spamAt = views.filter { $0.labels.contains(FakeLabels.spam) }.map(\.summary.date).max()
        let snooze = Self.snooze(visible, account: account)

        var draftAt: Date?, reviewAt: Date?, scheduledAt: Date?
        var listed = Set<DraftKey>(), pendingReview = Set<DraftKey>()
        for id in draftsByThread[key] ?? [] {
            guard let draft = drafts[id] else { continue }
            let summary = draft.summary
            if draft.isListed {
                listed.insert(id)
                draftAt = max(draftAt ?? summary.updatedAt, summary.updatedAt)
            }
            if summary.review == .pending, summary.status != .sending {
                pendingReview.insert(id)
                reviewAt = max(reviewAt ?? summary.updatedAt, summary.updatedAt)
            }
            if summary.status == .scheduled, let at = summary.sendAt { scheduledAt = min(scheduledAt ?? at, at) }
        }
        let reminder = reminders[key]
        let row = FakeAggregator.row(
            key: key, subject: thread.subject, messages: views, me: account.me, userLabelRows: account.userLabelRows,
            categoryLabelRows: account.categoryLabelRows, draftCount: listed.count, sortAt: lastAt, snoozedUntil: snooze?.wakeAt, reminderAt: reminder?.dueAt,
            scheduledSendAt: scheduledAt, hasPendingChanges: !(pendingByThread[key]?.isEmpty ?? true))

        var result = DerivedThread(
            row: row, lastAt: lastAt, hasVisible: !visible.isEmpty, inInbox: inInbox, inboxSortAt: inboxSortAt,
            visibleLabels: visibleLabels, sentAt: sentAt, trashAt: trashAt, spamAt: spamAt, snooze: snooze, split: nil,
            draftAt: draftAt, reviewAt: reviewAt, drafts: listed, pendingReview: pendingReview,
            scheduledSendAt: scheduledAt)
        if let last = visible.last, let from = last.summary.from?.email.lowercased(), account.me.contains(from),
           (last.summary.to + last.summary.cc).contains(where: { !account.me.contains($0.email.lowercased()) }) {
            result.waitingAt = last.summary.date
        }
        if inInbox, !account.splits.isEmpty {
            let facts = facts(thread: thread, views: views, derived: result, account: account)
            for split in account.splits.sorted(by: { $0.position < $1.position }) where split.enabled {
                if account.splitRules[split.id]?.matches(facts) == true {
                    result.split = split.id
                    break
                }
            }
        }
        return result
    }

    static func snooze(_ visible: [FakeAggregator.MessageView], account: FakeAccountState) -> SnoozeState? {
        var stamps = Set<Date>()
        var marked = false
        for view in visible {
            for id in view.labels where !Self.isGmailSystemLabel(id) {
                guard let name = account.label(id)?.name else { continue }
                switch ScheduleLabel.parse(name) {
                case .schedule(let label) where label.kind == .snoozed: stamps.insert(label.due)
                case .marker(.snoozed), .malformed(.snoozed): marked = true
                default: break
                }
            }
        }
        if let earliest = stamps.min() { return .until(earliest, stampCount: stamps.count) }
        return marked ? .wakeTimeUnknown : nil
    }

    static func isGmailSystemLabel(_ id: GmailLabelID) -> Bool {
        id.rawValue.allSatisfy { $0.isUppercase || $0 == "_" }
    }

    func facts(thread: FakeThread, views: [FakeAggregator.MessageView], derived: DerivedThread,
               account: FakeAccountState) -> FakeQuery.Facts {
        let visible = derived.hasVisible ? views.filter { FakeAggregator.isVisible($0.labels) } : views
        func describe(_ a: EmailAddress) -> String { "\(a.name ?? "") <\(a.email)>".lowercased() }
        let senders = visible.compactMap(\.summary.from).map(describe)
        let recipients = visible.flatMap { $0.summary.to + $0.summary.cc + $0.summary.bcc }.map(describe)
        let subject = thread.subject.lowercased()
        let text = ([subject] + visible.map { $0.summary.snippet.lowercased() } + senders + recipients)
            .joined(separator: "\n")
        var labelNames = Set<String>()
        var hasUserLabels = false
        for id in derived.visibleLabels {
            labelNames.insert(id.rawValue.lowercased())
            if let label = account.label(id) {
                labelNames.insert(label.name.lowercased())
                if label.kind == .user, !label.name.hasPrefix(ScheduleLabel.prefix) { hasUserLabels = true }
            }
        }
        var flags = Set<String>()
        if derived.visibleLabels.contains(FakeLabels.important) { flags.insert("important") }
        if derived.visibleLabels.contains(FakeLabels.starred) { flags.insert("starred") }
        flags.insert(derived.row.isUnread ? "unread" : "read")
        if derived.snooze != nil { flags.insert("snoozed") }
        if !derived.drafts.isEmpty { flags.insert("draft") }
        if visible.contains(where: { $0.summary.hasCalendarInvite
            || EventMailSignals.headersSuggestEvent(fromEmail: $0.summary.from?.email, subject: thread.subject) })
            || labelNames.contains(where: EventMailSignals.isEventLabelName) {
            flags.insert("event")
        }
        var has = Set<String>()
        if visible.contains(where: { $0.summary.attachments.contains { !$0.isInline } }) { has.insert("attachment") }
        if visible.contains(where: \.summary.hasCalendarInvite) { has.insert("invite") }
        if hasUserLabels { has.insert("userlabels") }
        var mailboxes = Set<String>()
        if derived.inInbox { mailboxes.insert("inbox") }
        if derived.hasVisible && !derived.inInbox && derived.row.messageCount > 0 { mailboxes.insert("done") }
        if derived.sentAt != nil { mailboxes.insert("sent") }
        if derived.trashAt != nil { mailboxes.insert("trash") }
        if derived.spamAt != nil { mailboxes.insert("spam") }
        if derived.snooze != nil { mailboxes.insert("snoozed") }
        if !derived.drafts.isEmpty { mailboxes.insert("drafts") }
        if flags.contains("starred") { mailboxes.insert("starred") }
        if flags.contains("important") { mailboxes.insert("important") }
        if derived.scheduledSendAt != nil { mailboxes.insert("scheduled") }
        if reminders[thread.key] != nil { mailboxes.insert("reminders") }
        if derived.waitingAt != nil { mailboxes.insert("waiting") }
        let lists = thread.messages.compactMap { $0.listID?.lowercased() }
        return FakeQuery.Facts(senders: senders, recipients: recipients, subject: subject, text: text,
                               labelNames: labelNames, listIDs: lists, flags: flags, has: has, mailboxes: mailboxes)
    }

    func sortKey(_ location: MailLocation, _ d: DerivedThread) -> Date? {
        let epoch = Date(timeIntervalSince1970: 0)
        switch location {
        case .system(.inbox): return d.inInbox ? d.inboxSortAt : nil
        case .system(.starred): return d.visibleLabels.contains(FakeLabels.starred) ? d.lastAt : nil
        case .system(.important): return d.visibleLabels.contains(FakeLabels.important) ? d.lastAt : nil
        case .system(.unread): return d.hasVisible && d.row.isUnread ? d.lastAt : nil
        case .system(.sent): return d.sentAt
        case .system(.drafts): return d.draftAt
        case .system(.allMail): return d.hasVisible ? d.lastAt : nil
        case .system(.done): return d.hasVisible && !d.inInbox && d.row.messageCount > 0 ? d.lastAt : nil
        case .system(.trash): return d.trashAt
        case .system(.spam): return d.spamAt
        case .system(.snoozed): return d.snooze.map { $0.wakeAt ?? epoch }
        case .system(.scheduled): return d.scheduledSendAt
        case .system(.reminders): return reminders[d.row.id]?.dueAt
        case .system(.waiting): return d.waitingAt
        case .label(let id): return d.visibleLabels.contains(id) ? d.lastAt : nil
        case .split(let id): return d.inInbox && d.split == id ? d.inboxSortAt : nil
        case .splitOther: return d.inInbox && d.split == nil ? d.inboxSortAt : nil
        case .reviewQueue(nil): return d.reviewAt
        case .reviewQueue(let ids?): return d.drafts.union(d.pendingReview).isDisjoint(with: ids) ? nil : (d.draftAt ?? d.reviewAt)
        case .search: return nil
        }
    }

    mutating func entries(_ location: MailLocation, account: AccountID) throws -> [WindowEntry] {
        let cacheKey = WindowCacheKey(account: account, location: location)
        if let cached = windowCache[cacheKey] { return cached }
        var result: [WindowEntry] = []
        if case .search(let text) = location {
            let lexical = try searchEntries(text, accounts: [account])
            let related = relatedEntries(text, account: account, excluding: Set(lexical.map(\.row.id)))
            let mark: SearchMatchKind? = related.isEmpty ? nil : .lexical
            result = lexical.map { WindowEntry(sortAt: $0.row.lastMessageAt, key: $0.row.id, match: mark) } + related
        } else {
            for key in threadOrder[account] ?? [] {
                guard let d = derived(key), let at = sortKey(location, d) else { continue }
                result.append(WindowEntry(sortAt: at, key: key))
            }
            if location.sortsAscending {
                result.sort { ($0.sortAt, $0.key.rowID) < ($1.sortAt, $1.key.rowID) }
            } else {
                result.sort { ($0.sortAt, $0.key.rowID) > ($1.sortAt, $1.key.rowID) }
            }
        }
        windowCache[cacheKey] = result
        return result
    }

    mutating func row(_ entry: WindowEntry) -> ThreadRow? {
        derived(entry.key)?.row.with(sortAt: entry.sortAt).with(searchMatch: entry.match)
    }

    mutating func searchEntries(_ text: String, accounts selected: [AccountID]?) throws -> [SearchHitInfo] {
        let query = try FakeQuery.parse(text, mode: .search)
        let includeHidden = query.includesTrashOrSpam
        var hits: [SearchHitInfo] = []
        for accountID in (selected ?? Array(accounts.keys)).sorted() {
            guard let account = accounts[accountID] else { continue }
            for key in threadOrder[accountID] ?? [] {
                guard let d = derived(key), let thread = threads[key], d.hasVisible || includeHidden else { continue }
                let views = views(thread)
                guard query.matches(facts(thread: thread, views: views, derived: d, account: account)) else { continue }
                let matched = views.filter { includeHidden || FakeAggregator.isVisible($0.labels) }.map(\.summary.id.rowID)
                hits.append(SearchHitInfo(row: d.row, matchedMessageRowIDs: matched, highlight: d.row.snippet))
            }
        }
        hits.sort { ($0.row.lastMessageAt, $0.row.id.rowID) > ($1.row.lastMessageAt, $1.row.id.rowID) }
        return hits
    }

    mutating func detail(_ key: ThreadKey) -> ConversationDetail? {
        guard let thread = threads[key], let d = derived(key) else { return nil }
        let views = views(thread)
        let shown = d.hasVisible ? views.filter { FakeAggregator.isVisible($0.labels) } : views
        let threadDrafts = (draftsByThread[key] ?? []).compactMap { drafts[$0] }
            .filter { $0.isListed || $0.summary.review == .pending }
            .map(\.summary).sorted { ($0.updatedAt, $0.id.rawValue) < ($1.updatedAt, $1.id.rawValue) }
        let reminder = reminders[key].map {
            ReminderItem(id: $0.id, thread: key, subject: thread.subject, dueAt: $0.dueAt, kind: $0.kind)
        }
        return ConversationDetail(id: key, subject: thread.subject, messages: shown.map(\.summary), drafts: threadDrafts,
                                  userLabelIDs: d.row.userLabelIDs, snooze: d.snooze, reminder: reminder,
                                  isStarred: d.row.isStarred)
    }

    mutating func tally(_ accountID: AccountID) -> (labels: [LabelInfo], counts: MailboxCountsInfo, splitTotals: [SplitKey: Int])? {
        guard let account = accounts[accountID] else { return nil }
        var byID: [GmailLabelID: (total: Int, unread: Int)] = [:]
        var inboxUnread = 0
        var importantUnread = 0
        var splitUnread: [SplitKey: Int] = [:]
        var splitTotal: [SplitKey: Int] = [:]
        func count(_ id: GmailLabelID, unread: Bool) {
            var t = byID[id] ?? (0, 0)
            t.total += 1
            if unread { t.unread += 1 }
            byID[id] = t
        }
        for key in threadOrder[accountID] ?? [] {
            guard let d = derived(key) else { continue }
            let unread = d.row.isUnread
            for id in d.visibleLabels { count(id, unread: unread) }
            if d.sentAt != nil, !d.visibleLabels.contains(FakeLabels.sent) { count(FakeLabels.sent, unread: unread) }
            if d.trashAt != nil { count(FakeLabels.trash, unread: unread) }
            if d.spamAt != nil { count(FakeLabels.spam, unread: unread) }
            if d.hasVisible { count(GmailLabelID("oh:allmail"), unread: unread) }
            if d.snooze != nil { count(GmailLabelID("oh:snoozed"), unread: unread) }
            if d.scheduledSendAt != nil { count(GmailLabelID("oh:scheduled"), unread: unread) }
            if reminders[key] != nil { count(GmailLabelID("oh:reminders"), unread: unread) }
            if d.waitingAt != nil { count(GmailLabelID("oh:waiting"), unread: false) }
            if !d.drafts.isEmpty { count(FakeLabels.draft, unread: false) }
            if d.inInbox {
                if unread { inboxUnread += 1 }
                if unread, d.row.isImportant { importantUnread += 1 }
                if let split = d.split {
                    splitTotal[split, default: 0] += 1
                    if unread { splitUnread[split, default: 0] += 1 }
                }
            }
        }
        var tallies: [Int64: LabelTally] = [:]
        let labels = account.labels.map { label -> LabelInfo in
            let t = byID[label.labelID] ?? (0, 0)
            tallies[label.id] = LabelTally(total: t.total, unread: t.unread)
            return LabelInfo(id: label.id, account: label.account, labelID: label.labelID, kind: label.kind,
                             name: label.name, displayName: label.displayName, colorBackground: label.colorBackground,
                             colorText: label.colorText, isHidden: label.isHidden, position: label.position,
                             totalThreads: t.total, unreadThreads: t.unread)
        }.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
        let accountDrafts = drafts.values.filter { $0.account == accountID }
        let counts = MailboxCountsInfo(
            account: accountID, byLabel: tallies, inboxUnread: inboxUnread,
            splitUnread: Dictionary(uniqueKeysWithValues: account.splits.map { ($0.id, splitUnread[$0.id] ?? 0) }),
            draftsCount: accountDrafts.filter(\.isListed).count,
            pendingReviewCount: accountDrafts.filter { $0.summary.review == .pending && $0.status != .sending }.count,
            failedOperationCount: failures.filter { $0.account == accountID }.count, importantUnread: importantUnread)
        return (labels, counts, splitTotal)
    }

    mutating func splitInfos(_ accountID: AccountID) -> [SplitInfo]? {
        guard let tally = tally(accountID), let account = accounts[accountID] else { return nil }
        let totals = tally.splitTotals, unread = tally.counts.splitUnread
        return account.splits.sorted { ($0.position, $0.id.rawValue) < ($1.position, $1.id.rawValue) }.map {
            SplitInfo(id: $0.id, account: $0.account, name: $0.name, position: $0.position, ruleText: $0.ruleText,
                      enabled: $0.enabled, unreadThreads: unread[$0.id] ?? 0, totalThreads: totals[$0.id] ?? 0)
        }
    }

    func draftSummaries(_ account: AccountID?, where include: (FakeDraft) -> Bool) -> [DraftSummary] {
        drafts.values.filter { (account == nil || $0.account == account) && include($0) }.map(\.summary)
            .sorted { ($0.updatedAt, $0.id.rawValue) > ($1.updatedAt, $1.id.rawValue) }
    }

    func reminderItems(_ account: AccountID?) -> [ReminderItem] {
        reminders.values.filter { account == nil || $0.thread.account == account }
            .map { ReminderItem(id: $0.id, thread: $0.thread, subject: threads[$0.thread]?.subject ?? "",
                                dueAt: $0.dueAt, kind: $0.kind) }
            .sorted { ($0.dueAt, $0.id) < ($1.dueAt, $1.id) }
    }
}
