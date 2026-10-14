import Foundation
import OpenHumanCore

public struct ContactReplyCounter: Sendable, Hashable {
    public let email: String
    public let name: String?
    public let repliedAt: [Date]

    public init(email: String, name: String?, repliedAt: [Date]) {
        self.email = email
        self.name = name
        self.repliedAt = repliedAt
    }
}

public enum VIPSettings {
    public static let suggest = AppSettingKey<Bool>(name: "importance.vip.suggest", defaultValue: true)

    public static func marked(_ account: AccountID) -> AppSettingKey<[String]> {
        AppSettingKey(name: "importance.vip.senders", scope: .account(account), defaultValue: [])
    }

    public static func declined(_ account: AccountID) -> AppSettingKey<[String]> {
        AppSettingKey(name: "importance.vip.declined", scope: .account(account), defaultValue: [])
    }
}
