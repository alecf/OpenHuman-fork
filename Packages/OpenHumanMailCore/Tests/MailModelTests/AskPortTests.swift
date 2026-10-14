import Foundation
import OpenHumanCore
import Testing
@testable import MailModel

@Test func searchOnceIsTheFirstAnswerOfSearchAndRemoteSearchFailsLoudly() async throws {
    struct Searching: MailDataSource {
        func accounts() -> AsyncThrowingStream<[Account], Error> { AsyncThrowingStream { $0.finish() } }
        func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> { AsyncThrowingStream { $0.finish() } }
        func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> { AsyncThrowingStream { $0.finish() } }
        func search(_ query: String, accounts: [AccountID]?, limit: Int) -> AsyncThrowingStream<SearchResultsInfo, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(SearchResultsInfo(hits: [], hasMore: query == "first"))
                continuation.yield(SearchResultsInfo(hits: [], hasMore: false))
            }
        }
    }
    let source = Searching()
    let once = try await source.searchOnce("first", semanticText: "ignored by a lexical source", accounts: nil, limit: 5)
    #expect(once.hasMore, "the live search's first answer")
    #expect(once.completeness == .complete && once.completeness.isComplete, "a source that does not say is complete")
    await #expect(throws: MailPortError.unsupported("remoteSearch")) {
        _ = try await source.remoteSearch(gmailQuery: "dentist", account: AccountID(1), maxResults: 20)
    }

    struct Minimal: MailDataSource {
        func accounts() -> AsyncThrowingStream<[Account], Error> { AsyncThrowingStream { $0.finish() } }
        func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> { AsyncThrowingStream { $0.finish() } }
        func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> { AsyncThrowingStream { $0.finish() } }
    }
    await #expect(throws: MailPortError.unsupported("search"), "no search: the one-shot search says so too") {
        _ = try await Minimal().searchOnce("x", semanticText: nil, accounts: nil, limit: 5)
    }
}

@Test func searchResultsCarryTheLocalIndexCoverage() {
    let back = Date(timeIntervalSince1970: 1_710_000_000)
    let incomplete = SearchResultsInfo(hits: [], hasMore: false,
                                       completeness: SearchCompletenessInfo(reasons: [.olderMailNotLocal(searchedBack: back)]))
    #expect(!incomplete.completeness.isComplete)
    #expect(incomplete.completeness.reasons == [.olderMailNotLocal(searchedBack: back)])
    #expect(SearchResultsInfo(hits: [], hasMore: true).completeness == .complete)
}
