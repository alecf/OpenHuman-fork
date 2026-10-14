import Foundation

public enum SearchMatchKind: String, Sendable, Hashable, Codable {
    case lexical
    case related
}

public struct SmartSearchStatus: Sendable, Hashable {
    public enum PauseReason: String, Sendable, Hashable {
        case lowPower, hot, lowDisk
    }

    public enum Phase: Sendable, Hashable {
        case off
        case indexing
        case paused(PauseReason)
        case ready
    }

    public var phase: Phase
    public var fraction: Double

    public init(phase: Phase = .off, fraction: Double = 0) {
        self.phase = phase
        self.fraction = min(1, max(0, fraction))
    }

    public static let off = SmartSearchStatus()
    public static let ready = SmartSearchStatus(phase: .ready, fraction: 1)

    public var addsRelatedResults: Bool { phase != .off }
}

extension ThreadRow {
    public func with(searchMatch: SearchMatchKind?) -> ThreadRow {
        searchMatch == self.searchMatch ? self : ThreadRow(
            id: id, subject: subject, snippet: snippet, participantsDisplay: participantsDisplay,
            participants: participants, messageCount: messageCount, unreadCount: unreadCount, draftCount: draftCount,
            attachmentCount: attachmentCount, isUnread: isUnread, isStarred: isStarred, isImportant: isImportant,
            userLabelIDs: userLabelIDs, lastMessageAt: lastMessageAt, sortAt: sortAt, snoozedUntil: snoozedUntil,
            reminderAt: reminderAt, scheduledSendAt: scheduledSendAt, hasPendingChanges: hasPendingChanges,
            categoryLabelIDs: categoryLabelIDs, searchMatch: searchMatch)
    }
}
