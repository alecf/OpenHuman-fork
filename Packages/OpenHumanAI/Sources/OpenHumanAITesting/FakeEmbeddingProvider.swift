import Foundation
import OpenHumanAI
import Synchronization

public final class FakeEmbeddingProvider: TextEmbeddingProvider {
    public let id: AIProviderID
    public let displayName: String
    public let dataLocation: AIDataLocation
    public let preferredBatchSize: Int
    public let dimension: Int
    public let maxInputTokens: Int?
    public let modelVersion: String
    public let queryPrefix: String
    public let documentPrefix: String
    private let latency: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let state = Mutex(State())

    private struct State {
        var availability: AIAvailability = .available
        var failures: [AIError] = []
        var embedCalls = 0
        var embeddedTexts = 0
        var loaded = false
    }

    public init(id: AIProviderID = "fake.embedding", displayName: String = "Fake embeddings", dimension: Int = 256,
                maxInputTokens: Int? = 512, modelVersion: String = "fake-embedding-1", queryPrefix: String = "",
                documentPrefix: String = "", preferredBatchSize: Int = 32, dataLocation: AIDataLocation = .onDevice,
                latency: Duration = .zero,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        precondition(dimension >= 8, "a fake space needs at least 8 dimensions")
        self.id = id
        self.displayName = displayName
        self.dimension = dimension
        self.maxInputTokens = maxInputTokens
        self.modelVersion = modelVersion
        self.queryPrefix = queryPrefix
        self.documentPrefix = documentPrefix
        self.preferredBatchSize = preferredBatchSize
        self.dataLocation = dataLocation
        self.latency = latency
        self.sleep = sleep
    }

    public func failNext(_ error: AIError = .providerFailed("fake embedding failure")) {
        state.withLock { $0.failures.append(error) }
    }

    public func setAvailability(_ availability: AIAvailability) {
        state.withLock { $0.availability = availability }
    }

    public var embedCalls: Int { state.withLock { $0.embedCalls } }
    public var embeddedTexts: Int { state.withLock { $0.embeddedTexts } }
    public var isLoaded: Bool { state.withLock { $0.loaded } }

    public func availability() async -> AIAvailability { state.withLock { $0.availability } }

    public func space() async throws -> EmbeddingSpace {
        if let reason = state.withLock({ $0.availability.unavailableReason }) { throw AIError.unavailable(reason) }
        return EmbeddingSpace(providerID: id, modelVersion: modelVersion, dimension: dimension,
                              maxInputTokens: maxInputTokens, queryPrefix: queryPrefix, documentPrefix: documentPrefix)
    }

    public func countTokens(_ text: String) async -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    public func embed(_ texts: [String], role: EmbeddingRole) async throws -> [[Float]] {
        let (reason, failure): (AIAvailability.UnavailableReason?, AIError?) = state.withLock { state in
            state.embedCalls += 1
            return (state.availability.unavailableReason, state.failures.isEmpty ? nil : state.failures.removeFirst())
        }
        if let reason { throw AIError.unavailable(reason) }
        if let failure { throw failure }
        if latency > .zero {
            do { try await sleep(latency) } catch { throw AIError.cancelled }
        }
        let prefix = role == .query ? queryPrefix : documentPrefix
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            if Task.isCancelled { throw AIError.cancelled }
            var words = (prefix + text).split(whereSeparator: \.isWhitespace)
            if let maxInputTokens, words.count > maxInputTokens { words = Array(words.prefix(maxInputTokens)) }
            vectors.append(Self.vector(words.joined(separator: " "), dimension: dimension))
        }
        state.withLock {
            $0.embeddedTexts += texts.count
            $0.loaded = true
        }
        return vectors
    }

    public func prewarm() async { state.withLock { $0.loaded = true } }
    public func unload() async { state.withLock { $0.loaded = false } }

    static let synonymGroups: [String: [String]] = [
        "offsite": ["offsite", "retreat", "getaway", "venue"],
        "order": ["order", "receipt", "purchase", "confirmation", "bought"],
        "postmortem": ["postmortem", "write-up", "writeup", "incident", "outage", "rca"],
        "fieldtrip": ["trip", "museum", "excursion", "permission", "slip"],
        "investor": ["investor", "shareholder", "metric", "quarterly"],
        "lease": ["lease", "rent", "landlord", "apartment", "tenancy", "renewal"],
        "invoice": ["invoice", "bill", "payment", "statement", "pay"],
        "flight": ["flight", "itinerary", "airline", "depart", "travel"],
        "dental": ["dental", "dentist", "cleaning", "appointment", "checkup"],
        "hiring": ["hiring", "candidate", "interview", "recruiter", "onsite", "loop"],
        "contract": ["contract", "agreement", "indemnity", "clause", "sign", "signed"],
        "desk": ["desk", "standing", "ergonomic", "workstation", "chair"],
        "launch": ["launch", "release", "checklist", "ship", "rollout"],
        "security": ["password", "sign-in", "login", "reset", "verification", "security"],
        "talk": ["talk", "conference", "speaker", "accepted", "session"],
        "expense": ["expense", "reimbursement", "report", "approval", "approve"],
    ]

    private static let groupIndex: [String: [String]] = {
        var index: [String: [String]] = [:]
        for (group, words) in synonymGroups {
            for word in words where !(index[stem(word)] ?? []).contains(group) { index[stem(word), default: []].append(group) }
        }
        return index.mapValues { $0.sorted() }
    }()

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "i", "in", "is", "it", "me", "my", "of", "on",
        "or", "our", "that", "the", "this", "to", "us", "was", "we", "with", "you", "your", "subject", "attachments",
    ]

    public static func vector(_ text: String, dimension: Int) -> [Float] {
        var sum = [Float](repeating: 0, count: dimension)
        func add(_ feature: String, weight: Float) {
            let hash = fnv1a(feature)
            let bucket = Int(hash % UInt64(dimension))
            sum[bucket] += (hash >> 63) == 0 ? weight : -weight
        }
        for raw in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") }) {
            let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard !word.isEmpty, !stopWords.contains(word) else { continue }
            let stemmed = stem(word)
            add("w:" + stemmed, weight: 1)
            for group in groupIndex[stemmed] ?? [] { add("g:" + group, weight: 1) }
        }
        return EmbeddingMath.normalized(sum)
    }

    static func stem(_ word: String) -> String {
        let lowered = word.lowercased()
        for suffix in ["ing", "ed", "es", "s"] where lowered.count > suffix.count + 3 && lowered.hasSuffix(suffix) {
            return String(lowered.dropLast(suffix.count))
        }
        return lowered
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
