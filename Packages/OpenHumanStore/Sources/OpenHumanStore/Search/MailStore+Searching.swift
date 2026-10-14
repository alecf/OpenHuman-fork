import Foundation
import GRDB
import OpenHumanCore

private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

extension MailStore: MailSearching {
    static let searchCandidateLimit = 20_000

    public func parseSearch(_ text: String) throws -> SearchQuery {
        try SearchParser.parse(text)
    }

    public func search(_ query: SearchQuery, accounts: [AccountID]?, after: ThreadCursor?, limit: Int) throws -> SearchPage {
        try search(query, accounts: accounts, after: after, limit: limit, ranking: BM25RecencyRanking(), now: Date())
    }

    public func search(_ query: SearchQuery, accounts: [AccountID]?, after: ThreadCursor?, limit: Int,
                       ranking: any SearchRanking, now: Date) throws -> SearchPage {
        try read { db in
            try Self.searchPage(query, accounts: accounts, after: after, limit: limit, ranking: ranking, now: now, in: db)
        }
    }

    public func observeSearch(_ query: SearchQuery, accounts: [AccountID]?, limit: Int) -> StoreObservation<SearchPage> {
        observe { db in
            try Self.searchPage(query, accounts: accounts, after: nil, limit: limit, ranking: BM25RecencyRanking(),
                                now: Date(), in: db)
        }
    }

    public func search(_ query: SearchQuery, accounts: [AccountID]?, after: ThreadCursor?, limit: Int,
                       external: ExternalSearchCandidates?) throws -> SearchPage {
        let external = Self.usable(external)
        return try search(query, accounts: accounts, after: after, limit: limit, external: external,
                          ranking: external == nil ? BM25RecencyRanking() : HybridRRFRanking(), now: Date())
    }

    public func search(_ query: SearchQuery, accounts: [AccountID]?, after: ThreadCursor?, limit: Int,
                       external: ExternalSearchCandidates?, ranking: any SearchRanking, now: Date) throws -> SearchPage {
        let external = Self.usable(external)
        return try read { db in
            try Self.searchPage(query, accounts: accounts, after: after, limit: limit, ranking: ranking, now: now,
                                external: external, in: db)
        }
    }

    public func observeSearch(_ query: SearchQuery, accounts: [AccountID]?, limit: Int,
                              external: ExternalSearchCandidates?) -> StoreObservation<SearchPage> {
        guard let external = Self.usable(external) else { return observeSearch(query, accounts: accounts, limit: limit) }
        return observe { db in
            try Self.searchPage(query, accounts: accounts, after: nil, limit: limit, ranking: HybridRRFRanking(),
                                now: Date(), external: external, in: db)
        }
    }

    public func structuredMessageIDs(_ query: SearchQuery, accounts: [AccountID]?, limit: Int) throws
        -> (ids: [MessageRowID], capped: Bool) {
        let n = max(limit, 0)
        let compiled = SearchCompiler.compile(query.structuredOnly, accounts: accounts)
        return try read { db in
            let mids = try Int64.fetchAll(db, sql: """
                SELECT m.mid FROM messages m
                LEFT JOIN message_search_docs d ON d.mid = m.mid
                WHERE \(compiled.predicate)
                ORDER BY m.internal_date DESC, m.mid DESC
                LIMIT ?
                """, arguments: StatementArguments(compiled.arguments + [Int64(n + 1).databaseValue]))
            return (mids.prefix(n).map { MessageRowID(rawValue: $0) }, mids.count > n)
        }
    }

    static func usable(_ external: ExternalSearchCandidates?) -> ExternalSearchCandidates? {
        guard let external, !external.candidates.isEmpty else { return nil }
        return external
    }

    private struct Match {
        var tid: Int64
        var best: Int64
        var bestAt: Int64
        var newestAt: Int64
        var bm25: Double?
        var mids: [Int64]
        var external: Double? = nil
        var lexical = true
    }

