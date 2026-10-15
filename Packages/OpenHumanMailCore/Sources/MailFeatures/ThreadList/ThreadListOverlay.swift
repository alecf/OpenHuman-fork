import Foundation
import MailModel
import OpenHumanCore

public struct RowPatch: Sendable, Hashable {
    public var isUnread: Bool?
    public var isStarred: Bool?
    public var reminderAt: Date??
    public var snoozedUntil: Date??
    public var addUserLabels: Set<Int64>
    public var removeUserLabels: Set<Int64>

    public init(isUnread: Bool? = nil, isStarred: Bool? = nil, reminderAt: Date?? = nil, snoozedUntil: Date?? = nil,
                addUserLabels: Set<Int64> = [], removeUserLabels: Set<Int64> = []) {
        self.isUnread = isUnread
        self.isStarred = isStarred
        self.reminderAt = reminderAt
        self.snoozedUntil = snoozedUntil
        self.addUserLabels = addUserLabels
        self.removeUserLabels = removeUserLabels
    }

    public var isEmpty: Bool {
        isUnread == nil && isStarred == nil && reminderAt == nil && snoozedUntil == nil && addUserLabels.isEmpty
            && removeUserLabels.isEmpty
    }

    public func applied(to row: ThreadRow) -> ThreadRow {
        var labels = row.userLabelIDs
        if !addUserLabels.isEmpty || !removeUserLabels.isEmpty {
            labels.removeAll { removeUserLabels.contains($0) }
            for id in addUserLabels.sorted() where !labels.contains(id) { labels.append(id) }
        }
        let unread = isUnread ?? row.isUnread
        return row.replacing(
            unreadCount: unread == row.isUnread ? row.unreadCount : (unread ? max(1, row.unreadCount) : 0),
            isUnread: unread, isStarred: isStarred ?? row.isStarred, userLabelIDs: labels,
            reminderAt: reminderAt ?? row.reminderAt, snoozedUntil: snoozedUntil ?? row.snoozedUntil)
    }

    public func isReflected(in row: ThreadRow) -> Bool {
        if let isUnread, row.isUnread != isUnread { return false }
        if let isStarred, row.isStarred != isStarred { return false }
        if let reminderAt, row.reminderAt != reminderAt { return false }
        if let snoozedUntil, row.snoozedUntil != snoozedUntil { return false }
        if !addUserLabels.isSubset(of: row.userLabelIDs) { return false }
        if row.userLabelIDs.contains(where: removeUserLabels.contains) { return false }
        return true
    }

    func superseded(by newer: RowPatch) -> RowPatch {
        let relabeled = newer.addUserLabels.union(newer.removeUserLabels)
        return RowPatch(isUnread: newer.isUnread == nil ? isUnread : nil,
                        isStarred: newer.isStarred == nil ? isStarred : nil,
                        reminderAt: newer.reminderAt == nil ? reminderAt : nil,
                        snoozedUntil: newer.snoozedUntil == nil ? snoozedUntil : nil,
                        addUserLabels: addUserLabels.subtracting(relabeled),
                        removeUserLabels: removeUserLabels.subtracting(relabeled))
    }

    func merged(with other: RowPatch) -> RowPatch {
        RowPatch(isUnread: other.isUnread ?? isUnread, isStarred: other.isStarred ?? isStarred,
                 reminderAt: other.reminderAt ?? reminderAt, snoozedUntil: other.snoozedUntil ?? snoozedUntil,
                 addUserLabels: addUserLabels.subtracting(other.removeUserLabels).union(other.addUserLabels),
                 removeUserLabels: removeUserLabels.subtracting(other.addUserLabels).union(other.removeUserLabels))
    }
}

public struct OptimisticTicket: Hashable, Sendable {
    let id: Int
}

public struct OptimisticEffect: Sendable, Equatable {
    public var hidden: Set<ThreadKey> = []
    public var patches: [ThreadKey: RowPatch] = [:]

    public init(hidden: Set<ThreadKey> = [], patches: [ThreadKey: RowPatch] = [:]) {
        self.hidden = hidden
        self.patches = patches
    }

    public var isEmpty: Bool { hidden.isEmpty && patches.isEmpty }
    var keys: Set<ThreadKey> { hidden.union(patches.keys) }

