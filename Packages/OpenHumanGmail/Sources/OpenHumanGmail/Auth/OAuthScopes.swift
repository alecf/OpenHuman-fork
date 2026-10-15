import Foundation

public enum OAuthScopes {
    public static let mailRequest: [String] = [GmailScope.modify]

    public static let mailWrite: Set<String> = [
        "https://mail.google.com/",
        GmailScope.modify,
        "https://www.googleapis.com/auth/gmail.compose",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.insert",
        "https://www.googleapis.com/auth/gmail.labels",
        "https://www.googleapis.com/auth/gmail.settings.basic",
        "https://www.googleapis.com/auth/gmail.settings.sharing",
    ]

    public static let identity: Set<String> = [
        "openid", "email", "profile",
        "https://www.googleapis.com/auth/userinfo.email", "https://www.googleapis.com/auth/userinfo.profile",
    ]

    public static func parse(_ field: String?) -> [String] {
        normalized((field ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init))
    }

    public static func normalized(_ scopes: [String]) -> [String] {
        Array(Set(scopes.filter { !$0.isEmpty })).sorted()
    }

    public static func carriesMailWrite(_ scopes: [String]) -> Bool {
        scopes.contains(where: mailWrite.contains)
    }

    public static func missing(_ requested: [String], in granted: [String]) -> [String] {
        let grantedSet = Set(granted)
        return requested.filter { !grantedSet.contains($0) }
    }

    public static func extra(_ granted: [String], beyond requested: [String]) -> [String] {
        Set(granted).subtracting(requested).subtracting(identity).sorted()
    }

    public static func beyondGrant(_ refreshed: [String], stored: [String]) -> [String] {
        let tolerated = stored.contains(GmailScope.modify) ? identity.union([GmailScope.readonly]) : identity
        return Set(refreshed).subtracting(stored).subtracting(tolerated).sorted()
    }

    public static func differ(_ stored: [String], _ granted: [String]) -> Bool {
        Set(stored) != Set(granted)
    }
}
