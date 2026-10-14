import Foundation
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import OpenHumanStore
import Testing

@testable import SearchEvalKit

enum Shared {
    static let emails: [CorpusEmail] = (try? RetrievalCorpus.loadEmails()) ?? []
    static let queries: [CorpusQuery] = (try? RetrievalCorpus.loadQueries()) ?? []
    static let corpus: BuiltCorpus? = try? BuiltCorpus.build(emails)
}

@Suite struct CorpusFileTests {
    @Test func theCorpusMatchesTheSpecShape() throws {
        let emails = try RetrievalCorpus.loadEmails()
        #expect(emails.count >= 400)
        #expect(Set(emails.map(\.id)).count == emails.count)
        let topics = Dictionary(grouping: emails, by: \.topic).filter { $0.value.count >= 5 }
        #expect(topics.count >= 40, "topics with at least 5 emails: \(topics.count)")
        let distractors = emails.filter { $0.tags.contains("distractor") }.count
        #expect(Double(distractors) / Double(emails.count) >= 0.2)
        #expect(emails.filter { $0.tags.contains("injection") }.count == 5)
        #expect(emails.filter { $0.tags.contains("foreign") }.count >= 10)
        let spam = Dictionary(grouping: emails.filter { $0.tags.contains("spam") }, by: \.body)
        #expect(spam.count == 3)
        for copies in spam.values {
            #expect(copies.contains { $0.labels.contains("SPAM") })
            #expect(copies.contains { $0.labels.contains("INBOX") && !$0.labels.contains("SPAM") })
        }
        #expect(emails.allSatisfy { (0...730).contains($0.days) })
        #expect(emails.map(\.days).max() ?? 0 >= 600)
        #expect(Set(emails.map(\.account)) == ["work", "home"])
        for (_, messages) in Dictionary(grouping: emails, by: \.thread) {
            #expect(Set(messages.map(\.account)).count == 1)
        }
    }

    @Test func theCorpusIsInventedOnly() throws {
        let reserved = #/@(?:[a-z0-9-]+\.)*example\.(?:com|net|org)$/#
        for email in try RetrievalCorpus.loadEmails() {
            #expect(email.sender.email.contains(reserved), "\(email.id)")
            for address in email.to { #expect(address.lowercased().contains(reserved), "\(email.id)") }
            for match in email.body.matches(of: #/[A-Za-z0-9._-]+@[A-Za-z0-9.-]+/#) {
                #expect(String(match.output).lowercased().contains(reserved), "\(email.id)")
            }
            #expect(!email.body.lowercased().contains("gmail.com"))
        }
    }

    @Test func everyQueryResolvesAndTheMixFollowsTheSpec() throws {
        let emails = Set(try RetrievalCorpus.loadEmails().map(\.id))
        let queries = try RetrievalCorpus.loadQueries()
        #expect(queries.count >= 80)
        #expect(Set(queries.map(\.id)).count == queries.count)
        for query in queries {
            for (id, grade) in query.relevant {
                #expect(emails.contains(id), "\(query.id) names an unknown email")
                #expect([1, 2].contains(grade), "\(query.id)")
            }
            switch query.kind {
            case .negative: #expect(query.relevant.isEmpty, "\(query.id)")
            case .natural: #expect(query.planned != nil, "\(query.id)")
            default: #expect(!query.relevant.isEmpty, "\(query.id)")
            }
        }
        let counts = Dictionary(grouping: queries, by: \.kind).mapValues(\.count)
        #expect(counts[.exact, default: 0] >= 20)
        #expect(counts[.paraphrase, default: 0] >= 15)
        #expect(counts[.vague, default: 0] >= 10)
        #expect(counts[.natural, default: 0] >= 15)
        #expect(counts[.distractor, default: 0] >= 5)
        #expect(counts[.misspelling, default: 0] + counts[.short, default: 0] >= 5)
        #expect(counts[.negative, default: 0] >= 5)
        #expect(counts[.crossLanguage, default: 0] >= 3)
        #expect(counts[.poisoning, default: 0] >= 2)
    }

    @Test func badLinesAreReportedWithTheirNumber() {
        #expect(throws: RetrievalCorpus.LoadError.badLine(file: "x", line: 3)) {
            let _: [CorpusQuery] = try RetrievalCorpus.parse(
                #"{"id":"a","class":"exact","query":"q","relevant":{}}"# + "\n// note\n{nope}\n", file: "x")
        }
    }
}

@Suite struct BuiltCorpusTests {
    @Test func theCorpusBuildsAStoreWithEveryMessageAndThread() throws {
        let corpus = try #require(Shared.corpus)
        #expect(corpus.messageRow.count == Shared.emails.count)
        #expect(Set(corpus.threadOfRow.values) == Set(Shared.emails.map(\.thread)))
        #expect(corpus.documents.count == Shared.emails.filter { !$0.isSpam }.count)
        #expect(corpus.documents.contains { $0.isTrash })
        #expect(corpus.now == RetrievalCorpus.anchor)
    }

