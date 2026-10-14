import Foundation
import OpenHumanAI
import OpenHumanCore
import OpenHumanStore

public struct SemanticQueryPlan: Sendable, Hashable {
    public var text: String?
    public var structured: [SearchTerm]
    public var after: Date?
    public var before: Date?
    public var includesTrash: Bool

    public init(_ query: SearchQuery) {
        var words: [String] = []
        var runs = false
        var structured: [SearchTerm] = []
        var after: Date?
        var before: Date?
        var trash = false
        var exactMessage = false
        for term in query.terms {
            switch term {
            case let .text(value, field) where field == nil:
                words.append(value)
                let isPhrase = value.contains(where: \.isWhitespace)
                if !isPhrase, value.count >= 3 { runs = true }
            case let .after(date): after = max(after ?? date, date)
            case let .before(date): before = min(before ?? date, date)
            case .not(.text(_, nil)):
                continue
            case .rfc822msgid:
                exactMessage = true
                structured.append(term)
            case .anywhere, .mailbox(.trash):
                trash = true
                structured.append(term)
            default:
                structured.append(term)
            }
        }
        self.text = runs && !exactMessage ? EmbeddingRecipe.query(words) : nil
        self.structured = structured
        self.after = after
        self.before = before
        self.includesTrash = trash
    }
}

public struct LexicalArm: Sendable {
    public let corpus: BuiltCorpus
    public static let candidateLimit = 200

    public init(corpus: BuiltCorpus) { self.corpus = corpus }

    public func run(_ text: String, scope: [AccountID]?, limit: Int = candidateLimit) -> [String] {
        rank(text, scope: scope, ranking: BM25RecencyRanking(), limit: limit)
    }

    public func bm25Ranks(_ text: String, scope: [AccountID]?, limit: Int = candidateLimit) -> [String] {
        rank(text, scope: scope, ranking: BM25RecencyRanking(relevanceWeight: 1, recencyWeight: 0), limit: limit)
    }

    func rank(_ text: String, scope: [AccountID]?, ranking: any SearchRanking, limit: Int) -> [String] {
        guard let query = try? corpus.store.parseSearch(text),
              let page = try? corpus.store.search(query, accounts: scope, after: nil, limit: limit, ranking: ranking,
                                                  now: corpus.now)
        else { return [] }
        return corpus.threads(page.hits.map(\.thread.id))
    }

    public func structuredMessages(_ terms: [SearchTerm], scope: [AccountID]?, limit: Int = 20_000) -> Set<MessageRowID> {
        let query = SearchQuery(text: "", terms: terms)
        var cursor: ThreadCursor?
        var found = Set<MessageRowID>()
        repeat {
            guard let page = try? corpus.store.search(SearchQuery(text: query.canonicalText, terms: terms), accounts: scope,
                                                      after: cursor, limit: 500, ranking: BM25RecencyRanking(),
                                                      now: corpus.now)
            else { break }
            for hit in page.hits { found.formUnion(hit.matchedMessageIDs) }
            cursor = page.nextCursor
        } while cursor != nil && found.count < limit
        return found
    }
}

public enum VectorStorage: String, Sendable, Hashable, CaseIterable, Codable {
    case float32, int8, float16

    public func bytesPerVector(dimension: Int) -> Int {
        let raw = switch self {
        case .float32: dimension * 4
        case .int8: dimension + 4
        case .float16: dimension * 2
        }
        return (raw + 15) / 16 * 16
    }
}

public struct SemanticHit: Sendable, Hashable {
    public var message: MessageRowID
    public var thread: String
    public var score: Float
}

public struct EvalVectorIndex: Sendable {
    struct Entry: Sendable {
        var message: MessageRowID
        var thread: String
        var account: AccountID
        var date: Date
        var isTrash: Bool
    }

    public let space: EmbeddingSpace
    public let storage: VectorStorage
    public let chunksPerMessage: Int
    let entries: [Entry]
    let vectors: [[Float]]
    let quantized: [[Int8]]
    let scales: [Float]
    public let buildSeconds: Double

    public var slotCount: Int { entries.count }
    public var messageCount: Int { Set(entries.map(\.message)).count }
    public var bytes: Int { storage.bytesPerVector(dimension: space.dimension) * entries.count }

    public static func build(_ corpus: BuiltCorpus, provider: any TextEmbeddingProvider, storage: VectorStorage = .int8,
                             chunks: Int = 1) async throws -> EvalVectorIndex {
        let started = ContinuousClock.now
        let space = try await provider.space()
        var texts: [(entry: Entry, text: String)] = []
        for document in corpus.documents {
            try Task.checkCancellation()
            let entry = Entry(message: document.message, thread: document.thread, account: document.account,
                              date: document.date, isTrash: document.isTrash)
            let recipe = EmbeddingRecipe.document(document.text)
            for window in Self.windows(recipe, chunks: chunks, maxTokens: space.maxInputTokens) {
                let fitted = await EmbeddingRecipe.fit(window, prefix: space.documentPrefix,
                                                       maxTokens: space.maxInputTokens) { await provider.countTokens($0) }
                texts.append((entry, fitted))
            }
        }
        var vectors: [[Float]] = []
        let batch = max(1, min(provider.preferredBatchSize, 32))
        var start = 0
        while start < texts.count {
            let slice = texts[start..<min(start + batch, texts.count)].map { $0.text }
            vectors += try await provider.embed(slice, role: .document)
            start += batch
        }
        guard vectors.count == texts.count else { throw AIError.invalidOutput("vector count") }
        var stored: [[Float]] = []
        var quantized: [[Int8]] = []
        var scales: [Float] = []
        for vector in vectors {
            switch storage {
            case .float32: stored.append(vector)
            case .float16: stored.append(Self.roundedToHalf(vector))
            case .int8:
                let (q, scale) = Self.quantize(vector)
                quantized.append(q)
                scales.append(scale)
            }
        }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return EvalVectorIndex(space: space, storage: storage, chunksPerMessage: max(1, chunks),
                               entries: texts.map { $0.entry }, vectors: stored, quantized: quantized, scales: scales,
                               buildSeconds: seconds)
    }

