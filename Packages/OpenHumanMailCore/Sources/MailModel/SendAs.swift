import Foundation
import OpenHumanCore

extension Account {
    public var myAddresses: Set<String> {
        Set([email.lowercased()] + sendAs.map { $0.email.lowercased() })
    }

    public func isMe(_ address: String) -> Bool {
        myAddresses.contains(address.lowercased())
    }

    public func identity(for address: String) -> SenderIdentity? {
        sendAs.first { $0.email.caseInsensitiveCompare(address) == .orderedSame }
    }
}
