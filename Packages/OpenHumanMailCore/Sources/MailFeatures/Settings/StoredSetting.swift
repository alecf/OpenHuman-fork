import Foundation
import MailModel
import Observation

@MainActor @Observable
public final class StoredSetting<Value: Codable & Sendable & Equatable> {
    public let key: AppSettingKey<Value>
    public private(set) var value: Value
    public private(set) var errorMessage: String?

    @ObservationIgnored private let port: (any SettingsPort)?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(_ key: AppSettingKey<Value>, port: (any SettingsPort)?) {
        self.key = key
        self.port = port
        self.value = key.defaultValue
    }

    isolated deinit {
        task?.cancel()
    }

    public func start() {
        guard task == nil, let port else { return }
        let key = self.key
        task = Task { [weak self] in
            for await next in port.observe(key) {
                guard !Task.isCancelled, let self else { return }
                self.value = next
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func set(_ newValue: Value) async {
        guard let port else { return }
        let old = value
        value = newValue
        errorMessage = nil
        do {
            try await port.set(key, newValue)
        } catch {
            value = old
            errorMessage = Self.message(error)
        }
    }

    static func message(_ error: Error) -> String {
        (error as? MailPortError)?.description ?? "That change couldn't be saved."
    }
}