    public func search(_ query: [Float], plan: SemanticQueryPlan, accounts: Set<AccountID>?,
                       allowed: Set<MessageRowID>?, topK: Int = 200, perThread: Int = 3, tau: Float = 0) -> [SemanticHit] {
        let q8 = storage == .int8 ? Self.quantize(query) : nil
        var best: [MessageRowID: SemanticHit] = [:]
        for (slot, entry) in entries.enumerated() {
            if let accounts, !accounts.contains(entry.account) { continue }
            if entry.isTrash, !plan.includesTrash { continue }
            if let after = plan.after, entry.date < after { continue }
            if let before = plan.before, entry.date >= before { continue }
            if let allowed, !allowed.contains(entry.message) { continue }
            let score: Float
            if let q8 {
                var sum: Int32 = 0
                let stored = quantized[slot]
                for index in 0..<min(stored.count, q8.values.count) { sum += Int32(stored[index]) * Int32(q8.values[index]) }
                score = Float(sum) * scales[slot] * q8.scale
            } else {
                score = EmbeddingMath.dot(vectors[slot], query)
            }
            guard score > tau else { continue }
            if let current = best[entry.message], current.score >= score { continue }
            best[entry.message] = SemanticHit(message: entry.message, thread: entry.thread, score: score)
        }
        let ranked = best.values.sorted { ($0.score, $0.message.rawValue) > ($1.score, $1.message.rawValue) }
        var perThreadCount: [String: Int] = [:]
        var kept: [SemanticHit] = []
        for hit in ranked where kept.count < topK {
            let count = perThreadCount[hit.thread, default: 0]
            guard count < perThread else { continue }
            perThreadCount[hit.thread] = count + 1
            kept.append(hit)
        }
        return kept
    }

    public static func threads(_ hits: [SemanticHit]) -> [String] {
        var seen = Set<String>()
        return hits.compactMap { seen.insert($0.thread).inserted ? $0.thread : nil }
    }

    static func quantize(_ vector: [Float]) -> (values: [Int8], scale: Float) {
        let peak = vector.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return ([Int8](repeating: 0, count: vector.count), 0) }
        let scale = peak / 127
        return (vector.map { Int8(max(-127, min(127, ($0 / scale).rounded()))) }, scale)
    }

    static func roundedToHalf(_ vector: [Float]) -> [Float] {
        #if arch(arm64)
        return vector.map { Float(Float16($0)) }
        #else
        return vector
        #endif
    }

    static func windows(_ text: String, chunks: Int, maxTokens: Int?) -> [String] {
        guard chunks > 1, let maxTokens, maxTokens > 1 else { return [text] }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > maxTokens else { return [text] }
        let step = max(1, maxTokens - maxTokens / 10)
        var windows: [String] = []
        var start = 0
        while start < words.count, windows.count < chunks {
            windows.append(words[start..<min(start + maxTokens, words.count)].joined(separator: " "))
            start += step
        }
        return windows
    }
}

public struct FusionParameters: Sendable, Hashable, Codable {
    public var k: Double
    public var lexicalWeight: Double
    public var semanticWeight: Double
    public var recencyWeight: Double

    public init(k: Double = 60, lexicalWeight: Double = 1, semanticWeight: Double = 1, recencyWeight: Double = 0.25) {
        self.k = k
        self.lexicalWeight = lexicalWeight
        self.semanticWeight = semanticWeight
        self.recencyWeight = recencyWeight
    }

    public static let grid: [FusionParameters] = {
        var grid: [FusionParameters] = []
        for k: Double in [20, 60, 120] {
            for ws: Double in [0.5, 1, 1.5] {
                for wr: Double in [0, 0.25, 0.5] { grid.append(FusionParameters(k: k, semanticWeight: ws, recencyWeight: wr)) }
            }
        }
        return grid
    }()

    public func fuse(lexical: [String], semantic: [String], newest: [String: Date]) -> [String] {
        var lexicalRank: [String: Int] = [:]
        for (index, thread) in lexical.enumerated() where lexicalRank[thread] == nil { lexicalRank[thread] = index + 1 }
        var semanticRank: [String: Int] = [:]
        for (index, thread) in semantic.enumerated() where semanticRank[thread] == nil { semanticRank[thread] = index + 1 }
        let all = Set(lexicalRank.keys).union(semanticRank.keys)
        let byDate = all.sorted { (newest[$0] ?? .distantPast, $0) > (newest[$1] ?? .distantPast, $1) }
        var recencyRank: [String: Int] = [:]
        for (index, thread) in byDate.enumerated() { recencyRank[thread] = index + 1 }
        func term(_ weight: Double, _ rank: Int?) -> Double { rank.map { weight / (k + Double($0)) } ?? 0 }
        let scored = all.map { thread in
            (thread, term(lexicalWeight, lexicalRank[thread]) + term(semanticWeight, semanticRank[thread])
                + term(recencyWeight, recencyRank[thread]))
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return (newest[a.0] ?? .distantPast, a.0) > (newest[b.0] ?? .distantPast, b.0)
        }.map { $0.0 }
    }
}