    static func searchPage(_ query: SearchQuery, accounts: [AccountID]?, after: ThreadCursor?, limit: Int,
                           ranking: any SearchRanking, now: Date, external: ExternalSearchCandidates? = nil,
                           in db: Database) throws -> SearchPage {
        let n = min(max(limit, 1), 500)
        let compiled = SearchCompiler.compile(query, accounts: accounts)
        var reasons: [SearchIncompleteReason] = []
        var picked: [(match: Match, key: Int64)]
        var more = false

        if let expression = compiled.ftsMatch {
            let lexical = try ftsMatches(expression, compiled, in: db)
            if lexical.capped { reasons.append(.candidateLimitReached(limit: searchCandidateLimit)) }
            var matches = lexical.0
            if let external {
                matches = merge(matches, try externalMatches(external, query: query, accounts: accounts, in: db))
            }
            let candidates = matches.map {
                SearchCandidate(threadID: ThreadRowID(rawValue: $0.tid), bestMessageID: MessageRowID(rawValue: $0.best),
                                matchedMessageIDs: $0.mids.map { MessageRowID(rawValue: $0) }, bestAt: date($0.bestAt),
                                newestAt: date($0.newestAt), bm25: $0.lexical ? $0.bm25 : nil, externalScore: $0.external)
            }
            let scores = ranking.scores(for: candidates, query: query, now: now)
            var ranked = zip(matches, scores).map { (match: $0, key: Int64(($1.isFinite ? $1 : 0) * 1e9)) }
            ranked.sort { ($0.key, $0.match.tid) > ($1.key, $1.match.tid) }
            if let after { ranked = ranked.filter { ($0.key, $0.match.tid) < (after.sortAt, after.tid) } }
            more = ranked.count > n
            picked = Array(ranked.prefix(n))
        } else {
            let matches = try structuredMatches(compiled, after: after, limit: n + 1, in: db)
            more = matches.count > n
            picked = matches.prefix(n).map { (match: $0, key: $0.newestAt) }
        }

        var hits: [SearchHit] = []
        let hybrid = external != nil && compiled.ftsMatch != nil
        for (match, _) in picked {
            guard var item = try threadItem(tid: match.tid, in: db) else { continue }
            item.sortAt = date(match.bestAt)
            var snippet: String?
            if match.lexical, let expression = compiled.ftsMatch {
                snippet = try highlight(match: expression, mid: match.best, in: db)
            }
            var hit = SearchHit(thread: item, matchedMessageIDs: match.mids.map { MessageRowID(rawValue: $0) },
                                highlight: snippet)
            if hybrid, let external {
                var sources: Set<SearchMatchSource> = match.lexical ? [.lexical] : []
                if match.external != nil { sources.insert(external.source) }
                hit.sources = sources
                hit.bestMessageID = MessageRowID(rawValue: match.best)
            }
            hits.append(hit)
        }
        let next = more ? picked.last.map { ThreadCursor(sortAt: $0.key, tid: $0.match.tid) } : nil
        reasons += try incompleteReasons(query, accounts: accounts, in: db)
        return SearchPage(hits: hits, nextCursor: next,
                          completeness: SearchCompleteness(reasons: reasons, gmailQuery: query.gmailQuery))
    }