    @Test func gradesAreThreadLevelAndTakeTheBestEmail() throws {
        let corpus = try #require(Shared.corpus)
        let query = CorpusQuery(id: "t", kind: .exact, query: "x", relevant: ["inv-04": 1, "inv-05": 2, "nope": 2])
        #expect(corpus.grades(for: query) == ["inv-d": 2])
        let labelled = CorpusQuery(id: "l", kind: .vague, query: "x", relevant: [:], relevantThreads: ["t1": 2, "t2": 0])
        #expect(corpus.grades(for: labelled) == ["t1": 2])
    }

    @Test func theLexicalArmIsMUR1Search() throws {
        let corpus = try #require(Shared.corpus)
        let arm = LexicalArm(corpus: corpus)
        for query in Shared.queries.prefix(30) {
            let ranked = arm.run(query.query, scope: corpus.scope(for: query))
            guard let parsed = try? corpus.store.parseSearch(query.query) else {
                #expect(ranked.isEmpty)
                continue
            }
            let pinned = try corpus.store.search(parsed, accounts: corpus.scope(for: query), after: nil,
                                                 limit: LexicalArm.candidateLimit, ranking: BM25RecencyRanking(),
                                                 now: RetrievalCorpus.anchor)
            #expect(ranked == corpus.threads(pinned.hits.map(\.thread.id)), "\(query.id)")
            let app = try corpus.store.search(parsed, accounts: corpus.scope(for: query), after: nil,
                                              limit: LexicalArm.candidateLimit)
            #expect(Set(ranked) == Set(corpus.threads(app.hits.map(\.thread.id))), "\(query.id)")
        }
    }

    @Test func exactQueriesFindWhatTheyAskForLexically() throws {
        let corpus = try #require(Shared.corpus)
        let arm = LexicalArm(corpus: corpus)
        let exact = Shared.queries.filter { $0.kind == .exact }
        let missed = exact.filter { query in
            let grades = corpus.grades(for: query)
            return !arm.run(query.query, scope: corpus.scope(for: query)).prefix(10).contains { (grades[$0] ?? 0) > 0 }
        }
        #expect(Double(missed.count) <= Double(exact.count) * 0.1, "missed: \(missed.map(\.id))")
    }
}

@Suite struct MetricTests {
    let grades = ["a": 2, "b": 1, "c": 2]

    @Test func recall() {
        #expect(RetrievalMetrics.recall(["x", "a", "b"], grades: grades) == 2.0 / 3.0)
        #expect(RetrievalMetrics.recall(["a", "x"], grades: grades, k: 1) == 1.0 / 3.0)
        #expect(RetrievalMetrics.recall(["a"], grades: [:]) == nil)
        #expect(RetrievalMetrics.recall([], grades: grades) == 0)
    }

