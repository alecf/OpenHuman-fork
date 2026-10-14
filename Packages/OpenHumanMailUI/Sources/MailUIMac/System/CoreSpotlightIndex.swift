import CoreSpotlight
import Foundation
import MailModel
import UniformTypeIdentifiers

public final class CoreSpotlightIndex: SpotlightIndexing, @unchecked Sendable {
    private let index: CSSearchableIndex

    public init(name: String = "openhuman.mail") {
        index = CSSearchableIndex(name: name)
    }

    public func index(_ items: [SpotlightItem]) async throws {
        try await index.indexSearchableItems(items.map(Self.searchableItem(for:)))
    }

    public func delete(identifiers: [String]) async throws {
        try await index.deleteSearchableItems(withIdentifiers: identifiers)
    }

    public func delete(domains: [String]) async throws {
        try await index.deleteSearchableItems(withDomainIdentifiers: domains)
    }

    public func deleteAll() async throws {
        try await index.deleteAllSearchableItems()
    }

    static func searchableItem(for item: SpotlightItem) -> CSSearchableItem {
        let searchable = CSSearchableItem(uniqueIdentifier: item.identifier, domainIdentifier: item.domain,
                                          attributeSet: attributes(for: item))
        searchable.expirationDate = .distantFuture
        return searchable
    }

    static func attributes(for item: SpotlightItem) -> CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .emailMessage)
        set.title = item.title
        set.displayName = item.title
        set.contentDescription = item.summary
        set.authorNames = [item.authorName]
        set.contentModificationDate = item.date
        set.contentCreationDate = item.date
        set.keywords = item.keywords
        set.rankingHint = NSNumber(value: item.isImportant ? 1 : 0)
        return set
    }
}
