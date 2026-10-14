// Payloads carry only ids or a route name, never a subject or an address
import Foundation
import MailModel
import OpenHumanCore

enum NotificationRouting {
    static func userInfo(for thread: ThreadKey) -> [String: String] {
        ["account": String(thread.account.rawValue), "row": String(thread.rowID), "gmail": thread.gmailThreadID.rawValue]
    }

    static func thread(from userInfo: [String: String]) -> ThreadKey? {
        guard let account = userInfo["account"].flatMap(Int64.init), let row = userInfo["row"].flatMap(Int64.init),
              let gmail = userInfo["gmail"] else { return nil }
        return ThreadKey(account: AccountID(account), rowID: row, gmailThreadID: GmailThreadID(gmail))
    }

    static let reviewRoute = ["route": "review"]

    static let importantRouteName = "important"

    static func importantRoute(_ account: AccountID) -> [String: String] {
        ["account": String(account.rawValue), "route": importantRouteName]
    }
}
