import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore
import Synchronization

extension MailStoreAdapter {
    public func search(_ query: String, accounts: [AccountID]?, limit: Int) -> AsyncThrowingStream<SearchResultsInfo, Error> {
        let store = self.store
        let parsed: (searching: any MailSearching, query: SearchQuery)
        do { parsed = try Self.parsedSearch(query, store) } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return Self.map(parsed.searching.observeSearch(parsed.query, accounts: accounts, limit: limit).values()) { page in
            var primary: [AccountID: LabelRowID] = [:]
            var looked: Set<AccountID> = []
            let hits = page.hits.map { hit -> SearchHitInfo in
                let account = hit.thread.ref.accountID
                if looked.insert(account).inserted { primary[account] = Self.primaryCategory(store, account: account) }
                return SearchHitInfo(row: Self.row(hit.thread, hiddenCategory: primary[account]),
                                     matchedMessageRowIDs: hit.matchedMessageIDs.map(\.rawValue), highlight: hit.highlight)
            }
            return SearchResultsInfo(hits: hits, hasMore: page.nextCursor != nil,
                                     completeness: Self.completeness(page.completeness))
        }
    }

    public func searchGmail(_ query: String, account: AccountID) async throws -> Int {
        guard let fallback = searchFallback else { throw MailPortError.unsupported("Gmail search in this store") }
        let parsed = try Self.parsedSearch(query, store)
        do {
            return try await fallback.searchNow(parsed.query.gmailQuery, account: account).count
        } catch let error as MailPortError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MailPortError.unavailable("Gmail search")
        }
    }

    func searchWindow(_ text: String, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        let store = self.store
        let parsed: (searching: any MailSearching, query: SearchQuery)
        do { parsed = try Self.parsedSearch(text, store) } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let source = parsed.searching.observeSearch(parsed.query, accounts: [account], limit: limit).values()
        let fallback = searchFallback
        let arm = semanticArm.flatMap { SemanticSearchArm.plan(parsed.query) == nil ? nil : $0 }
        let searching = parsed.searching
        let query = parsed.query
        let gmailQuery = GmailSearchFallback.normalized(parsed.query.gmailQuery)
        let canAskGmail = fallback != nil && !gmailQuery.isEmpty
        return AsyncThrowingStream { continuation in
            let inputs = SearchWindowInputs()
            let publish: @Sendable (SearchWindowInputs.Snapshot) -> Void = { snapshot in
                do {
                    continuation.yield(try Self.searchWindow(snapshot.page, related: snapshot.related, remote: snapshot.remote,
                                                             gmail: snapshot.gmail, canAskGmail: canAskGmail, store: store,
                                                             account: account))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let observation: GmailSearchFallback.Observation? = canAskGmail
                ? fallback?.observe(gmailQuery, account: account, { event in inputs.apply(event, publish: publish) })
                : nil
            if canAskGmail, let kept = fallback?.kept(gmailQuery, account: account) {
                inputs.apply(.answered(kept), publish: publish)
            }
            if let arm {
                arm.noteActivity()
                inputs.hold()
            }
            let semanticTask: Task<Void, Never>? = arm.map { arm in
                Task {
                    let deadline = Task {
                        try? await Task.sleep(for: arm.firstPaintBudget)
                        guard !Task.isCancelled else { return }
                        inputs.release(publish: publish)
                    }
                    let external = await arm.candidates(query, [account])
                    let early = inputs.isHolding
                    deadline.cancel()
                    guard let external, !external.candidates.isEmpty, !Task.isCancelled else {
                        inputs.release(publish: publish)
                        return
                    }
                    if early { inputs.useFused() } else { inputs.release(publish: publish) }
                    do {
                        for try await fused in searching.observeSearch(query, accounts: [account], limit: limit,
                                                                       external: external).values() {
                            if early {
                                inputs.setPage(fused, fused: true, publish: publish)
                            } else {
                                inputs.setRelated(fused.hits.filter { !$0.sources.contains(.lexical) }, publish: publish)
                            }
                        }
                    } catch {
                        Log(.app).notice("semantic results stopped (\(String(describing: type(of: error))))")
                    }
                }
            }
            let task = Task {
                var remoteTask: Task<Void, Never>?
                defer {
                    remoteTask?.cancel()
                    semanticTask?.cancel()
                }
                do {
                    for try await page in source {
                        inputs.setPage(page, publish: publish)
                        guard remoteTask == nil, canAskGmail, let fallback, page.completeness.needsGmailFallback,
                              !inputs.hasAskedGmail else { continue }
                        inputs.apply(.searching, publish: publish)
                        remoteTask = Task {
                            let event: GmailSearchFallback.Event
                            if let refs = await fallback.threads(matching: gmailQuery, account: account) {
                                event = .answered(refs)
                            } else {
                                event = .failed
                            }
                            guard !Task.isCancelled else { return }
                            inputs.apply(event, publish: publish)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if let observation { fallback?.stopObserving(observation) }
            }
        }
    }

    func searchPage(_ text: String, account: AccountID, after: PageCursor?,
                    limit: Int) throws -> (rows: [ThreadRow], next: PageCursor?) {
        let parsed = try Self.parsedSearch(text, store)
        let cursor = try after.map(Self.threadCursor)
        let external = semanticArm?.cached(parsed.query, [account])
        let page = try parsed.searching.search(parsed.query, accounts: [account], after: cursor, limit: limit, external: external)
        let primary = Self.primaryCategory(store, account: account)
        let hybrid = page.hits.contains { $0.sources.contains(.semantic) }
        return (page.hits.map { Self.row($0.thread, hiddenCategory: primary).with(searchMatch: Self.searchMatch($0, hybrid: hybrid)) },
                page.nextCursor.map(Self.pageCursor))
    }

    static func searchMatch(_ hit: SearchHit, hybrid: Bool) -> SearchMatchKind? {
        if !hit.sources.contains(.lexical) { return .related }
        return hybrid ? .lexical : nil
    }

    static func searchWindow(_ page: SearchPage, related: [SearchHit] = [], remote: [ThreadRef], gmail: GmailSearchPhase,
                             canAskGmail: Bool, store: any Store, account: AccountID) throws -> ThreadListWindow {
        let primary = primaryCategory(store, account: account)
        let hybrid = !related.isEmpty || page.hits.contains { $0.sources.contains(.semantic) }
        var rows = page.hits.map { row($0.thread, hiddenCategory: primary).with(searchMatch: searchMatch($0, hybrid: hybrid)) }
        var seen = Set(rows.map(\.id.rowID))
        for hit in related where seen.insert(hit.thread.id.rawValue).inserted {
            rows.append(row(hit.thread, hiddenCategory: primary).with(searchMatch: .related))
        }
        let local = rows.count
        for ref in remote where seen.insert(ref.rowID.rawValue).inserted {
            guard let item = try store.thread(ref) else { continue }
            rows.append(row(item, hiddenCategory: primary))
        }
        let state: GmailSearchState
        switch gmail {
        case .notAsked: state = .notAsked
        case .searching: state = .searching
        case .answered: state = .done(added: rows.count - local)
        case .failed: state = .failed
        }
        let status = SearchWindowStatus(completeness: completeness(page.completeness), gmail: state,
                                        gmailAvailable: canAskGmail)
        return ThreadListWindow(rows: rows, hasMore: page.nextCursor != nil, totalCount: rows.count, search: status)
    }

    static func completeness(_ completeness: SearchCompleteness) -> SearchCompletenessInfo {
        SearchCompletenessInfo(reasons: completeness.reasons.map { reason -> SearchIncompleteness in
            switch reason {
            case .olderMailNeedsGmailFallback(_, let searchedBack): .olderMailNotLocal(searchedBack: searchedBack)
            case .bodiesPartiallyIndexed(let messages): .bodiesNotDownloaded(messages: messages)
            case .candidateLimitReached(let limit): .tooManyMatches(limit: limit)
            }
        })
    }

    static func parsedSearch(_ text: String, _ store: any Store) throws -> (searching: any MailSearching, query: SearchQuery) {
        guard let searching = store as? any MailSearching else { throw MailPortError.unsupported("search in this store") }
        do {
            return (searching, try searching.parseSearch(text))
        } catch let error as StoreError {
            if case .invalidQuery = error { throw MailPortError.invalidQuery("check the search operators") }
            throw MailPortError.unavailable("search")
        }
    }
}

enum GmailSearchPhase: Sendable, Equatable {
    case notAsked, searching, answered, failed
}

private final class SearchWindowInputs: Sendable {
    struct Snapshot: Sendable {
        var page: SearchPage
        var related: [SearchHit] = []
        var remote: [ThreadRef]
        var gmail: GmailSearchPhase
    }
    private struct State {
        var page: SearchPage?
        var related: [SearchHit] = []
        var remote: [ThreadRef] = []
        var gmail: GmailSearchPhase = .notAsked
        var holding = false
        var fused = false
    }
    private let state = Mutex(State())

    var hasAskedGmail: Bool { state.withLock { $0.gmail != .notAsked } }
    var isHolding: Bool { state.withLock { $0.holding } }

    func hold() { state.withLock { $0.holding = true } }

    func release(publish: (Snapshot) -> Void) {
        state.withLock { s in
            guard s.holding else { return }
            s.holding = false
            if let page = s.page { publish(Snapshot(page: page, related: s.related, remote: s.remote, gmail: s.gmail)) }
        }
    }

    func useFused() { state.withLock { $0.fused = true } }

    func setPage(_ page: SearchPage, fused: Bool = false, publish: (Snapshot) -> Void) {
        state.withLock { s in
            if s.fused, !fused { return }
            if fused { s.holding = false }
            s.page = page
            if !s.holding { publish(Snapshot(page: page, related: s.related, remote: s.remote, gmail: s.gmail)) }
        }
    }

    func setRelated(_ hits: [SearchHit], publish: (Snapshot) -> Void) {
        state.withLock { s in
            s.related = hits
            if !s.holding, let page = s.page { publish(Snapshot(page: page, related: hits, remote: s.remote, gmail: s.gmail)) }
        }
    }

    func apply(_ event: GmailSearchFallback.Event, publish: (Snapshot) -> Void) {
        state.withLock { s in
            switch event {
            case .searching:
                s.gmail = .searching
            case .answered(let refs):
                s.remote = refs
                s.gmail = .answered
            case .failed:
                if s.gmail != .answered { s.gmail = .failed }
            }
            if !s.holding, let page = s.page { publish(Snapshot(page: page, related: s.related, remote: s.remote, gmail: s.gmail)) }
        }
    }
}

final class GmailSearchFallback: Sendable {
    typealias Search = @Sendable (_ gmailQuery: String, _ account: AccountID) async throws -> [ThreadRef]
    static let keptAnswers = 32

    enum Event: Sendable {
        case searching
        case answered([ThreadRef])
        case failed
    }

    struct Key: Hashable, Sendable {
        var account: AccountID
        var query: String
    }

    struct Observation: Sendable {
        let key: Key
        let id: UUID
    }

    private struct Answers {
        var order: [Key] = []
        var refs: [Key: [ThreadRef]] = [:]
        var observers: [Key: [UUID: @Sendable (Event) -> Void]] = [:]
    }
    private let search: Search
    private let delay: Duration
    private let answers = Mutex(Answers())

    init(delay: Duration, search: @escaping Search) {
        self.delay = delay
        self.search = search
    }

    static func normalized(_ gmailQuery: String) -> String {
        gmailQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func threads(matching gmailQuery: String, account: AccountID) async -> [ThreadRef]? {
        let query = Self.normalized(gmailQuery)
        guard !query.isEmpty else { return nil }
        let key = Key(account: account, query: query)
        if let known = answers.withLock({ $0.refs[key] }) { return known }
        do { try await Task.sleep(for: delay) } catch { return nil }
        do {
            let refs = try await search(query, account)
            keep(refs, for: key)
            Log(.app).info("account \(account.rawValue): Gmail search added \(refs.count) thread(s)")
            return refs
        } catch {
            if !(error is CancellationError) {
                Log(.app).notice("account \(account.rawValue): Gmail search failed (\(String(describing: type(of: error))))")
            }
            return nil
        }
    }

    func searchNow(_ gmailQuery: String, account: AccountID) async throws -> [ThreadRef] {
        let query = Self.normalized(gmailQuery)
        guard !query.isEmpty else { throw MailPortError.unsupported("Gmail search for this query") }
        let key = Key(account: account, query: query)
        notify(key, .searching)
        do {
            let refs = try await search(query, account)
            keep(refs, for: key)
            Log(.app).info("account \(account.rawValue): Gmail search (asked for) found \(refs.count) thread(s)")
            notify(key, .answered(refs))
            return refs
        } catch {
            Log(.app).notice("account \(account.rawValue): Gmail search failed (\(String(describing: type(of: error))))")
            notify(key, .failed)
            throw error
        }
    }

    func kept(_ gmailQuery: String, account: AccountID) -> [ThreadRef]? {
        let key = Key(account: account, query: Self.normalized(gmailQuery))
        return answers.withLock { $0.refs[key] }
    }

    func observe(_ gmailQuery: String, account: AccountID,
                 _ handler: @escaping @Sendable (Event) -> Void) -> Observation {
        let observation = Observation(key: Key(account: account, query: Self.normalized(gmailQuery)), id: UUID())
        answers.withLock { $0.observers[observation.key, default: [:]][observation.id] = handler }
        return observation
    }

    func stopObserving(_ observation: Observation) {
        answers.withLock { a in
            a.observers[observation.key]?[observation.id] = nil
            if a.observers[observation.key]?.isEmpty == true { a.observers[observation.key] = nil }
        }
    }

    var observerCount: Int { answers.withLock { $0.observers.values.reduce(0) { $0 + $1.count } } }

    private func keep(_ refs: [ThreadRef], for key: Key) {
        answers.withLock { a in
            if a.refs.updateValue(refs, forKey: key) == nil { a.order.append(key) }
            while a.order.count > Self.keptAnswers { a.refs[a.order.removeFirst()] = nil }
        }
    }

    private func notify(_ key: Key, _ event: Event) {
        let handlers = answers.withLock { Array(($0.observers[key] ?? [:]).values) }
        for handler in handlers { handler(event) }
    }
}

final class ViewLoader: Sendable {
    static let folders: Set<SystemFolder> = [.trash, .spam, .drafts]

    static func loadsOnOpen(_ location: MailLocation) -> Bool {
        switch location {
        case .system(let folder): folders.contains(folder)
        case .label: true
        case .split, .splitOther, .search, .reviewQueue: false
        }
    }

    private let load: @Sendable (MailboxView) async throws -> Void
    private let started = Mutex<Set<MailboxView>>([])

    init(_ load: @escaping @Sendable (MailboxView) async throws -> Void) {
        self.load = load
    }

    func open(_ view: MailboxView) {
        guard started.withLock({ $0.insert(view).inserted }) else { return }
        Task { [self] in
            do { try await load(view) } catch {
                _ = started.withLock { $0.remove(view) }
                Log(.app).notice("view load failed (\(String(describing: type(of: error))))")
            }
        }
    }

    var openedViews: Set<MailboxView> { started.withLock { $0 } }
}
