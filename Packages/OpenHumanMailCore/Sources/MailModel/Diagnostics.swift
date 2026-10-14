import Foundation
import OpenHumanCore

public enum UnsubscribeInfo: Sendable, Hashable {
    case oneClick(host: String)
    case mailto(EmailAddress, subject: String?)
    case link(URL)
}

public struct DiagnosticsSnapshot: Sendable, Codable, Hashable {
    public struct AccountEntry: Sendable, Codable, Hashable {
        public var index: Int
        public var health: String
        public var connectivity: String
        public var lastSyncAt: Date?
        public var consecutiveFailures: Int
        public var threadCount: Int
        public var messageCount: Int
        public var draftCount: Int
        public var pendingOperations: Int
        public var failedOperations: Int

        public init(index: Int, health: String, connectivity: String, lastSyncAt: Date? = nil,
                    consecutiveFailures: Int = 0, threadCount: Int, messageCount: Int, draftCount: Int,
                    pendingOperations: Int, failedOperations: Int) {
            self.index = index
            self.health = health
            self.connectivity = connectivity
            self.lastSyncAt = lastSyncAt
            self.consecutiveFailures = consecutiveFailures
            self.threadCount = threadCount
            self.messageCount = messageCount
            self.draftCount = draftCount
            self.pendingOperations = pendingOperations
            self.failedOperations = failedOperations
        }
    }

    public struct OperationTally: Sendable, Codable, Hashable {
        public var kind: String
        public var status: String
        public var count: Int

        public init(kind: String, status: String, count: Int) {
            self.kind = kind
            self.status = status
            self.count = count
        }
    }

    public struct ErrorTally: Sendable, Codable, Hashable {
        public var code: String
        public var count: Int
        public var lastAt: Date?

        public init(code: String, count: Int, lastAt: Date? = nil) {
            self.code = code
            self.count = count
            self.lastAt = lastAt
        }
    }

    public var generatedAt: Date
    public var safeMode: String
    public var schemaVersion: Int?
    public var accounts: [AccountEntry]
    public var operations: [OperationTally]
    public var recentErrors: [ErrorTally]

    public init(generatedAt: Date, safeMode: String, schemaVersion: Int? = nil, accounts: [AccountEntry],
                operations: [OperationTally] = [], recentErrors: [ErrorTally] = []) {
        self.generatedAt = generatedAt
        self.safeMode = safeMode
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.operations = operations
        self.recentErrors = recentErrors
    }
}
