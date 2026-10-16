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

    public func observeSearch(_ query: SearchQuery, accounts: [AccountID]?, limit: Int,
                              external: ExternalSearchCandidates?, ranking: any SearchRanking) -> StoreObservation<SearchPage> {
        let external = Self.usable(external)
        return observe { db in
            try Self.searchPage(query, accounts: accounts, after: nil, limit: limit, ranking: ranking, now: Date(),
                                external: external, in: db)
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
        var header: SearchHeaderMatch? = nil
        var sent: Int? = nil
        var together: Bool? = nil

        mutating func absorb(header other: SearchHeaderMatch?, sent otherSent: Int?, together otherTogether: Bool?) {
            if let other { header = max(header ?? .none, other) }
            if let otherSent { sent = max(sent ?? 0, otherSent) }
            if let otherTogether { together = (together ?? false) || otherTogether }
        }
    }

    static let headerArmLimit = 2_000

    static func searchPage(_ query: SearchQuery, accounts: [AccountID]?, after: ThreadCursor?, limit: Int,
                           ranking: any SearchRanking, now: Date, external: ExternalSearchCandidates? = nil,
                           candidateLimit: Int = searchCandidateLimit, in db: Database) throws -> SearchPage {
        let n = min(max(limit, 1), 500)
        let compiled = SearchCompiler.compile(query, accounts: accounts)
        var reasons: [SearchIncompleteReason] = []
        var picked: [(match: Match, key: Int64, breakdown: SearchScoreBreakdown?)]
        var more = false
        let byDate = ranking.ordersByDate

        if let expression = compiled.ftsMatch {
            let facts = RankingFacts(inputs: ranking.inputs, terms: SearchHeaderTerms(query: query))
            let lexical = try ftsMatches(expression, compiled, facts: facts, limit: candidateLimit, in: db)
            if lexical.capped { reasons.append(.candidateLimitReached(limit: candidateLimit)) }
            var matches = lexical.0
            if let external {
                matches = merge(matches, try externalMatches(external, query: query, accounts: accounts, facts: facts, in: db))
            }
            let candidates = matches.map {
                SearchCandidate(threadID: ThreadRowID(rawValue: $0.tid), bestMessageID: MessageRowID(rawValue: $0.best),
                                matchedMessageIDs: $0.mids.map { MessageRowID(rawValue: $0) }, bestAt: date($0.bestAt),
                                newestAt: date($0.newestAt), bm25: $0.lexical ? $0.bm25 : nil, externalScore: $0.external,
                                headerMatch: $0.header, sentToCorrespondent: $0.sent, wordsTogether: $0.together)
            }
            let result = ranking.rankedScores(for: candidates, query: query, now: now)
            var ranked = matches.indices.map { index -> (match: Match, key: Int64, breakdown: SearchScoreBreakdown?) in
                let score = index < result.scores.count ? result.scores[index] : 0
                let key = byDate ? matches[index].newestAt : Int64((score.isFinite ? score : 0) * 1e9)
                let breakdown = result.breakdowns.flatMap { index < $0.count ? $0[index] : nil }
                return (matches[index], key, breakdown)
            }
            ranked.sort { ($0.key, $0.match.tid) > ($1.key, $1.match.tid) }
            if let after { ranked = ranked.filter { ($0.key, $0.match.tid) < (after.sortAt, after.tid) } }
            more = ranked.count > n
            picked = Array(ranked.prefix(n))
        } else {
            let matches = try structuredMatches(compiled, after: after, limit: n + 1, in: db)
            more = matches.count > n
            picked = matches.prefix(n).map { (match: $0, key: $0.newestAt, breakdown: nil) }
        }

        var hits: [SearchHit] = []
        let hybrid = external != nil && compiled.ftsMatch != nil
        for (match, _, breakdown) in picked {
            guard var item = try threadItem(tid: match.tid, in: db) else { continue }
            item.sortAt = date(byDate ? match.newestAt : match.bestAt)
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
            hit.scoreBreakdown = breakdown
            hits.append(hit)
        }
        let next = more ? picked.last.map { ThreadCursor(sortAt: $0.key, tid: $0.match.tid) } : nil
        reasons += try incompleteReasons(query, accounts: accounts, in: db)
        return SearchPage(hits: hits, nextCursor: next,
                          completeness: SearchCompleteness(reasons: reasons, gmailQuery: query.gmailQuery),
                          ordering: compiled.ftsMatch != nil && !byDate ? .relevance : .date)
    }

    struct RankingFacts {
        let inputs: SearchRankingInputs
        let terms: SearchHeaderTerms
        let phrase: String?

        init(inputs: SearchRankingInputs, terms: SearchHeaderTerms) {
            self.inputs = inputs
            self.terms = terms
            phrase = inputs.contains(.phrase) ? terms.ftsPhrase.map(SearchCompiler.phrase) : nil
        }

        var readsFields: Bool { inputs.contains(.fields) && !terms.isEmpty }
        var readsContacts: Bool { inputs.contains(.contacts) }

        var columns: String {
            var sql = ""
            if readsFields { sql += ", m.subject AS r_subject, m.from_name AS r_from_name, m.from_email AS r_from_email" }
            if readsContacts {
                sql += """
                    , (SELECT c.sent_count FROM contacts c WHERE c.account_id = m.account_id AND c.email = \
                    (CASE WHEN m.is_from_me = 1 THEN json_extract(m.to_json, '$[0].e') ELSE m.from_email END)) AS r_sent
                    """
            }
            if phrase != nil { sql += ", (m.mid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)) AS r_together" }
            return sql
        }

        var arguments: [DatabaseValue] { phrase.map { [$0.databaseValue] } ?? [] }

        func read(_ row: Row) -> (header: SearchHeaderMatch?, sent: Int?, together: Bool?) {
            let header = readsFields
                ? terms.match(subject: row["r_subject"], fromName: row["r_from_name"], fromEmail: row["r_from_email"]) : nil
            let sent: Int? = readsContacts ? ((row["r_sent"] as Int?) ?? 0) : nil
            let together: Bool? = phrase != nil ? ((row["r_together"] as Bool?) ?? false) : nil
            return (header, sent, together)
        }

        func headerArm(_ expression: String) -> String? {
            guard readsFields else { return nil }
            let words = terms.rawWords.filter(SearchCompiler.isIndexable)
            guard !words.isEmpty else { return nil }
            return "(\(expression))" + words.map { " AND {subject participants} : " + SearchCompiler.phrase($0) }.joined()
        }
    }

    private static func ftsMatches(_ expression: String, _ compiled: CompiledSearch, facts: RankingFacts, limit: Int,
                                   in db: Database) throws -> ([Match], capped: Bool) {
        func fetch(_ expression: String, limit: Int, before: (at: Int64, mid: Int64)? = nil) throws -> [Row] {
            var boundary = ""
            var boundaryArguments: [DatabaseValue] = []
            if let before {
                boundary = " AND (m.internal_date, m.mid) < (?, ?)"
                boundaryArguments = [before.at.databaseValue, before.mid.databaseValue]
            }
            return try Row.fetchAll(db, sql: """
                SELECT m.tid, m.mid, m.internal_date, bm25(messages_fts, 5.0, 2.0, 1.0, 3.0) AS rank\(facts.columns)
                FROM messages_fts
                JOIN messages m ON m.mid = messages_fts.rowid
                LEFT JOIN message_search_docs d ON d.mid = m.mid
                WHERE messages_fts MATCH ? AND \(compiled.predicate)\(boundary)
                ORDER BY m.internal_date DESC, m.mid DESC
                LIMIT ?
                """, arguments: StatementArguments(facts.arguments + [expression.databaseValue] + compiled.arguments
                                                   + boundaryArguments + [Int64(limit).databaseValue]))
        }
        let rows = try fetch(expression, limit: limit + 1)
        let capped = rows.count > limit
        var order: [Int64] = []
        var byThread: [Int64: Match] = [:]
        var seen = Set<Int64>()
        func add(_ row: Row) {
            let tid: Int64 = row["tid"], mid: Int64 = row["mid"], at: Int64 = row["internal_date"]
            guard seen.insert(mid).inserted else { return }
            let rank: Double = row["rank"]
            let fact = facts.read(row)
            if var match = byThread[tid] {
                match.mids.append(mid)
                match.newestAt = max(match.newestAt, at)
                if rank < (match.bm25 ?? .infinity) { match.best = mid; match.bestAt = at; match.bm25 = rank }
                match.absorb(header: fact.header, sent: fact.sent, together: fact.together)
                byThread[tid] = match
            } else {
                order.append(tid)
                var match = Match(tid: tid, best: mid, bestAt: at, newestAt: at, bm25: rank, mids: [mid])
                match.absorb(header: fact.header, sent: fact.sent, together: fact.together)
                byThread[tid] = match
            }
        }
        let kept = rows.prefix(limit)
        for row in kept { add(row) }
        if capped, let arm = facts.headerArm(expression), let last = kept.last {
            let lastAt: Int64 = last["internal_date"], lastMid: Int64 = last["mid"]
            for row in try fetch(arm, limit: headerArmLimit, before: (lastAt, lastMid)) { add(row) }
        }
        return (order.compactMap { byThread[$0] }, capped)
    }

    private static func externalMatches(_ external: ExternalSearchCandidates, query: SearchQuery, accounts: [AccountID]?,
                                        facts lexicalFacts: RankingFacts, in db: Database) throws -> [Match] {
        var expected: [Int64: (gmail: String, score: Double)] = [:]
        for candidate in external.candidates.prefix(ExternalSearchCandidates.maximumCount)
        where expected[candidate.message.rawValue] == nil && candidate.score.isFinite {
            expected[candidate.message.rawValue] = (candidate.gmailMessageID.rawValue, candidate.score)
        }
        guard !expected.isEmpty else { return [] }
        let facts = RankingFacts(inputs: lexicalFacts.inputs.subtracting(.phrase), terms: lexicalFacts.terms)
        let structured = SearchCompiler.compile(query.structuredOnly, accounts: accounts)
        let ids = "[" + expected.keys.sorted().map(String.init).joined(separator: ",") + "]"
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.tid, m.mid, m.internal_date, m.gmail_message_id\(facts.columns)
            FROM json_each(?) j
            JOIN messages m ON m.mid = j.value
            LEFT JOIN message_search_docs d ON d.mid = m.mid
            WHERE \(structured.predicate)
            """, arguments: StatementArguments(facts.arguments + [ids.databaseValue] + structured.arguments))
        var byThread: [Int64: Match] = [:]
        for row in rows {
            let mid: Int64 = row["mid"], tid: Int64 = row["tid"], at: Int64 = row["internal_date"]
            let gmail: String = row["gmail_message_id"]
            guard let wanted = expected[mid], wanted.gmail == gmail else { continue }
            let fact = facts.read(row)
            if var match = byThread[tid] {
                match.mids.append(mid)
                match.newestAt = max(match.newestAt, at)
                if wanted.score > (match.external ?? -.infinity) {
                    match.best = mid
                    match.bestAt = at
                    match.external = wanted.score
                }
                match.absorb(header: fact.header, sent: fact.sent, together: nil)
                byThread[tid] = match
            } else {
                var match = Match(tid: tid, best: mid, bestAt: at, newestAt: at, bm25: nil, mids: [mid],
                                  external: wanted.score, lexical: false)
                match.absorb(header: fact.header, sent: fact.sent, together: nil)
                byThread[tid] = match
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
                match.absorb(header: found.header, sent: found.sent, together: nil)
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
