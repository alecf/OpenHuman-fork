import Foundation
import OpenHumanAI
import Synchronization

public protocol AISettingsStoring: Sendable {
    func load() -> AISettings
    func save(_ settings: AISettings) throws
}

extension AISettingsStore: AISettingsStoring {}

public final class InMemoryAISettingsStore: AISettingsStoring {
    private let value: Mutex<AISettings>

    public init(_ settings: AISettings = AISettings()) {
        value = Mutex(settings)
    }

    public func load() -> AISettings { value.withLock { $0 } }
    public func save(_ settings: AISettings) throws { value.withLock { $0 = settings } }
}

public final class AISettingsBox: Sendable {
    private let store: any AISettingsStoring
    private let value: Mutex<AISettings>

    public init(store: any AISettingsStoring) {
        self.store = store
        value = Mutex(store.load())
    }

    public var current: AISettings { value.withLock { $0 } }

    @discardableResult
    public func update(_ change: (inout AISettings) -> Void) throws -> AISettings {
        try value.withLock { current in
            var next = current
            change(&next)
            guard next != current else { return current }
            try store.save(next)
            current = next
            return next
        }
    }
}
