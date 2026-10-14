import Foundation
import MailModel

public enum RemoteImageRules {
    public enum Decision: Sendable, Hashable {
        case load
        case block
    }

    public static func decision(policy: RemoteImagePolicy, allowedSenders: [String], sender: String?,
                                loadOnce: Bool = false) -> Decision {
        if loadOnce { return .load }
        if policy == .allow { return .load }
        if let sender, isAllowed(sender: sender, allowedSenders: allowedSenders) { return .load }
        return .block
    }

    public static func isAllowed(sender: String, allowedSenders: [String]) -> Bool {
        guard let address = normalizedAddress(sender) else { return false }
        let domain = String(address[address.index(after: address.lastIndex(of: "@")!)...])
        for raw in allowedSenders {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if entry.hasPrefix("@") {
                let d = String(entry.dropFirst())
                guard !d.isEmpty, d.contains(".") else { continue }
                if domain == d || domain.hasSuffix("." + d) { return true }
            } else if entry == address {
                return true
            }
        }
        return false
    }

    public static func domainEntry(forSender sender: String) -> String? {
        guard let address = normalizedAddress(sender), let at = address.lastIndex(of: "@") else { return nil }
        return "@" + address[address.index(after: at)...]
    }

    public static func addressEntry(forSender sender: String) -> String? { normalizedAddress(sender) }

    static func normalizedAddress(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.lastIndex(of: "<"), let close = s.lastIndex(of: ">"), open < close {
            s = String(s[s.index(after: open)..<close])
        }
        s = s.lowercased()
        guard let at = s.lastIndex(of: "@"), at != s.startIndex else { return nil }
        let domain = s[s.index(after: at)...]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."),
              !s.contains(where: { $0.isWhitespace }) else { return nil }
        return s
    }
}