    @Test func ndcgMatchesAHandComputedCase() throws {
        let value = try #require(RetrievalMetrics.ndcg(["c", "x", "b"], grades: grades))
        #expect(abs(value - 3.5 / (3 + 3 / log2(3.0) + 0.5)) < 1e-9)
        #expect(RetrievalMetrics.ndcg(["a", "c", "b"], grades: grades) == 1)
        #expect(RetrievalMetrics.ndcg(["x"], grades: grades) == 0)
        #expect(RetrievalMetrics.ndcg(["x"], grades: [:]) == nil)
        #expect(RetrievalMetrics.ndcg(["a", "a", "c", "b"], grades: grades)! < 1)
    }

    @Test func reciprocalRankTopOneAndPrecision() {
        #expect(RetrievalMetrics.reciprocalRank(["x", "y", "b"], grades: grades) == 1.0 / 3.0)
        #expect(RetrievalMetrics.reciprocalRank(["x"], grades: grades) == 0)
        #expect(RetrievalMetrics.reciprocalRank(["x"], grades: [:]) == nil)
        #expect(RetrievalMetrics.topOne(["a", "x"], grades: grades) == true)
        #expect(RetrievalMetrics.topOne(["b", "a"], grades: grades) == false)
        #expect(RetrievalMetrics.topOne([], grades: grades) == false)
        #expect(RetrievalMetrics.topOne(["b"], grades: ["b": 1]) == nil)
        #expect(RetrievalMetrics.precision(["a", "x", "c", "y"], relevant: ["a", "c"], k: 4) == 0.5)
        #expect(RetrievalMetrics.precision(["a"], relevant: ["a"], k: 20) == 0.05)
    }

    @Test func meanAndPercentile() {
        #expect(RetrievalMetrics.mean([1, nil, 3]) == 2)
        #expect(RetrievalMetrics.mean([nil]) == nil)
        #expect(RetrievalMetrics.percentile([5, 1, 3, 2, 4], 0.5) == 3)
        #expect(RetrievalMetrics.percentile([5, 1, 3, 2, 4], 0.95) == 5)
        #expect(RetrievalMetrics.percentile([], 0.5) == 0)
    }
}

@Suite struct QueryAnalysisTests {
    private func plan(_ text: String) throws -> SemanticQueryPlan {
        let corpus = try #require(Shared.corpus)
        return SemanticQueryPlan(try corpus.store.parseSearch(text))
    }

    @Test func freeTextRunsTheArmAndOperatorsBecomeTheAllowList() throws {
        let mixed = try plan("from:dana.ruiz@example.com offsite")
        #expect(mixed.text == "offsite")
        #expect(mixed.structured.count == 1)
        let dated = try plan("offsite before:2025/06/01")
        #expect(dated.text == "offsite")
        #expect(dated.before != nil)
        #expect(dated.structured.isEmpty)
        #expect(try plan("in:trash newsletter about invoicing").includesTrash)
    }

    @Test func exactIntentSkipsTheArm() throws {
        #expect(try plan("\"Larkspur Office Supply\"").text == nil)
        #expect(try plan("PO").text == nil)
        #expect(try plan("is:starred").text == nil)
        #expect(try plan("rfc822msgid:<inv-02@example.com> invoice").text == nil)
        #expect(try plan("-lunch launch").text == "launch")
    }
}

@Suite struct FusionTests {
    @Test func rrfMatchesAHandComputedCase() {
        let day = 86_400.0
        let newest = ["a": Date(timeIntervalSince1970: 3 * day), "b": Date(timeIntervalSince1970: 2 * day),
                      "c": Date(timeIntervalSince1970: 1 * day)]
        let fusion = FusionParameters(k: 60, lexicalWeight: 1, semanticWeight: 1, recencyWeight: 0.25)
        let ranked = fusion.fuse(lexical: ["a", "b"], semantic: ["c", "b"], newest: newest)
        #expect(ranked == ["b", "a", "c"])
    }

    @Test func tiesGoToTheNewerThreadThenTheLargerID() {
        let newest = ["x": Date(timeIntervalSince1970: 10), "y": Date(timeIntervalSince1970: 20)]
        let fusion = FusionParameters(k: 60, lexicalWeight: 1, semanticWeight: 1, recencyWeight: 0)
        #expect(fusion.fuse(lexical: ["x"], semantic: ["y"], newest: newest) == ["y", "x"])
        let sameDate = ["p": Date(timeIntervalSince1970: 5), "q": Date(timeIntervalSince1970: 5)]
        #expect(fusion.fuse(lexical: ["p"], semantic: ["q"], newest: sameDate) == ["q", "p"])
    }

