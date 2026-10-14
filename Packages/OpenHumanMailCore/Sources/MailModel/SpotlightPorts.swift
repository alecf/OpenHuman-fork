import Foundation

public struct SpotlightItem: Sendable, Hashable {
    public let identifier: String
    public let domain: String
    public let title: String
    public let summary: String
    public let authorName: String
    public let date: Date
    public let keywords: [String]
    public let isImportant: Bool

    public init(identifier: String, domain: String, title: String, summary: String, authorName: String, date: Date,
                keywords: [String], isImportant: Bool) {
        self.identifier = identifier
        self.domain = domain
        self.title = title
        self.summary = summary
        self.authorName = authorName
        self.date = date
        self.keywords = keywords
        self.isImportant = isImportant
    }
}

public protocol SpotlightIndexing: Sendable {
    func index(_ items: [SpotlightItem]) async throws
    func delete(identifiers: [String]) async throws
    func delete(domains: [String]) async throws
    func deleteAll() async throws
}