    private static func ftsMatches(_ expression: String, _ compiled: CompiledSearch, in db: Database) throws -> ([Match], capped: Bool) {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.tid, m.mid, m.internal_date, bm25(messages_fts, 5.0, 2.0, 1.0, 3.0) AS rank
            FROM messages_fts
            JOIN messages m ON m.mid = messages_fts.rowid
            LEFT JOIN message_search_docs d ON d.mid = m.mid
            WHERE messages_fts MATCH ? AND \(compiled.predicate)
            ORDER BY m.internal_date DESC, m.mid DESC
            LIMIT ?
            """, arguments: StatementArguments([expression.databaseValue] + compiled.arguments
                                               + [Int64(searchCandidateLimit + 1).databaseValue]))
        let capped = rows.count > searchCandidateLimit
        var order: [Int64] = []
        var byThread: [Int64: Match] = [:]
        for row in rows.prefix(searchCandidateLimit) {
            let tid: Int64 = row["tid"], mid: Int64 = row["mid"], at: Int64 = row["internal_date"]
            let rank: Double = row["rank"]
            if var match = byThread[tid] {
                match.mids.append(mid)
                if rank < (match.bm25 ?? .infinity) { match.best = mid; match.bestAt = at; match.bm25 = rank }
                byThread[tid] = match
            } else {
                order.append(tid)
                byThread[tid] = Match(tid: tid, best: mid, bestAt: at, newestAt: at, bm25: rank, mids: [mid])
            }
        }
        return (order.compactMap { byThread[$0] }, capped)
    }

    private static func externalMatches(_ external: ExternalSearchCandidates, query: SearchQuery, accounts: [AccountID]?,
                                        in db: Database) throws -> [Match] {
        var expected: [Int64: (gmail: String, score: Double)] = [:]
        for candidate in external.candidates.prefix(ExternalSearchCandidates.maximumCount)
        where expected[candidate.message.rawValue] == nil && candidate.score.isFinite {
            expected[candidate.message.rawValue] = (candidate.gmailMessageID.rawValue, candidate.score)
        }
        guard !expected.isEmpty else { return [] }
        let structured = SearchCompiler.compile(query.structuredOnly, accounts: accounts)
        let ids = "[" + expected.keys.sorted().map(String.init).joined(separator: ",") + "]"
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.tid, m.mid, m.internal_date, m.gmail_message_id
            FROM json_each(?) j
            JOIN messages m ON m.mid = j.value
            LEFT JOIN message_search_docs d ON d.mid = m.mid
            WHERE \(structured.predicate)
            """, arguments: StatementArguments([ids.databaseValue] + structured.arguments))
        var byThread: [Int64: Match] = [:]
        for row in rows {
            let mid: Int64 = row["mid"], tid: Int64 = row["tid"], at: Int64 = row["internal_date"]
            let gmail: String = row["gmail_message_id"]
            guard let wanted = expected[mid], wanted.gmail == gmail else { continue }
            if var match = byThread[tid] {
                match.mids.append(mid)
                match.newestAt = max(match.newestAt, at)
                if wanted.score > (match.external ?? -.infinity) {
                    match.best = mid
                    match.bestAt = at
                    match.external = wanted.score
                }
                byThread[tid] = match
            } else {
                byThread[tid] = Match(tid: tid, best: mid, bestAt: at, newestAt: at, bm25: nil, mids: [mid],
                                      external: wanted.score, lexical: false)
            }
        }
        return byThread.values.sorted { ($0.external ?? 0, $0.tid) > ($1.external ?? 0, $1.tid) }
    }

    private static func merge(_ lexical: [Match], _ external: [Match]) -> [Match] {
        var order = lexical.map(\.tid)
        var byThread = Dictionary(lexical.map { ($0.tid, $0) }, uniquingKeysWith: { first, _ in first })
        for found in external {
            if var match = byThread[found.tid] {
                match.external = found.external
                for mid in found.mids where !match.mids.contains(mid) { match.mids.append(mid) }
                match.newestAt = max(match.newestAt, found.newestAt)
                byThread[found.tid] = match
            } else {
                order.append(found.tid)
                byThread[found.tid] = found
            }
        }
        return order.compactMap { byThread[$0] }
    }

    private static func structuredMatches(_ compiled: CompiledSearch, after: ThreadCursor?, limit: Int,
                                          in db: Database) throws -> [Match] {
        var args = compiled.arguments
        var cursorSQL = ""
        if let after {
            cursorSQL = "HAVING (max(m.internal_date), m.tid) < (?, ?)"
            args += [after.sortAt.databaseValue, after.tid.databaseValue]
        }
        args.append(Int64(limit).databaseValue)
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.tid, max(m.internal_date) AS best_at, m.mid AS best_mid,
                   group_concat(m.mid ORDER BY m.internal_date DESC, m.mid DESC) AS mids
            FROM messages m
            LEFT JOIN message_search_docs d ON d.mid = m.mid
            WHERE \(compiled.predicate)
            GROUP BY m.tid \(cursorSQL)
            ORDER BY best_at DESC, m.tid DESC
            LIMIT ?
            """, arguments: StatementArguments(args))
        return rows.map { row in
            let at: Int64 = row["best_at"]
            let mids = (row["mids"] as String).split(separator: ",").compactMap { Int64($0) }
            return Match(tid: row["tid"], best: row["best_mid"], bestAt: at, newestAt: at, bm25: nil, mids: mids)
        }
    }

    private static func highlight(match expression: String, mid: Int64, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT snippet(messages_fts, -1, char(2), char(3), '…', 16) FROM messages_fts
            WHERE messages_fts MATCH ? AND rowid = ?
            """, arguments: [expression, mid])
    }

    private static func incompleteReasons(_ query: SearchQuery, accounts: [AccountID]?, in db: Database) throws -> [SearchIncompleteReason] {
        var sql = """
            SELECT a.account_id, COALESCE(s.backfill_complete, 0) AS complete, s.backfill_oldest_at AS oldest
            FROM accounts a LEFT JOIN sync_state s ON s.account_id = a.account_id WHERE a.status <> 'removing'
            """
        var args: [DatabaseValue] = []
        if let accounts {
            sql += " AND a.account_id IN (\(accounts.map { _ in "?" }.joined(separator: ", ")))"
            args = accounts.map { $0.rawValue.databaseValue }
        }
        let lowerBound = query.terms.compactMap { term -> Date? in if case let .after(d) = term { return d } else { return nil } }.max()
        var missing: [AccountID] = []
        var searchedBack: Date?
        var unknownDepth = false
        var scope: [Int64] = []
        for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
            let account: Int64 = row["account_id"]
            scope.append(account)
            let complete: Bool = row["complete"]
            let oldest: Int64? = row["oldest"]
            if complete { continue }
            if let lowerBound, let oldest, lowerBound >= date(oldest) { continue }
            missing.append(AccountID(account))
            if let oldest { searchedBack = max(searchedBack ?? .distantPast, date(oldest)) } else { unknownDepth = true }
        }
        var reasons: [SearchIncompleteReason] = []
        if !missing.isEmpty {
            reasons.append(.olderMailNeedsGmailFallback(accounts: missing, searchedBack: unknownDepth ? nil : searchedBack))
        }
        if query.searchesBodies, !scope.isEmpty {
            let count = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM messages WHERE account_id IN (\(scope.map { _ in "?" }.joined(separator: ", ")))
                AND body_state < 2 AND in_trash = 0 AND in_spam = 0 AND is_draft = 0
                """, arguments: StatementArguments(scope.map { $0.databaseValue })) ?? 0
            if count > 0 { reasons.append(.bodiesPartiallyIndexed(messages: count)) }
        }
        return reasons
    }
}

extension SearchQuery {
    var structuredOnly: SearchQuery {
        SearchQuery(text: text, terms: terms.filter { !Self.isFreeText($0) })
    }

    static func isFreeText(_ term: SearchTerm) -> Bool {
        switch term {
        case let .text(_, field): return field == nil
        case let .or(items), let .and(items): return !items.isEmpty && items.allSatisfy(isFreeText)
        default: return false
        }
    }
}