    public static func of(_ command: MailCommand, in location: MailLocation,
                          labelRows: [GmailLabelID: Int64] = [:]) -> OptimisticEffect {
        let keys = command.threads
        func hide(_ condition: Bool) -> OptimisticEffect { condition ? OptimisticEffect(hidden: Set(keys)) : OptimisticEffect() }
        func patch(_ patch: RowPatch) -> OptimisticEffect {
            OptimisticEffect(patches: Dictionary(keys.map { ($0, patch) }, uniquingKeysWith: { $1 }))
        }
        let inboxLike = location.isInboxLike
        switch command {
        case .markDone:
            return hide(inboxLike)
        case .snooze(_, let until):
            // The store keeps wake times to the minute; matching it lets the patch settle
            return inboxLike ? hide(true) : patch(RowPatch(snoozedUntil: .some(ScheduleStamp.floorToMinute(until))))
        case .trash:
            return hide(location != .system(.trash))
        case .untrash:
            return hide(location == .system(.trash))
        case .markSpam:
            return hide(location != .system(.spam))
        case .markNotSpam:
            return hide(location == .system(.spam))
        case .unsnooze:
            let leaves = location == .system(.snoozed) || location == .system(.done)
            return leaves ? hide(true) : patch(RowPatch(snoozedUntil: .some(nil)))
        case .clearSnooze:
            return location == .system(.snoozed) ? hide(true) : patch(RowPatch(snoozedUntil: .some(nil)))
        case .moveToInbox:
            return hide(location == .system(.trash) || location == .system(.spam) || location == .system(.done))
        case .markRead:
            return patch(RowPatch(isUnread: false))
        case .markUnread:
            return patch(RowPatch(isUnread: true))
        case .star:
            return patch(RowPatch(isStarred: true))
        case .unstar:
            return patch(RowPatch(isStarred: false))
        case .setReminder(_, let dueAt, _):
            return patch(RowPatch(reminderAt: .some(dueAt)))
        case .cancelReminder:
            return location == .system(.reminders) ? hide(true) : patch(RowPatch(reminderAt: .some(nil)))
        case .modifyLabels(_, let add, let remove):
            var leaves = inboxLike && remove.contains(GmailLabelID("INBOX"))
            if case .label(let id) = location, remove.contains(id) { leaves = true }
            if location == .system(.done) && add.contains(GmailLabelID("INBOX")) { leaves = true }
            if add.contains(GmailLabelID("TRASH")) && location != .system(.trash) { leaves = true }
            if add.contains(GmailLabelID("SPAM")) && location != .system(.spam) { leaves = true }
            if leaves { return hide(true) }
            let added = Set(add.compactMap { labelRows[$0] }), removed = Set(remove.compactMap { labelRows[$0] })
            let change = RowPatch(addUserLabels: added, removeUserLabels: removed)
            return change.isEmpty ? OptimisticEffect() : patch(change)
        }
    }
}

extension MailLocation {
    public var isInboxLike: Bool {
        switch self {
        case .system(.inbox), .split, .splitOther: true
        default: false
        }
    }
}

public struct ThreadListOverlay: Sendable {
    public static let lifetime: TimeInterval = 10

    struct Entry: Sendable {
        let id: Int
        let createdAt: Date
        var hidden: Set<ThreadKey>
        var patches: [ThreadKey: RowPatch]

        var isSettled: Bool { hidden.isEmpty && patches.isEmpty }
    }

    private(set) var entries: [Entry] = []
    private var nextID = 1
    public private(set) var version = 0
    // Local-only reads (read-only mode): the store never confirms them, so they last until newer mail arrives
    public private(set) var localReads: [ThreadKey: Date] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    @discardableResult
    public mutating func markReadLocally(_ key: ThreadKey, through date: Date) -> Bool {
        if let known = localReads[key], known >= date { return false }
        localReads[key] = date
        version += 1
        return true
    }

    public func locallyRead(_ row: ThreadRow) -> ThreadRow {
        guard row.isUnread, let through = localReads[row.id], row.lastMessageAt <= through else { return row }
        return RowPatch(isUnread: false).applied(to: row)
    }

    public var hiddenKeys: Set<ThreadKey> {
        entries.reduce(into: Set<ThreadKey>()) { $0.formUnion($1.hidden) }
    }

    public var touchedKeys: Set<ThreadKey> {
        entries.reduce(into: Set<ThreadKey>()) { set, entry in
            set.formUnion(entry.hidden)
            set.formUnion(entry.patches.keys)
        }
    }

    public func patch(for key: ThreadKey) -> RowPatch? {
        var result: RowPatch?
        for entry in entries {
            guard let patch = entry.patches[key] else { continue }
            result = result.map { $0.merged(with: patch) } ?? patch
        }
        return result
    }

    public var earliestExpiry: Date? { entries.map(\.createdAt).min()?.addingTimeInterval(Self.lifetime) }

