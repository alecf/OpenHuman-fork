import Foundation
import OpenHumanCore

public struct LabelInfo: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case system
        case category
        case user
        case virtual
        case split
    }

    public let id: Int64
    public let account: AccountID
    public let labelID: GmailLabelID
    public let kind: Kind
    public let name: String
    public let displayName: String
    public let colorBackground: String?
    public let colorText: String?
    public let isHidden: Bool
    public let position: Int
    public let totalThreads: Int
    public let unreadThreads: Int

    public init(id: Int64, account: AccountID, labelID: GmailLabelID, kind: Kind, name: String, displayName: String,
                colorBackground: String? = nil, colorText: String? = nil, isHidden: Bool = false, position: Int,
                totalThreads: Int = 0, unreadThreads: Int = 0) {
        self.id = id
        self.account = account
        self.labelID = labelID
        self.kind = kind
        self.name = name
        self.displayName = displayName
        self.colorBackground = colorBackground
        self.colorText = colorText
        self.isHidden = isHidden
        self.position = position
        self.totalThreads = totalThreads
        self.unreadThreads = unreadThreads
    }
}

public struct SplitInfo: Identifiable, Sendable, Hashable {
    public let id: SplitKey
    public let account: AccountID
    public let name: String
    public let position: Int
    public let ruleText: String
    public let enabled: Bool
    public let unreadThreads: Int
    public let totalThreads: Int

    public init(id: SplitKey, account: AccountID, name: String, position: Int, ruleText: String, enabled: Bool = true,
                unreadThreads: Int = 0, totalThreads: Int = 0) {
        self.id = id
        self.account = account
        self.name = name
        self.position = position
        self.ruleText = ruleText
        self.enabled = enabled
        self.unreadThreads = unreadThreads
        self.totalThreads = totalThreads
    }
}

public struct SplitDefinition: Sendable, Hashable {
    public var account: AccountID
    public var id: SplitKey?
    public var name: String
    public var ruleText: String
    public var position: Int?
    public var enabled: Bool

    public init(account: AccountID, id: SplitKey? = nil, name: String, ruleText: String, position: Int? = nil,
                enabled: Bool = true) {
        self.account = account
        self.id = id
        self.name = name
        self.ruleText = ruleText
        self.position = position
        self.enabled = enabled
    }
}

public struct LabelTally: Sendable, Hashable {
    public let total: Int
    public let unread: Int

    public init(total: Int, unread: Int) {
        self.total = total
        self.unread = unread
    }
}

public struct MailboxCountsInfo: Sendable, Hashable {
    public let account: AccountID
    public let byLabel: [Int64: LabelTally]
    public let inboxUnread: Int
    public let splitUnread: [SplitKey: Int]
    public let draftsCount: Int
    public let pendingReviewCount: Int
    public let failedOperationCount: Int
    public let importantUnread: Int?

    public init(account: AccountID, byLabel: [Int64: LabelTally], inboxUnread: Int, splitUnread: [SplitKey: Int],
                draftsCount: Int, pendingReviewCount: Int, failedOperationCount: Int, importantUnread: Int? = nil) {
        self.account = account
        self.byLabel = byLabel
        self.inboxUnread = inboxUnread
        self.splitUnread = splitUnread
        self.draftsCount = draftsCount
        self.pendingReviewCount = pendingReviewCount
        self.failedOperationCount = failedOperationCount
        self.importantUnread = importantUnread
    }

    public var otherUnread: Int { max(0, inboxUnread - splitUnread.values.reduce(0, +)) }

    public func otherTotal(labels: [LabelInfo], splits: [SplitInfo]) -> Int? {
        if let row = labels.first(where: { $0.labelID == Self.otherLabelID }) { return byLabel[row.id]?.total ?? row.totalThreads }
        guard let inbox = labels.first(where: { $0.labelID == GmailLabelID("INBOX") }) else { return nil }
        let inboxTotal = byLabel[inbox.id]?.total ?? inbox.totalThreads
        return max(0, inboxTotal - splits.filter(\.enabled).reduce(0) { $0 + $1.totalThreads })
    }

    public static let otherLabelID = GmailLabelID("oh:split:other")
}
