import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFakes

private func relatedStore(_ on: Bool) -> FakeMailStore {
    FakeMailStore(corpus: .rich(threadCount: 120, now: fixedNow),
                  options: .init(remoteAck: .manual, heldSends: .manual, now: { fixedNow }, relatedSearchMatches: on))
}

@Test func relatedRuleIsOffByDefault() async throws {
    let store = relatedStore(false)
    let rows = try await window(store, .search("retreat")).rows
    #expect(rows.isEmpty, "no thread uses the word, and the rule is off")
    #expect(try await window(store, .search("offsite")).rows.allSatisfy { $0.searchMatch == nil })
    #expect(await first(store.smartSearchStatus()) == SmartSearchStatus.off)
}

@Test func relatedRowsFollowTheWordMatchesMarked() async throws {
    let store = relatedStore(true)
    let related = try await window(store, .search("retreat")).rows
    #expect(!related.isEmpty)
    #expect(related.allSatisfy { $0.searchMatch == .related })
    #expect(related.contains { $0.subject.lowercased().contains("offsite") })
    #expect(related.count <= FakeRelatedMatch.limit)
    let lexical = try await window(store, .search("offsite")).rows
    #expect(!lexical.isEmpty && lexical.allSatisfy { $0.searchMatch == nil })
    let mixed = try await window(store, .search("trip")).rows
    if let firstRelated = mixed.firstIndex(where: { $0.searchMatch == .related }) {
        #expect(mixed[..<firstRelated].allSatisfy { $0.searchMatch == .lexical })
        #expect(mixed[firstRelated...].allSatisfy { $0.searchMatch == .related })
    }
    #expect(await first(store.smartSearchStatus()) == SmartSearchStatus.ready)
}

@Test func exactQueriesNeverGetRelatedRows() {
    #expect(FakeRelatedMatch.queries("\"retreat\"").isEmpty, "a quoted phrase is exact intent")
    #expect(FakeRelatedMatch.queries("from:retreat").isEmpty, "operators are not free text")
    #expect(FakeRelatedMatch.queries("rfc822msgid:abc retreat").isEmpty)
    #expect(FakeRelatedMatch.queries("-retreat").isEmpty)
    #expect(FakeRelatedMatch.queries("is:unread retreat") == ["is:unread offsite"], "the rest of the query still applies")
    #expect(FakeRelatedMatch.queries("receipt") == ["\"order confirmation\"", "invoice"])
    #expect(FakeRelatedMatch.tokenize("a \"b c\" d") == ["a", "\"b c\"", "d"])
}

@Test func smartSearchStatusHookAndSwitch() async throws {
    let store = relatedStore(false)
    store.setSmartSearchStatus(SmartSearchStatus(phase: .indexing, fraction: 0.42))
    #expect(await first(store.smartSearchStatus()) == SmartSearchStatus(phase: .indexing, fraction: 0.42))
    store.setRelatedSearchMatches(true)
    #expect(await first(store.smartSearchStatus()) == SmartSearchStatus.ready)
    #expect(try await window(store, .search("retreat")).rows.allSatisfy { $0.searchMatch == .related })
    store.setRelatedSearchMatches(false)
    #expect(try await window(store, .search("retreat")).rows.isEmpty)
}
