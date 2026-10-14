import CoreSpotlight
import Foundation
import MailModel
import Testing
@testable import MailUIMac

struct CoreSpotlightMappingTests {
    private let item = SpotlightItem(identifier: "oh.thread.1.abc", domain: "oh.account.1", title: "Mail from Ada",
                                     summary: "Important · Atlas", authorName: "Ada", date: Date(timeIntervalSince1970: 1_791_000_000),
                                     keywords: ["Important", "Atlas"], isImportant: true)

    @Test func attributesCarryOnlyTheItemsMetadata() {
        let set = CoreSpotlightIndex.attributes(for: item)
        #expect(set.title == "Mail from Ada" && set.displayName == "Mail from Ada")
        #expect(set.contentDescription == "Important · Atlas")
        #expect(set.authorNames == ["Ada"] && set.keywords == ["Important", "Atlas"])
        #expect(set.contentModificationDate == item.date)
        #expect(set.rankingHint?.intValue == 1)
        #expect(set.textContent == nil && set.emailAddresses == nil && set.authorEmailAddresses == nil && set.htmlContentData == nil)
        #expect(set.contentURL == nil)
    }

    @Test func theSearchableItemKeepsIdentifierDomainAndDoesNotExpire() {
        let searchable = CoreSpotlightIndex.searchableItem(for: item)
        #expect(searchable.uniqueIdentifier == "oh.thread.1.abc" && searchable.domainIdentifier == "oh.account.1")
        #expect(searchable.expirationDate == .distantFuture)
    }
}
