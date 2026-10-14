import Foundation

public struct AccountID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public init(_ rawValue: Int64) { self.rawValue = rawValue }
    public static func < (lhs: AccountID, rhs: AccountID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct GmailMessageID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct GmailThreadID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct GmailLabelID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct GmailDraftID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct HistoryID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public static func < (lhs: HistoryID, rhs: HistoryID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct DraftID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct SplitID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct EmailAddress: Hashable, Codable, Sendable {
    public var name: String?
    public var email: String
    public init(name: String? = nil, email: String) {
        self.name = name
        self.email = email
    }
}
