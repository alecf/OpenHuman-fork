import Foundation

public enum StoredItemPresence: Sendable, Equatable {
    case absent
    case present
    case unknown
}

public protocol CredentialAccess: Sendable {
    func storedItemPresence() -> StoredItemPresence
    var hasRefusals: Bool { get }
    func forgetRefusals()
}