    @discardableResult
    public mutating func add(_ effect: OptimisticEffect, at now: Date) -> OptimisticTicket? {
        guard !effect.isEmpty else { return nil }
        for (key, patch) in effect.patches {
            for i in entries.indices {
                guard let older = entries[i].patches[key] else { continue }
                let rest = older.superseded(by: patch)
                entries[i].patches[key] = rest.isEmpty ? nil : rest
            }
        }
        entries.removeAll(where: \.isSettled)
        let id = nextID
        nextID += 1
        entries.append(Entry(id: id, createdAt: now, hidden: effect.hidden, patches: effect.patches))
        version += 1
        return OptimisticTicket(id: id)
    }

    @discardableResult
    public mutating func revert(_ ticket: OptimisticTicket) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == ticket.id }) else { return false }
        entries.remove(at: index)
        version += 1
        return true
    }

    @discardableResult
    public mutating func clear(keys: Set<ThreadKey>) -> Bool {
        var changed = false
        for i in entries.indices {
            let before = entries[i].hidden.count + entries[i].patches.count
            entries[i].hidden.subtract(keys)
            for key in keys { entries[i].patches.removeValue(forKey: key) }
            if entries[i].hidden.count + entries[i].patches.count != before { changed = true }
        }
        entries.removeAll(where: \.isSettled)
        if changed { version += 1 }
        return changed
    }

    @discardableResult
    mutating func relabel(_ swaps: [Int64: Int64]) -> Set<ThreadKey> {
        guard !swaps.isEmpty else { return [] }
        var touched = Set<ThreadKey>()
        for i in entries.indices {
            for (key, patch) in entries[i].patches {
                var next = patch
                next.addUserLabels = Set(patch.addUserLabels.map { swaps[$0] ?? $0 })
                next.removeUserLabels = Set(patch.removeUserLabels.map { swaps[$0] ?? $0 })
                guard next != patch else { continue }
                entries[i].patches[key] = next
                touched.insert(key)
            }
        }
        if !touched.isEmpty { version += 1 }
        return touched
    }

    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        let before = entries.count
        entries.removeAll { now.timeIntervalSince($0.createdAt) >= Self.lifetime }
        guard entries.count != before else { return false }
        version += 1
        return true
    }

    @discardableResult
    mutating func confirm(_ base: (ThreadKey) -> ThreadRow?) -> [Int] {
        var settled: [Int] = []
        for i in entries.indices {
            entries[i].hidden = entries[i].hidden.filter { base($0) != nil }
            entries[i].patches = entries[i].patches.filter { key, patch in
                guard let row = base(key) else { return false }
                return !patch.isReflected(in: row)
            }
            if entries[i].isSettled { settled.append(entries[i].id) }
        }
        entries.removeAll(where: \.isSettled)
        return settled
    }

    mutating func drop(settled ids: [Int]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        entries.removeAll { set.contains($0.id) }
    }

    public func apply(to rows: [ThreadRow]) -> (rows: [ThreadRow], hiddenCount: Int) {
        guard !entries.isEmpty || !localReads.isEmpty else { return (rows, 0) }
        let hidden = hiddenKeys
        var patches: [ThreadKey: RowPatch] = [:]
        for entry in entries {
            for (key, patch) in entry.patches { patches[key] = patches[key].map { $0.merged(with: patch) } ?? patch }
        }
        var result: [ThreadRow] = []
        result.reserveCapacity(rows.count)
        var hiddenCount = 0
        for row in rows {
            if hidden.contains(row.id) {
                hiddenCount += 1
                continue
            }
            let base = localReads.isEmpty ? row : locallyRead(row)
            result.append(patches[row.id].map { $0.applied(to: base) } ?? base)
        }
        return (result, hiddenCount)
    }
}

extension ThreadRow {
    public func replacing(unreadCount: Int? = nil, isUnread: Bool? = nil, isStarred: Bool? = nil,
                          userLabelIDs: [Int64]? = nil, reminderAt: Date?? = nil,
                          snoozedUntil: Date?? = nil) -> ThreadRow {
        ThreadRow(id: id, subject: subject, snippet: snippet, participantsDisplay: participantsDisplay,
                  participants: participants, messageCount: messageCount, unreadCount: unreadCount ?? self.unreadCount,
                  draftCount: draftCount, attachmentCount: attachmentCount, isUnread: isUnread ?? self.isUnread,
                  isStarred: isStarred ?? self.isStarred, isImportant: isImportant,
                  userLabelIDs: userLabelIDs ?? self.userLabelIDs, lastMessageAt: lastMessageAt, sortAt: sortAt,
                  snoozedUntil: snoozedUntil ?? self.snoozedUntil, reminderAt: reminderAt ?? self.reminderAt,
                  scheduledSendAt: scheduledSendAt, hasPendingChanges: hasPendingChanges,
                  categoryLabelIDs: categoryLabelIDs)
    }
}
