import CryptoKit
import Foundation

public struct DevFeedbackSnapshot: Codable, Sendable, Hashable {
    public struct AppInfo: Codable, Sendable, Hashable {
        public var version: String
        public var build: String
        public var gitCommit: String
        public var configuration: String
        public var dataMode: String
        public var devFeedbackEnabledBy: String
        public var os: String

        public init(version: String, build: String, gitCommit: String, configuration: String, dataMode: String,
                    devFeedbackEnabledBy: String, os: String) {
            self.version = version
            self.build = build
            self.gitCommit = gitCommit
            self.configuration = configuration
            self.dataMode = dataMode
            self.devFeedbackEnabledBy = devFeedbackEnabledBy
            self.os = os
        }
    }

    public struct SyncRun: Codable, Sendable, Hashable {
        public var at: Date
        public var kind: String
        public var outcome: String?
        public var requests: Int
        public var added: Int
        public var changed: Int
        public var deleted: Int
        public var errorCode: String?

        public init(at: Date, kind: String, outcome: String?, requests: Int, added: Int, changed: Int, deleted: Int,
                    errorCode: String?) {
            self.at = at
            self.kind = kind
            self.outcome = outcome
            self.requests = requests
            self.added = added
            self.changed = changed
            self.deleted = deleted
            self.errorCode = errorCode
        }
    }

    public struct AccountInfo: Codable, Sendable, Hashable {
        public var index: Int
        public var idHash: String
        public var health: String?
        public var connectivity: String?
        public var syncPhase: String?
        public var lastSyncAt: Date?
        public var consecutiveFailures: Int?
        public var syncErrorCode: String?
        public var historyID: String?
        public var threadCount: Int?
        public var messageCount: Int?
        public var inboxThreads: Int?
        public var inboxUnreadThreads: Int?
        public var pendingOperations: Int?
        public var failedOperations: Int?
        public var recentSync: [SyncRun]?

        public init(index: Int, idHash: String, health: String? = nil, connectivity: String? = nil,
                    syncPhase: String? = nil, lastSyncAt: Date? = nil, consecutiveFailures: Int? = nil,
                    syncErrorCode: String? = nil, historyID: String? = nil, threadCount: Int? = nil,
                    messageCount: Int? = nil, inboxThreads: Int? = nil, inboxUnreadThreads: Int? = nil,
                    pendingOperations: Int? = nil, failedOperations: Int? = nil, recentSync: [SyncRun]? = nil) {
            self.index = index
            self.idHash = idHash
            self.health = health
            self.connectivity = connectivity
            self.syncPhase = syncPhase
            self.lastSyncAt = lastSyncAt
            self.consecutiveFailures = consecutiveFailures
            self.syncErrorCode = syncErrorCode
            self.historyID = historyID
            self.threadCount = threadCount
            self.messageCount = messageCount
            self.inboxThreads = inboxThreads
            self.inboxUnreadThreads = inboxUnreadThreads
            self.pendingOperations = pendingOperations
            self.failedOperations = failedOperations
            self.recentSync = recentSync
        }
    }

    public struct StatusInfo: Codable, Sendable, Hashable {
        public var syncText: String?
    }

    public struct ListInfo: Codable, Sendable, Hashable {
        public var location: String
        public var state: String
        public var rows: Int
        public var totalCount: Int
        public var hasMore: Bool
        public var unreadRows: Int
        public var loadedMessages: Int
        public var cursorIndex: Int?
        public var cursorThreadID: String?
    }

    public struct ReaderMessage: Codable, Sendable, Hashable {
        public var messageID: String
        public var isExpanded: Bool
        public var isUnread: Bool
        public var body: String
        public var hasRemoteContent: Bool?
        public var blockedRemote: Int?
        public var trackers: Int?
        public var renderHash: String?
    }

    public struct ReaderInfo: Codable, Sendable, Hashable {
        public var threadID: String
        public var threadRowID: Int64
        public var state: String
        public var messageCount: Int
        public var expandedCount: Int
        public var focusedMessageID: String?
        public var mode: String
        public var imagePolicy: String
        public var messages: [ReaderMessage]
    }

    public struct ThemeInfo: Codable, Sendable, Hashable {
        public var themeID: String
        public var appearance: String
        public var mode: String
        public var accentID: String?

        public init(themeID: String, appearance: String, mode: String, accentID: String?) {
            self.themeID = themeID
            self.appearance = appearance
            self.mode = mode
            self.accentID = accentID
        }
    }

    public struct Command: Codable, Sendable, Hashable {
        public var at: Date
        public var id: String
    }

    public struct ErrorEntry: Codable, Sendable, Hashable {
        public var at: Date?
        public var source: String
        public var message: String
    }

    public var capturedAtUTC: String
    public var capturedAtLocal: String
    public var timeZone: String
    public var app: AppInfo
    public var screen: String
    public var route: String
    public var status: StatusInfo?
    public var accountCount: Int
    public var accounts: [AccountInfo]
    public var list: ListInfo?
    public var reader: ReaderInfo?
    public var theme: ThemeInfo?
    public var recentCommands: [Command]
    public var checklistViewing: String?
    public var recentErrors: [ErrorEntry]
    public var calendars: [DiagnosticsCalendarEntry]? = nil
    public var keychain: KeychainInfo? = nil

    public struct KeychainInfo: Codable, Sendable, Hashable {
        public struct Entry: Codable, Sendable, Hashable {
            public var subject: String
            public var stores: [String]

            public init(subject: String, stores: [String]) {
                self.subject = subject
                self.stores = stores
            }
        }
        public var entries: [Entry]
        public var lastStatus: String

        public init(entries: [Entry], lastStatus: String) {
            self.entries = entries
            self.lastStatus = lastStatus
        }
    }
}

public enum DevFeedbackHash {
    public static func account(_ email: String) -> String {
        SHA256.hash(data: Data(email.lowercased().utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }
}

extension DevFeedbackSnapshot {
    static func utcString(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func localString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