    @Test func theGridIsTheSpecGrid() {
        #expect(FusionParameters.grid.count == 27)
        #expect(Set(FusionParameters.grid.map(\.k)) == [20, 60, 120])
        #expect(Set(FusionParameters.grid.map(\.semanticWeight)) == [0.5, 1, 1.5])
        #expect(Set(FusionParameters.grid.map(\.recencyWeight)) == [0, 0.25, 0.5])
    }
}

@Suite struct VectorArmTests {
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func randomUnit(_ rng: inout Seeded, dimension: Int) -> [Float] {
        EmbeddingMath.normalized((0..<dimension).map { _ in Float.random(in: -1...1, using: &rng) })
    }

    func index(_ vectors: [[Float]], storage: VectorStorage, threads: [String]? = nil, dates: [Date]? = nil,
               trash: Set<Int> = [], accounts: [AccountID]? = nil) -> EvalVectorIndex {
        let entries = vectors.indices.map { i in
            EvalVectorIndex.Entry(message: MessageRowID(rawValue: Int64(i + 1)), thread: threads?[i] ?? "t\(i)",
                                  account: accounts?[i] ?? AccountID(1), date: dates?[i] ?? RetrievalCorpus.anchor,
                                  isTrash: trash.contains(i))
        }
        let quantized = vectors.map { EvalVectorIndex.quantize($0) }
        return EvalVectorIndex(
            space: EmbeddingSpace(providerID: "test", modelVersion: "1", dimension: vectors.first?.count ?? 0,
                                  maxInputTokens: nil),
            storage: storage, chunksPerMessage: 1, entries: entries,
            vectors: storage == .int8 ? [] : vectors, quantized: storage == .int8 ? quantized.map { $0.values } : [],
            scales: storage == .int8 ? quantized.map { $0.scale } : [], buildSeconds: 0)
    }

    private var everything: SemanticQueryPlan {
        var plan = SemanticQueryPlan(SearchQuery(text: "x", terms: [.text("anything", field: nil)]))
        plan.includesTrash = true
        return plan
    }

    @Test func int8QuantizationKeepsTheCosine() {
        var rng = Seeded(state: 7)
        for _ in 0..<50 {
            let a = randomUnit(&rng, dimension: 384), b = randomUnit(&rng, dimension: 384)
            let (qa, sa) = EvalVectorIndex.quantize(a)
            let (qb, sb) = EvalVectorIndex.quantize(b)
            var sum: Int32 = 0
            for i in 0..<384 { sum += Int32(qa[i]) * Int32(qb[i]) }
            #expect(abs(Float(sum) * sa * sb - EmbeddingMath.dot(a, b)) < 0.02)
        }
    }

    @Test func topKMatchesAFloat32Reference() {
        var rng = Seeded(state: 42)
        let vectors = (0..<300).map { _ in randomUnit(&rng, dimension: 64) }
        let query = randomUnit(&rng, dimension: 64)
        let reference = vectors.indices.sorted { EmbeddingMath.dot(vectors[$0], query) > EmbeddingMath.dot(vectors[$1], query) }
        let exact = index(vectors, storage: .float32).search(query, plan: everything, accounts: nil, allowed: nil, topK: 20,
                                                            tau: -2)
        #expect(exact.map { Int($0.message.rawValue) - 1 } == Array(reference.prefix(20)))
        let quantized = index(vectors, storage: .int8).search(query, plan: everything, accounts: nil, allowed: nil,
                                                             topK: 20, tau: -2)
        let overlap = Set(quantized.map { Int($0.message.rawValue) - 1 }).intersection(reference.prefix(20)).count
        #expect(overlap >= 17)
    }

