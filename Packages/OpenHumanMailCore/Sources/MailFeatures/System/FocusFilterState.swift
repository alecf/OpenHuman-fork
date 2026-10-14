import Foundation
import OpenHumanCore

public struct FocusFilterState: Hashable, Sendable, Codable {
    public enum OpenOn: String, Hashable, Sendable, Codable, CaseIterable {
        case important
        case inbox
        case stay
    }

    public var accounts: [AccountID]
    public var openOn: OpenOn
    public var holdOtherNotifications: Bool
    public var badgeOnlyTheseAccounts: Bool

    public init(accounts: [AccountID], openOn: OpenOn = .important, holdOtherNotifications: Bool = false,
                badgeOnlyTheseAccounts: Bool = false) {
        self.accounts = accounts
        self.openOn = openOn
        self.holdOtherNotifications = holdOtherNotifications
        self.badgeOnlyTheseAccounts = badgeOnlyTheseAccounts
    }

    public func keeping(_ signedIn: some Sequence<AccountID>) -> FocusFilterState? {
        let known = Set(signedIn)
        var kept: [AccountID] = []
        for id in accounts where known.contains(id) && !kept.contains(id) { kept.append(id) }
        guard !kept.isEmpty else { return nil }
        var copy = self
        copy.accounts = kept
        return copy
    }

    public var identity: String {
        "accounts=\(accounts.map { String($0.rawValue) }.joined(separator: ","));open=\(openOn.rawValue);"
            + "hold=\(holdOtherNotifications ? 1 : 0);badge=\(badgeOnlyTheseAccounts ? 1 : 0)"
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decoded(_ data: Data?) -> FocusFilterState? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(FocusFilterState.self, from: data)
    }
}
