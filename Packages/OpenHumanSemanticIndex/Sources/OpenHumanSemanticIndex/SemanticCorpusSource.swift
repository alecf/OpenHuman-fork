import Foundation
import OpenHumanAI

public struct CorpusMessage: Hashable, Sendable {
    public var mid: Int64
    public var account: Int64
    public var gmailID: String
    public var thread: Int64
    public var internalDate: Date
    public var bodyState: Int
    public var isDraft: Bool
    public var inSpam: Bool

    public init(mid: Int64, account: Int64, gmailID: String, thread: Int64, internalDate: Date, bodyState: Int,
                isDraft: Bool = false, inSpam: Bool = false) {
        self.mid = mid
        self.account = account
        self.gmailID = gmailID
        self.thread = thread
        self.internalDate = internalDate
        self.bodyState = bodyState
        self.isDraft = isDraft
        self.inSpam = inSpam
    }

    public var isEligible: Bool { !isDraft && !inSpam }
}

public struct CorpusDocument: Hashable, Sendable {
    public var mid: Int64
    public var text: EmbeddingRecipe.MessageText
    public var hasStoredBody: Bool

    public init(mid: Int64, text: EmbeddingRecipe.MessageText, hasStoredBody: Bool) {
        self.mid = mid
        self.text = text
        self.hasStoredBody = hasStoredBody
    }
}

public enum CorpusBodyDownload: String, Hashable, Sendable { case downloading, complete, capped, off }

public protocol SemanticCorpusSource: Sendable {
    func storeEpoch() async throws -> String
    func accounts() async throws -> [Int64]
    func messages(after mid: Int64, limit: Int) async throws -> [CorpusMessage]
    func messages(_ mids: [Int64]) async throws -> [CorpusMessage]
    func awaitingBodies(account: Int64) async throws -> Set<Int64>
    func documents(_ mids: [Int64]) async throws -> [CorpusDocument]
    func identities(_ mids: [Int64]) async throws -> [Int64: String]
    func bodyDownload(account: Int64) async throws -> CorpusBodyDownload
    func eligibleCount(account: Int64) async throws -> Int
}

public struct SemanticIndexProgress: Sendable, Hashable {
    public enum OffReason: String, Sendable, Hashable { case disabled, aiOff, noProvider, needsDownload }
    public enum PauseReason: String, Sendable, Hashable { case lowPower, hot, userActive, lowDisk }
    public enum Phase: Sendable, Hashable {
        case off(OffReason)
        case indexing, ready
        case paused(PauseReason)
        case rebuilding(fraction: Double)
        case failed(String)
    }

    public var phase: Phase
    public var embedded: Int
    public var eligible: Int
    public var bytesOnDisk: Int64
    public var spaceID: String?
    public var failed: Int

    public init(phase: Phase, embedded: Int = 0, eligible: Int = 0, bytesOnDisk: Int64 = 0, spaceID: String? = nil,
                failed: Int = 0) {
        self.phase = phase
        self.embedded = embedded
        self.eligible = eligible
        self.bytesOnDisk = bytesOnDisk
        self.spaceID = spaceID
        self.failed = failed
    }

    public var fraction: Double { eligible > 0 ? min(1, Double(embedded) / Double(eligible)) : 0 }
}

public protocol IndexingGate: Sendable {
    func pauseReason() async -> SemanticIndexProgress.PauseReason?
    func dutyShare() async -> Double
}

public struct OpenIndexingGate: IndexingGate {
    public var duty: Double
    public init(duty: Double = 0.5) { self.duty = duty }
    public func pauseReason() async -> SemanticIndexProgress.PauseReason? { nil }
    public func dutyShare() async -> Double { duty }
}
