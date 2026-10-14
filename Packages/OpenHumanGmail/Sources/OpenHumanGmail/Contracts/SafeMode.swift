import Foundation

public enum GmailScope {
    public static let modify = "https://www.googleapis.com/auth/gmail.modify"
    public static let readonly = "https://www.googleapis.com/auth/gmail.readonly"
}

public enum SafeMode: String, Codable, Sendable, CaseIterable {
    case normal
    case readOnly = "read-only"
    case writeAllowlist = "write-allowlist"

    public var oauthScopes: [String] {
        switch self {
        case .readOnly: return [GmailScope.readonly]
        case .normal, .writeAllowlist: return [GmailScope.modify]
        }
    }

    // Fails closed: nil, empty or any inexact value is read-only, so a typo never enables writes
    public static func fromEnvironment(_ value: String?) -> SafeMode {
        value.flatMap(SafeMode.init(rawValue:)) ?? .readOnly
    }
}
