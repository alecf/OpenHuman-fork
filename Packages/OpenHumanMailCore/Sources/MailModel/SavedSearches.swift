import Foundation
import OpenHumanCore

public struct SavedSearch: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var query: String
    public var createdAt: Int64

    public init(id: String = UUID().uuidString, name: String, query: String, createdAt: Int64) {
        self.id = id
        self.name = name
        self.query = query
        self.createdAt = createdAt
    }

    public static let maxPerAccount = 50
    public static let nameLimit = 60

    public static func defaultName(for query: String) -> String {
        let line = query.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > nameLimit ? String(line.prefix(nameLimit - 1)) + "…" : line
    }
}

extension AppSettings {
    public static func savedSearches(_ account: AccountID) -> AppSettingKey<[SavedSearch]> {
        AppSettingKey(name: "search.saved", scope: .account(account), defaultValue: [])
    }
}

extension MailDataSource {
    public func recentThreads(involving email: String, account: AccountID, limit: Int) async throws -> [ThreadRow] {
        throw MailPortError.unsupported("recentThreads")
    }
}
