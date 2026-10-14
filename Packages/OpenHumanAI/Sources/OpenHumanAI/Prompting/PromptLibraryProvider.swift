import Foundation
import Synchronization

public protocol PromptLibrarySource: Sendable {
    var current: PromptLibrary { get }
}

extension PromptLibrary: PromptLibrarySource {
    public var current: PromptLibrary { self }
}

public final class PromptLibraryProvider: PromptLibrarySource {
    public static let shared = PromptLibraryProvider(bundled: .standard)

    @TaskLocal static var drafts: [String: String] = [:]

    public let bundled: PromptLibrary
    private let state: Mutex<(overrides: [String: PromptOverride], library: PromptLibrary)>

    public init(bundled: PromptLibrary, overrides: [String: PromptOverride] = [:]) {
        self.bundled = bundled
        state = Mutex((overrides, bundled.overriding(overrides)))
    }

    public var current: PromptLibrary {
        let library = state.withLock { $0.library }
        let drafts = Self.drafts
        guard !drafts.isEmpty else { return library }
        var overrides: [String: PromptOverride] = [:]
        for (name, body) in drafts {
            guard let bundled = bundled.templates[name] else { continue }
            overrides[name] = PromptOverride(revision: 0, baseVersion: bundled.id.version, body: body)
        }
        return library.overriding(overrides)
    }

    public var overrides: [String: PromptOverride] { state.withLock { $0.overrides } }

    public func setOverrides(_ overrides: [String: PromptOverride]) {
        let library = bundled.overriding(overrides)
        state.withLock { $0 = (overrides, library) }
    }

    public func setOverride(_ override: PromptOverride?, for name: String) {
        state.withLock { state in
            state.overrides[name] = override
            state.library = bundled.overriding(state.overrides)
        }
    }

    public nonisolated(nonsending) static func withDrafts<T>(
        _ drafts: [String: String], _ operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $drafts.withValue(drafts, operation: operation)
    }
}
