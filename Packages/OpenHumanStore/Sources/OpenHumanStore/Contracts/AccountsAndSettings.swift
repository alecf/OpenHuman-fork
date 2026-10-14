import Foundation
import OpenHumanCore

public protocol AccountStoring: Sendable {
    func addAccount(email: String, displayName: String?, scopes: [String]) throws -> AccountID
    func setAccountStatus(_ id: AccountID, _ status: AccountStatus) throws
    func updateAccount(_ id: AccountID, alias: String?, color: String?, position: Int?, displayName: String?) throws
    func removeAccountData(_ id: AccountID, progress: (Double) -> Void) throws
}

public protocol SettingsStoring: Sendable {
    func setting<T: Codable & Sendable>(_ key: SettingKey<T>, scope: SettingScope) throws -> T
    func setSetting<T: Codable & Sendable>(_ key: SettingKey<T>, _ value: T, scope: SettingScope) throws
}
public enum SettingScope: Hashable, Sendable { case global, account(AccountID) }
public struct SettingKey<T: Codable & Sendable>: Sendable {
    public let name: String; public let defaultValue: T; public let isSafetyKey: Bool

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        name: String,
        defaultValue: T,
        isSafetyKey: Bool
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.isSafetyKey = isSafetyKey
    }
    // end generated-init
}
