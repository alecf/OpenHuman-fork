import Foundation

public struct AISettingsStore: Sendable {
    public static let suiteName = "dev.openhuman.mail.ai"
    static let key = "settings.v1"

    public let suite: String

    public init(suiteName: String = AISettingsStore.suiteName) { suite = suiteName }

    private var defaults: UserDefaults? { UserDefaults(suiteName: suite) }

    public func load() -> AISettings {
        guard let data = defaults?.data(forKey: Self.key),
            let settings = try? JSONDecoder().decode(AISettings.self, from: data)
        else { return AISettings() }
        return settings
    }

    public func save(_ settings: AISettings) throws {
        guard let defaults else { throw CocoaError(.fileWriteUnknown) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(settings), forKey: Self.key)
    }

    public func reset() { defaults?.removeObject(forKey: Self.key) }
}
