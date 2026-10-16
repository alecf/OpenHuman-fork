import Foundation
import OpenHumanCore

public struct SearchQuery: Hashable, Codable, Sendable {
    public var text: String
    public var terms: [SearchTerm]

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        text: String,
        terms: [SearchTerm]
    ) {
        self.text = text
        self.terms = terms
    }
    // end generated-init
}
public indirect enum SearchTerm: Hashable, Codable, Sendable {
    case text(String, field: SearchField?)
    case address(AddressField, String)
    case label(String)
    case mailbox(SystemMailbox)
    case isFlag(SearchFlag)
    case has(SearchHas)
    case filename(String)
    case before(Date), after(Date)
    case larger(Int), smaller(Int)
    case listID(String)
    case rfc822msgid(String)
    case anywhere
    case not(SearchTerm), or([SearchTerm]), and([SearchTerm])
}
public enum SearchField: String, Codable, Sendable { case subject, body, participants, attachments }
public enum AddressField: String, Codable, Sendable { case from, to, cc, bcc }
public enum SearchFlag: String, Codable, Sendable { case unread, read, starred, important, draft, snoozed, event }
public enum SearchHas: String, Codable, Sendable { case attachment, invite, userLabels }

public struct SearchHit: Hashable, Sendable {
    public var thread: ThreadListItem
    public var matchedMessageIDs: [MessageRowID]
    public var highlight: String?
    public var sources: Set<SearchMatchSource> = [.lexical]
    public var bestMessageID: MessageRowID?
    public var scoreBreakdown: SearchScoreBreakdown?

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        thread: ThreadListItem,
        matchedMessageIDs: [MessageRowID],
        highlight: String? = nil,
        sources: Set<SearchMatchSource> = [.lexical],
        bestMessageID: MessageRowID? = nil,
        scoreBreakdown: SearchScoreBreakdown? = nil
    ) {
        self.thread = thread
        self.matchedMessageIDs = matchedMessageIDs
        self.highlight = highlight
        self.sources = sources
        self.bestMessageID = bestMessageID
        self.scoreBreakdown = scoreBreakdown
    }
    // end generated-init
}
public struct SearchPage: Hashable, Sendable {
    public var hits: [SearchHit]; public var nextCursor: ThreadCursor?
    public var completeness: SearchCompleteness = SearchCompleteness()
    public var ordering: SearchOrdering = .date

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        hits: [SearchHit],
        nextCursor: ThreadCursor? = nil,
        completeness: SearchCompleteness = SearchCompleteness(),
        ordering: SearchOrdering = .date
    ) {
        self.hits = hits
        self.nextCursor = nextCursor
        self.completeness = completeness
        self.ordering = ordering
    }
    // end generated-init
}

public protocol MailSearching: Sendable {
    func parseSearch(_ text: String) throws -> SearchQuery
    func search(_ query: SearchQuery, accounts: [AccountID]?, after: ThreadCursor?, limit: Int) throws -> SearchPage
    func observeSearch(_ query: SearchQuery, accounts: [AccountID]?, limit: Int) -> StoreObservation<SearchPage>
    func search(_ query: SearchQuery, accounts: [AccountID]?, after: ThreadCursor?, limit: Int,
                external: ExternalSearchCandidates?) throws -> SearchPage
    func observeSearch(_ query: SearchQuery, accounts: [AccountID]?, limit: Int,
                       external: ExternalSearchCandidates?) -> StoreObservation<SearchPage>
    func structuredMessageIDs(_ query: SearchQuery, accounts: [AccountID]?, limit: Int) throws
        -> (ids: [MessageRowID], capped: Bool)
    func search(_ query: SearchQuery, accounts: [AccountID]?, after: ThreadCursor?, limit: Int,
                external: ExternalSearchCandidates?, ranking: any SearchRanking, now: Date) throws -> SearchPage
    func observeSearch(_ query: SearchQuery, accounts: [AccountID]?, limit: Int,
                       external: ExternalSearchCandidates?, ranking: any SearchRanking) -> StoreObservation<SearchPage>
}

public enum SearchOrdering: String, Hashable, Sendable, Codable { case date, relevance }

extension MailSearching {
    public func search(_ query: SearchQuery, accounts: [AccountID]?, after: ThreadCursor?, limit: Int,
                       external: ExternalSearchCandidates?, ranking: any SearchRanking, now: Date) throws -> SearchPage {
        try search(query, accounts: accounts, after: after, limit: limit, external: external)
    }

    public func observeSearch(_ query: SearchQuery, accounts: [AccountID]?, limit: Int,
                              external: ExternalSearchCandidates?, ranking: any SearchRanking) -> StoreObservation<SearchPage> {
        observeSearch(query, accounts: accounts, limit: limit, external: external)
    }

    public func search(_ query: SearchQuery, accounts: [AccountID]?, after: ThreadCursor?, limit: Int,
                       external: ExternalSearchCandidates?) throws -> SearchPage {
        try search(query, accounts: accounts, after: after, limit: limit)
    }

    public func observeSearch(_ query: SearchQuery, accounts: [AccountID]?, limit: Int,
                              external: ExternalSearchCandidates?) -> StoreObservation<SearchPage> {
        observeSearch(query, accounts: accounts, limit: limit)
    }

    public func structuredMessageIDs(_ query: SearchQuery, accounts: [AccountID]?, limit: Int) throws
        -> (ids: [MessageRowID], capped: Bool) {
        throw StoreError.unsupportedView("structured message ids")
    }
}

public enum SearchMatchSource: String, Hashable, Sendable, Codable { case lexical, semantic }

public struct ExternalSearchCandidate: Hashable, Sendable {
    public var message: MessageRowID
    public var gmailMessageID: GmailMessageID
    public var score: Double

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        message: MessageRowID,
        gmailMessageID: GmailMessageID,
        score: Double
    ) {
        self.message = message
        self.gmailMessageID = gmailMessageID
        self.score = score
    }
    // end generated-init
}

public struct ExternalSearchCandidates: Hashable, Sendable {
    public var source: SearchMatchSource
    public var candidates: [ExternalSearchCandidate]

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        source: SearchMatchSource,
        candidates: [ExternalSearchCandidate]
    ) {
        self.source = source
        self.candidates = candidates
    }
    // end generated-init
}

extension ExternalSearchCandidates {
    public static let maximumCount = 1_000
}
