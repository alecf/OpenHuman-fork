import Foundation
import OpenHumanAI
import OpenHumanCore
import OpenHumanStore

public struct SearchEvalOptions: Sendable {
    public var storage: VectorStorage
    public var chunks: Int
    public var fusion: FusionParameters
    public var tau: Float
    public var runGrid: Bool
    public var tauSweep: [Double]
    public var perQuery: Bool

    public init(storage: VectorStorage = .int8, chunks: Int = 1, fusion: FusionParameters = FusionParameters(),
                tau: Float = 0, runGrid: Bool = true, tauSweep: [Double] = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7],
                perQuery: Bool = false) {
        self.storage = storage
        self.chunks = chunks
        self.fusion = fusion
        self.tau = tau
        self.runGrid = runGrid
        self.tauSweep = tauSweep
        self.perQuery = perQuery
    }
}

struct QueryCandidates: Sendable {
    var lexicalMUR1: [String]
    var lexicalBM25: [String]
    var semantic: [SemanticHit]?
    var lexicalMilliseconds: Double
    var semanticMilliseconds: Double
    var embedMilliseconds: Double?
}

public enum SearchEvalRunner {
    public static func run(corpus: BuiltCorpus, queries: [CorpusQuery], provider: (any TextEmbeddingProvider)?,
                           index prebuilt: EvalVectorIndex? = nil, options: SearchEvalOptions = SearchEvalOptions(),
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> SearchEvalReport {
        let lexical = LexicalArm(corpus: corpus)
        let index = try await vectorIndex(corpus, provider: provider, prebuilt: prebuilt, options: options)

        var typed: [QueryCandidates] = []
        var planned: [QueryCandidates?] = []
        for (number, query) in queries.enumerated() {
            let scope = corpus.scope(for: query)
            typed.append(try await candidates(query.query, scope: scope, lexical: lexical, index: index, provider: provider))
            if let text = query.planned {
                planned.append(try await candidates(text, scope: scope, lexical: lexical, index: index, provider: provider))
            } else {
                planned.append(nil)
            }
            progress?(number + 1, queries.count)
        }

        var arms: [SearchEvalReport.ArmScore] = []
        var perQuery: [SearchEvalReport.PerQueryLine] = []
        let mur1 = queries.indices.map { typed[$0].lexicalMUR1 }
        arms.append(score(.lexical, queries: queries, corpus: corpus, ranked: mur1, semanticOnly: nil,
                          milliseconds: typed.map(\.lexicalMilliseconds), perQuery: &perQuery, options: options))
        var thresholds: [SearchEvalReport.ThresholdRow] = []
        var grid: SearchEvalReport.GridResult?
        var rules = SearchEvalReport.RuleChecks()
        var stats: SearchEvalReport.IndexStats?
        if let index {
            let tau = Double(options.tau)
            let vector = queries.indices.map { EvalVectorIndex.threads(filtered(typed[$0].semantic, tau: tau) ?? []) }
            arms.append(score(.vector, queries: queries, corpus: corpus, ranked: vector, semanticOnly: nil,
                              milliseconds: typed.map(\.semanticMilliseconds), perQuery: &perQuery, options: options))
            let hybrid = queries.indices.map { fused(typed[$0], fusion: options.fusion, tau: tau, corpus: corpus) }
            arms.append(score(.hybrid, queries: queries, corpus: corpus, ranked: hybrid.map { $0.ranked },
                              semanticOnly: hybrid.map { $0.semanticOnly },
                              milliseconds: typed.map { max($0.lexicalMilliseconds, $0.semanticMilliseconds) },
                              perQuery: &perQuery, options: options))
            let withPlan = queries.indices.map { fused(planned[$0] ?? typed[$0], fusion: options.fusion, tau: tau, corpus: corpus) }
            arms.append(score(.planned, queries: queries, corpus: corpus, ranked: withPlan.map { $0.ranked },
                              semanticOnly: withPlan.map { $0.semanticOnly },
                              milliseconds: typed.map { max($0.lexicalMilliseconds, $0.semanticMilliseconds) },
                              perQuery: &perQuery, options: options))
            rules = ruleChecks(queries: queries, corpus: corpus, lexical: mur1, hybrid: hybrid.map { $0.ranked })
            thresholds = options.tauSweep.map { tau in
                let runs = queries.indices.map { fused(typed[$0], fusion: options.fusion, tau: tau, corpus: corpus) }
                let negatives = queries.indices.filter { queries[$0].kind == .negative }
                let related = negatives.map { Double(runs[$0].semanticOnly) }
                let wanted = queries.indices.filter { [QueryClass.paraphrase, .vague].contains(queries[$0].kind) }
                return SearchEvalReport.ThresholdRow(
                    tau: tau, negativeRelatedInTop10: related.isEmpty ? 0 : related.reduce(0, +) / Double(related.count),
                    paraphraseAndVagueRecallAt10: RetrievalMetrics.mean(wanted.map {
                        RetrievalMetrics.recall(runs[$0].ranked, grades: corpus.grades(for: queries[$0]))
                    }))
            }
            rules.chosenTau = thresholds.first { $0.negativeRelatedInTop10 <= 2 }?.tau
            if options.runGrid { grid = tune(queries: queries, corpus: corpus, typed: typed, tau: tau, options: options) }
            let embeds = typed.compactMap(\.embedMilliseconds)
            stats = SearchEvalReport.IndexStats(
                providerID: index.space.providerID.rawValue, modelVersion: index.space.modelVersion,
                spaceID: index.space.id, dimension: index.space.dimension, maxInputTokens: index.space.maxInputTokens,
                storage: index.storage, chunksPerMessage: index.chunksPerMessage, messages: index.messageCount,
                slots: index.slotCount, bytes: index.bytes, buildSeconds: index.buildSeconds,
                messagesPerMinute: index.buildSeconds > 0 ? Double(index.messageCount) / index.buildSeconds * 60 : 0,
                queryEmbedding: .init(p50Milliseconds: RetrievalMetrics.percentile(embeds, 0.5),
                                      p95Milliseconds: RetrievalMetrics.percentile(embeds, 0.95)))
        }
        return SearchEvalReport(corpusEmails: corpus.emails.count, queries: queries.count, arms: arms, index: stats,
                                grid: grid, thresholds: thresholds, rules: rules,
                                perQuery: options.perQuery ? perQuery : nil)
    }

    static func vectorIndex(_ corpus: BuiltCorpus, provider: (any TextEmbeddingProvider)?, prebuilt: EvalVectorIndex?,
                            options: SearchEvalOptions) async throws -> EvalVectorIndex? {
        guard let provider else { return nil }
        guard let local = EmbeddingProviders.onDeviceOnly(provider) else { throw AIError.unavailable(.onDeviceOnly) }
        if let prebuilt { return prebuilt }
        return try await EvalVectorIndex.build(corpus, provider: local, storage: options.storage, chunks: options.chunks)
    }

    public static func categoryPrecision(corpus: BuiltCorpus, categories: [(query: String, relevant: Set<String>)],
                                         provider: (any TextEmbeddingProvider)?, index prebuilt: EvalVectorIndex?,
                                         options: SearchEvalOptions = SearchEvalOptions())
        async throws -> [(arm: SearchEvalArm, precision: Double)] {
        guard !categories.isEmpty else { return [] }
        let lexical = LexicalArm(corpus: corpus)
        let index = try await vectorIndex(corpus, provider: provider, prebuilt: prebuilt, options: options)
        var lexicalPrecision: [Double] = []
        var hybridPrecision: [Double] = []
        for category in categories {
            let typed = try await candidates(category.query, scope: nil, lexical: lexical, index: index, provider: provider)
            lexicalPrecision.append(RetrievalMetrics.precision(typed.lexicalMUR1, relevant: category.relevant))
            let hybrid = fused(typed, fusion: options.fusion, tau: Double(options.tau), corpus: corpus).ranked
            hybridPrecision.append(RetrievalMetrics.precision(hybrid, relevant: category.relevant))
        }
        var rows: [(arm: SearchEvalArm, precision: Double)] = [
            (.lexical, lexicalPrecision.reduce(0, +) / Double(lexicalPrecision.count)),
        ]
        if index != nil { rows.append((.hybrid, hybridPrecision.reduce(0, +) / Double(hybridPrecision.count))) }
        return rows
    }

    static func candidates(_ text: String, scope: [AccountID]?, lexical: LexicalArm, index: EvalVectorIndex?,
                           provider: (any TextEmbeddingProvider)?) async throws -> QueryCandidates {
        let clock = ContinuousClock()
        var mur1: [String] = []
        let lexicalTime = clock.measure { mur1 = lexical.run(text, scope: scope) }
        let bm25 = lexical.bm25Ranks(text, scope: scope)
        var result = QueryCandidates(lexicalMUR1: mur1, lexicalBM25: bm25, semantic: nil,
                                     lexicalMilliseconds: milliseconds(lexicalTime), semanticMilliseconds: 0,
                                     embedMilliseconds: nil)
        guard let index, let provider, let query = try? lexical.corpus.store.parseSearch(text) else { return result }
        let plan = SemanticQueryPlan(query)
        guard let queryText = plan.text else { return result }
        let start = clock.now
        let fitted = await EmbeddingRecipe.fit(queryText, prefix: index.space.queryPrefix,
                                               maxTokens: index.space.maxInputTokens) { await provider.countTokens($0) }
        let vector = try await provider.embed(fitted, role: .query)
        let embedded = clock.now
        let allowed = plan.structured.isEmpty ? nil : lexical.structuredMessages(plan.structured, scope: scope)
        let accounts = scope.map { Set($0) }
        result.semantic = index.search(vector, plan: plan, accounts: accounts, allowed: allowed,
                                       tau: -Float.greatestFiniteMagnitude)
        result.embedMilliseconds = milliseconds(embedded - start)
        result.semanticMilliseconds = milliseconds(clock.now - start)
        return result
    }

    static func filtered(_ hits: [SemanticHit]?, tau: Double) -> [SemanticHit]? {
        hits.map { $0.filter { Double($0.score) > tau } }
    }

    static func fused(_ candidates: QueryCandidates, fusion: FusionParameters, tau: Double,
                      corpus: BuiltCorpus) -> (ranked: [String], semanticOnly: Int) {
        guard let hits = filtered(candidates.semantic, tau: tau), !hits.isEmpty else {
            return (candidates.lexicalMUR1, 0)
        }
        let semantic = EvalVectorIndex.threads(hits)
        let ranked = fusion.fuse(lexical: candidates.lexicalBM25, semantic: semantic, newest: corpus.newestDate)
        let lexical = Set(candidates.lexicalBM25)
        return (ranked, ranked.prefix(10).filter { !lexical.contains($0) }.count)
    }

    static func score(_ arm: SearchEvalArm, queries: [CorpusQuery], corpus: BuiltCorpus, ranked: [[String]],
                      semanticOnly: [Int]?, milliseconds: [Double], perQuery: inout [SearchEvalReport.PerQueryLine],
                      options: SearchEvalOptions) -> SearchEvalReport.ArmScore {
        func classScore(_ name: String, _ members: [Int]) -> SearchEvalReport.ClassScore {
            let n = Double(max(members.count, 1))
            return SearchEvalReport.ClassScore(
                queryClass: name, queries: members.count,
                recallAt10: RetrievalMetrics.mean(members.map { RetrievalMetrics.recall(ranked[$0], grades: corpus.grades(for: queries[$0])) }),
                ndcgAt10: RetrievalMetrics.mean(members.map { RetrievalMetrics.ndcg(ranked[$0], grades: corpus.grades(for: queries[$0])) }),
                mrrAt10: RetrievalMetrics.mean(members.map {
                    RetrievalMetrics.reciprocalRank(ranked[$0], grades: corpus.grades(for: queries[$0]))
                }),
                topOne: RetrievalMetrics.mean(members.map {
                    RetrievalMetrics.topOne(ranked[$0], grades: corpus.grades(for: queries[$0])).map { $0 ? 1.0 : 0.0 }
                }),
                zeroHitRate: Double(members.filter { ranked[$0].isEmpty }.count) / n,
                resultsInTop10: Double(members.map { min(ranked[$0].count, 10) }.reduce(0, +)) / n,
                semanticOnlyInTop10: Double(members.map { semanticOnly?[$0] ?? 0 }.reduce(0, +)) / n)
        }
        if options.perQuery {
            for index in queries.indices {
                let grades = corpus.grades(for: queries[index])
                let first = ranked[index].prefix(10).firstIndex { (grades[$0] ?? 0) > 0 }.map { $0 + 1 }
                perQuery.append(.init(line: index + 1, queryClass: queries[index].kind.rawValue, arm: arm,
                                      firstRelevantRank: first, recallAt10: RetrievalMetrics.recall(ranked[index], grades: grades)))
            }
        }
        let classes = QueryClass.allCases.compactMap { kind -> SearchEvalReport.ClassScore? in
            let members = queries.indices.filter { queries[$0].kind == kind }
            return members.isEmpty ? nil : classScore(kind.rawValue, members)
        }
        return SearchEvalReport.ArmScore(
            arm: arm, overall: classScore("all", Array(queries.indices)), classes: classes,
            latency: .init(p50Milliseconds: RetrievalMetrics.percentile(milliseconds, 0.5),
                           p95Milliseconds: RetrievalMetrics.percentile(milliseconds, 0.95)))
    }

    static func ruleChecks(queries: [CorpusQuery], corpus: BuiltCorpus, lexical: [[String]],
                           hybrid: [[String]]) -> SearchEvalReport.RuleChecks {
        func meanRecall(_ ranked: [[String]], _ classes: Set<QueryClass>) -> Double? {
            RetrievalMetrics.mean(queries.indices.filter { classes.contains(queries[$0].kind) }.map {
                RetrievalMetrics.recall(ranked[$0], grades: corpus.grades(for: queries[$0]))
            })
        }
        var checks = SearchEvalReport.RuleChecks()
        if let a = meanRecall(lexical, [.paraphrase, .vague]), let c = meanRecall(hybrid, [.paraphrase, .vague]) {
            checks.paraphraseVagueGainPoints = (c - a) * 100
        }
        if let a = meanRecall(lexical, [.exact]), let c = meanRecall(hybrid, [.exact]) {
            checks.exactRecallLossPoints = (a - c) * 100
        }
        let exact = queries.indices.filter { queries[$0].kind == .exact }
        checks.exactTopOneLosses = exact.filter { index in
            let grades = corpus.grades(for: queries[index])
            return RetrievalMetrics.topOne(lexical[index], grades: grades) == true
                && RetrievalMetrics.topOne(hybrid[index], grades: grades) == false
        }.count
        if let gain = checks.paraphraseVagueGainPoints, let loss = checks.exactRecallLossPoints,
           let losses = checks.exactTopOneLosses {
            checks.rule1QualityPasses = gain >= 15 && loss <= 2 && losses == 0
        }
        return checks
    }

    static func tune(queries: [CorpusQuery], corpus: BuiltCorpus, typed: [QueryCandidates], tau: Double,
                     options: SearchEvalOptions) -> SearchEvalReport.GridResult? {
        let tuning = queries.indices.filter { $0 % 2 == 0 }
        let heldOut = queries.indices.filter { $0 % 2 == 1 }
        guard !tuning.isEmpty, !heldOut.isEmpty else { return nil }
        var best: (FusionParameters, Double)?
        for parameters in FusionParameters.grid {
            let ndcg = RetrievalMetrics.mean(tuning.map {
                RetrievalMetrics.ndcg(fused(typed[$0], fusion: parameters, tau: tau, corpus: corpus).ranked,
                                      grades: corpus.grades(for: queries[$0]))
            }) ?? 0
            if best == nil || ndcg > best!.1 { best = (parameters, ndcg) }
        }
        guard let best else { return nil }
        let held = heldOut.map { queries[$0] }
        let runs = heldOut.map { fused(typed[$0], fusion: best.0, tau: tau, corpus: corpus) }
        var ignored: [SearchEvalReport.PerQueryLine] = []
        var quiet = options
        quiet.perQuery = false
        let heldOutScore = score(.hybrid, queries: held, corpus: corpus, ranked: runs.map { $0.ranked },
                                 semanticOnly: runs.map { $0.semanticOnly }, milliseconds: [], perQuery: &ignored,
                                 options: quiet)
        return SearchEvalReport.GridResult(best: best.0, tuningNDCGAt10: best.1, heldOut: heldOutScore)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
