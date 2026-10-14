import Foundation
import MailModel
import OpenHumanCore
import OpenHumanStore

public final class MailStoreSettings: SettingsPort, Sendable {
    public typealias Store = SettingsStoring & MailObserving

    private let store: any Store

    public init(store: any Store) {
        self.store = store
    }

    public func observe<V>(_ key: AppSettingKey<V>) -> AsyncStream<V> {
        let source = store.observeSetting(Self.storeKey(key), scope: Self.scope(key.scope)).values()
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in source { continuation.yield(value) }
                } catch {
                    Log(.store).error("setting \(key.name) could not be observed (\(String(describing: type(of: error))))")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func get<V>(_ key: AppSettingKey<V>) async throws -> V {
        try store.setting(Self.storeKey(key), scope: Self.scope(key.scope))
    }

    public func set<V>(_ key: AppSettingKey<V>, _ value: V) async throws {
        try store.setSetting(Self.storeKey(key), value, scope: Self.scope(key.scope))
    }

    static func storeKey<V>(_ key: AppSettingKey<V>) -> SettingKey<V> {
        SettingKey(name: key.name, defaultValue: key.defaultValue, isSafetyKey: key.isSafetyKey)
    }

    static func scope(_ scope: AppSettingScope) -> SettingScope {
        switch scope {
        case .global: .global
        case .account(let id): .account(id)
        }
    }
}
