import Foundation

public enum PromptRegistryError: Error, Equatable, Sendable {
    case unknownPrompt(String)
    case refused([PromptProblem])
}

public final class PromptRegistry: Sendable {
    public let provider: PromptLibraryProvider
    public let store: any PromptOverrideStore
    let now: @Sendable () -> Date

    public init(provider: PromptLibraryProvider = .shared, store: any PromptOverrideStore,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.store = store
        self.now = now
    }

    public func load() async throws {
        let active = try await store.activeRevisions()
        var overrides: [String: PromptOverride] = [:]
        for (id, revision) in active where provider.bundled.templates[id] != nil { overrides[id] = revision.override }
        provider.setOverrides(overrides)
    }

    public func bundled(_ id: String) throws -> PromptTemplate {
        guard let template = provider.bundled.templates[id] else { throw PromptRegistryError.unknownPrompt(id) }
        return template
    }

    public func activeOverride(_ id: String) -> PromptOverride? { provider.overrides[id] }

    @discardableResult
    public func save(_ id: String, body: String, note: String? = nil) async throws -> PromptRevision {
        try await add(id, body: body, origin: .edit, note: note)
    }

    @discardableResult
    public func revert(_ id: String, to revision: Int) async throws -> PromptRevision {
        guard let old = try await store.history(of: id).first(where: { $0.revision == revision }) else {
            throw PromptOverrideStoreError.unknownRevision(id, revision)
        }
        return try await add(id, body: old.body, origin: .revert, note: "Reverted to r\(revision)")
    }

    public func reset(_ id: String) async throws {
        _ = try bundled(id)
        try await store.setActive(promptID: id, revision: nil, at: now())
        provider.setOverride(nil, for: id)
    }

    public func history(_ id: String) async throws -> [PromptRevision] { try await store.history(of: id) }

    public func revisionCounts() async throws -> [String: Int] { try await store.revisionCounts() }

    private func add(_ id: String, body: String, origin: PromptRevision.Origin, note: String?) async throws
        -> PromptRevision
    {
        let template = try bundled(id)
        guard let info = PromptCatalog.entry(id) else { throw PromptRegistryError.unknownPrompt(id) }
        let check = PromptCheck.of(body, for: info)
        guard check.canSave else { throw PromptRegistryError.refused(check.problems) }
        let revision = try await store.addRevision(promptID: id, baseVersion: template.id.version, body: body,
                                                   origin: origin, note: note, at: now())
        provider.setOverride(revision.override, for: id)
        return revision
    }
}
