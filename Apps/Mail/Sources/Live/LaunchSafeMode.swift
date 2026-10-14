import Foundation
import MailFeatures
import OpenHumanCore
import OpenHumanGmail

enum LaunchSafeMode {
    struct Refusal: Error, Equatable, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static var key: String { SafeModeLaunch.environmentKey }

    static let refusalTitle = "Mail didn't start"

    static let writeAllowlistRefusal = "Test writes (OPENHUMAN_SAFE_MODE=write-allowlist) aren't available in this "
        + "build. Quit and open Mail without the variable, or with OPENHUMAN_SAFE_MODE=read-only to keep it read-only."

    static func environmentChoice(_ environment: [String: String]) throws(Refusal) -> WriteModeLaunchSource {
        let raw = environment[key] ?? ""
        if raw.isEmpty { return .setting }
        if raw == SafeMode.normal.rawValue { return .environmentNormal }
        if raw == SafeMode.writeAllowlist.rawValue {
            throw Refusal(message: writeAllowlistRefusal)
        }
        if raw != SafeMode.readOnly.rawValue { Log(.app).notice("\(key) has an unrecognised value; running read-only") }
        return .environmentReadOnly
    }

    static func forRealAccounts(_ choice: WriteModeLaunchSource, allowsChanges: Bool) -> SafeMode {
        switch choice {
        case .environmentNormal:
            return .normal
        case .environmentReadOnly:
            return .readOnly
        case .setting:
            return allowsChanges ? .normal : .readOnly
        }
    }

    static func forRealAccounts(environment: [String: String], allowsChanges: Bool = false) throws(Refusal) -> SafeMode {
        forRealAccounts(try environmentChoice(environment), allowsChanges: allowsChanges)
    }

    static func forFakeGmail(environment: [String: String]) -> SafeMode {
        SafeModeLaunch.resolve(environment: environment)
    }
}