    @Test func filtersAndThePerThreadCap() {
        var rng = Seeded(state: 3)
        let vectors = (0..<8).map { _ in randomUnit(&rng, dimension: 16) }
        let old = RetrievalCorpus.anchor.addingTimeInterval(-400 * 86_400)
        let built = index(vectors, storage: .float32, threads: ["t", "t", "t", "t", "u", "v", "w", "x"],
                          dates: [Date](repeating: RetrievalCorpus.anchor, count: 7) + [old], trash: [5],
                          accounts: [AccountID(1), AccountID(1), AccountID(1), AccountID(1), AccountID(1), AccountID(1),
                                     AccountID(2), AccountID(1)])
        let query = vectors[0]
        var plan = SemanticQueryPlan(SearchQuery(text: "x", terms: [.text("anything", field: nil)]))
        plan.after = RetrievalCorpus.anchor.addingTimeInterval(-30 * 86_400)
        let hits = built.search(query, plan: plan, accounts: [AccountID(1)], allowed: nil, tau: -2)
        #expect(hits.filter { $0.thread == "t" }.count == 3)
        #expect(!hits.contains { $0.thread == "v" })
        #expect(!hits.contains { $0.thread == "w" })
        #expect(!hits.contains { $0.thread == "x" })
        let allowed = built.search(query, plan: plan, accounts: nil, allowed: [MessageRowID(rawValue: 5)], tau: -2)
        #expect(allowed.map(\.message) == [MessageRowID(rawValue: 5)])
        #expect(built.search(query, plan: plan, accounts: nil, allowed: nil, tau: 2).isEmpty)
        #expect(EvalVectorIndex.threads(hits).first == "t")
    }

    @Test func windowsForTheChunkVariant() {
        let text = (1...25).map(String.init).joined(separator: " ")
        #expect(EvalVectorIndex.windows(text, chunks: 1, maxTokens: 10) == [text])
        #expect(EvalVectorIndex.windows(text, chunks: 4, maxTokens: nil) == [text])
        let windows = EvalVectorIndex.windows(text, chunks: 4, maxTokens: 10)
        #expect(windows.count == 3)
        #expect(windows[0].hasPrefix("1 2 3"))
        #expect(windows[1].hasPrefix("10 11"))
        #expect(VectorStorage.int8.bytesPerVector(dimension: 384) == 400)
        #expect(VectorStorage.float16.bytesPerVector(dimension: 384) == 768)
    }
}

@Suite struct RunnerTests {
    @Test func theFakeArmsRunAndHybridHelpsParaphrases() async throws {
        let corpus = try #require(Shared.corpus)
        let report = try await SearchEvalRunner.run(
            corpus: corpus, queries: Shared.queries, provider: FakeEmbeddingProvider(),
            options: SearchEvalOptions(runGrid: true, perQuery: true))
        #expect(report.arms.map(\.arm) == SearchEvalArm.allCases)
        #expect(report.index?.messages == corpus.documents.count)
        #expect(report.grid?.best != nil)
        let lexical = try #require(report.arms.first { $0.arm == .lexical })
        let hybrid = try #require(report.arms.first { $0.arm == .hybrid })
        func recall(_ arm: SearchEvalReport.ArmScore, _ kind: QueryClass) -> Double {
            arm.classes.first { $0.queryClass == kind.rawValue }?.recallAt10 ?? 0
        }
        #expect(recall(hybrid, .paraphrase) > recall(lexical, .paraphrase))
        #expect(report.rules.paraphraseVagueGainPoints ?? 0 > 0)
        #expect(report.thresholds.count == SearchEvalOptions().tauSweep.count)
    }

