import Foundation

public struct PromptOverride: Sendable, Hashable, Codable {
    public let revision: Int
    public let baseVersion: Int
    public let body: String
    public let digest: String

    public init(revision: Int, baseVersion: Int, body: String) {
        self.revision = revision
        self.baseVersion = baseVersion
        self.body = body
        digest = Digest.sha256Hex(body)
    }

    public static func identity(_ id: PromptID, _ override: PromptOverride?) -> String {
        guard let override else { return id.description }
        let short = String(override.digest.prefix(8))
        return override.revision == 0 ? "\(id)+draft (\(short))" : "\(id)+r\(override.revision) (\(short))"
    }
}

public struct PromptRevision: Sendable, Hashable, Identifiable {
    public enum Origin: String, Sendable, Hashable, CaseIterable {
        case edit
        case revert
        case `import`
        case reset
    }

    public let promptID: String
    public let revision: Int
    public let baseVersion: Int
    public let body: String
    public let digest: String
    public let origin: Origin
    public let note: String?
    public let createdAt: Date

    public init(promptID: String, revision: Int, baseVersion: Int, body: String, origin: Origin, note: String?,
                createdAt: Date, digest: String? = nil) {
        self.promptID = promptID
        self.revision = revision
        self.baseVersion = baseVersion
        self.body = body
        self.digest = digest ?? Digest.sha256Hex(body)
        self.origin = origin
        self.note = note
        self.createdAt = createdAt
    }

    public var id: String { "\(promptID)#\(revision)" }

    public var override: PromptOverride { PromptOverride(revision: revision, baseVersion: baseVersion, body: body) }
}

public protocol PromptOverrideStore: Sendable {
    func activeRevisions() async throws -> [String: PromptRevision]
    func history(of promptID: String) async throws -> [PromptRevision]
    func revisionCounts() async throws -> [String: Int]
    func addRevision(promptID: String, baseVersion: Int, body: String, origin: PromptRevision.Origin, note: String?,
                     at date: Date) async throws -> PromptRevision
    func setActive(promptID: String, revision: Int?, at date: Date) async throws
}

public enum PromptOverrideStoreError: Error, Equatable, Sendable {
    case unknownRevision(String, Int)
}

public actor InMemoryPromptOverrideStore: PromptOverrideStore {
    private var revisions: [String: [PromptRevision]] = [:]
    private var active: [String: Int] = [:]

    public init() {}

    public func activeRevisions() -> [String: PromptRevision] {
        var out: [String: PromptRevision] = [:]
        for (id, revision) in active {
            if let found = revisions[id]?.first(where: { $0.revision == revision }) { out[id] = found }
        }
        return out
    }

    public func history(of promptID: String) -> [PromptRevision] {
        (revisions[promptID] ?? []).sorted { $0.revision > $1.revision }
    }

    public func revisionCounts() -> [String: Int] { revisions.mapValues(\.count).filter { $0.value > 0 } }

    public func addRevision(promptID: String, baseVersion: Int, body: String, origin: PromptRevision.Origin,
                            note: String?, at date: Date) -> PromptRevision {
        let next = (revisions[promptID]?.map(\.revision).max() ?? 0) + 1
        let revision = PromptRevision(promptID: promptID, revision: next, baseVersion: baseVersion, body: body,
                                      origin: origin, note: note, createdAt: date)
        revisions[promptID, default: []].append(revision)
        active[promptID] = next
        return revision
    }

    public func setActive(promptID: String, revision: Int?, at date: Date) throws {
        guard let revision else {
            active[promptID] = nil
            return
        }
        guard revisions[promptID]?.contains(where: { $0.revision == revision }) == true else {
            throw PromptOverrideStoreError.unknownRevision(promptID, revision)
        }
        active[promptID] = revision
    }
}