    @Test func operatorOnlyAndPhraseQueriesStayExactlyMUR1() async throws {
        let corpus = try #require(Shared.corpus)
        let exact = Shared.queries.filter { ["Q02", "Q32", "Q40", "Q18"].contains($0.id) }
        #expect(exact.count == 4)
        let report = try await SearchEvalRunner.run(
            corpus: corpus, queries: exact, provider: FakeEmbeddingProvider(),
            options: SearchEvalOptions(runGrid: false, tauSweep: [], perQuery: true))
        let lines = try #require(report.perQuery)
        for line in lines where line.arm == .hybrid {
            let lexical = lines.first { $0.line == line.line && $0.arm == .lexical }
            #expect(line.firstRelevantRank == lexical?.firstRelevantRank)
            #expect(line.recallAt10 == lexical?.recallAt10)
        }
        #expect(report.arms.first { $0.arm == .hybrid }?.overall.semanticOnlyInTop10 == 0)
    }

    @Test func theReportCarriesNoCorpusText() async throws {
        let corpus = try #require(Shared.corpus)
        let report = try await SearchEvalRunner.run(
            corpus: corpus, queries: Shared.queries, provider: FakeEmbeddingProvider(),
            options: SearchEvalOptions(runGrid: true, perQuery: true))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output = (String(decoding: try encoder.encode(report), as: UTF8.self) + "\n" + report.summary).lowercased()
        for query in Shared.queries where query.query.count >= 6 {
            #expect(!output.contains(query.query.lowercased()), "query \(query.id) text leaked")
        }
        for email in Shared.emails {
            if email.subject.count >= 12 { #expect(!output.contains(email.subject.lowercased()), "subject of \(email.id)") }
            #expect(!output.contains(String(email.body.prefix(24)).lowercased()), "body of \(email.id)")
            #expect(!output.contains(email.sender.email), "address of \(email.id)")
        }
    }

    @Test func providersThatLeaveTheMacAreRefused() async throws {
        let corpus = try #require(Shared.corpus)
        await #expect(throws: AIError.unavailable(.onDeviceOnly)) {
            _ = try await SearchEvalRunner.run(
                corpus: corpus, queries: Array(Shared.queries.prefix(2)),
                provider: FakeEmbeddingProvider(dataLocation: .thirdParty(vendor: "Example")),
                options: SearchEvalOptions(runGrid: false, tauSweep: []))
        }
    }

    @Test func lexicalOnlyRunsWithoutAProvider() async throws {
        let corpus = try #require(Shared.corpus)
        let report = try await SearchEvalRunner.run(corpus: corpus, queries: Shared.queries, provider: nil,
                                                    options: SearchEvalOptions(runGrid: false))
        #expect(report.arms.map(\.arm) == [.lexical])
        #expect(report.index == nil)
        #expect(report.summary.contains("lexical arm only"))
    }
}

@Suite struct LabelsGuardTests {
    @Test func aPathInsideAGitWorkingTreeIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oh-searcheval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        let inside = repo.appendingPathComponent("labels.jsonl")
        try Data(#"{"query":"q","threads":["t"]}"#.utf8).write(to: inside)
        #expect(LabelsPathGuard.isInsideGitWorkingTree(inside))
        #expect(throws: LabelsPathGuard.Refusal.insideGitWorkingTree) { try LabelsPathGuard.load(inside) }

        let outside = root.appendingPathComponent("labels.jsonl")
        try Data(#"{"query":"q","class":"vague","threads":["t1","t2"]}"#.utf8).write(to: outside)
        #expect(!LabelsPathGuard.isInsideGitWorkingTree(outside))
        let labels = try LabelsPathGuard.load(outside)
        #expect(labels == [AuthorLabel(query: "q", kind: .vague, threads: ["t1", "t2"])])
        let queries = LabelsPathGuard.queries(labels)
        #expect(queries.first?.relevantThreads == ["t1": 2, "t2": 2])
        #expect(throws: LabelsPathGuard.Refusal.missing) { try LabelsPathGuard.load(root.appendingPathComponent("none")) }
    }

    @Test func thisRepositoryCountsAsAWorkingTree() {
        #expect(LabelsPathGuard.isInsideGitWorkingTree(URL(fileURLWithPath: #filePath)))
    }

    @Test func quotedHistoryIsLeftOut() {
        #expect(AuthorStore.withoutQuotedLines("Yes.\n> old text\n  > older\nThanks") == "Yes.\nThanks")
    }
}
