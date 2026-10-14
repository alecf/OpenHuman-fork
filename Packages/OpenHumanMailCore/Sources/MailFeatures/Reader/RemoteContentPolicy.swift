import Foundation
import MailModel
import MailRender
import OpenHumanCore

public enum RemoteContentPolicy {
    public enum Source: Sendable, Hashable {
        case policy
        case allowlist(String)
        case once
    }

    public static func decision(policy: RemoteImagePolicy, allowedSenders: [String], sender: String?,
                                loadOnce: Bool) -> (RemoteImageRules.Decision, Source?) {
        switch RemoteImageRules.decision(policy: policy, allowedSenders: allowedSenders, sender: sender, loadOnce: loadOnce) {
        case .block:
            return (.block, nil)
        case .load:
            if loadOnce { return (.load, .once) }
            if policy == .allow { return (.load, .policy) }
            let entry = sender.flatMap { s in allowedSenders.first { RemoteImageRules.isAllowed(sender: s, allowedSenders: [$0]) } }
            return (.load, entry.map(Source.allowlist) ?? .policy)
        }
    }

    // Why: store the exact address, never the domain, since nothing verifies who sent the message
    public static func alwaysEntry(forSender sender: String) -> String? {
        RemoteImageRules.addressEntry(forSender: sender)
    }

    public static let unverifiedSenderNote = "Mail can't verify who sent a message, so mail that only claims to be "
        + "from an allowed sender loads its images too."

    public static func displayName(ofEntry entry: String) -> String {
        entry.hasPrefix("@") ? String(entry.dropFirst()) : entry
    }

    public static func removingEntries(for sender: String, from list: [String]) -> [String] {
        list.filter { !RemoteImageRules.isAllowed(sender: sender, allowedSenders: [$0]) }
    }

    public static func adding(_ entry: String, to list: [String]) -> [String] {
        let lower = entry.lowercased()
        return list.contains { $0.lowercased() == lower } ? list : list + [lower]
    }

    public static func colorOverride(forSender sender: String?, in overrides: [String: String]) -> ColorOverride? {
        guard let key = sender.map(colorKey), !key.isEmpty, let raw = overrides[key] else { return nil }
        return ColorOverride(rawValue: raw)
    }

    public static func setting(_ choice: ColorOverride?, forSender sender: String, in overrides: [String: String]) -> [String: String] {
        var copy = overrides
        let key = colorKey(sender)
        guard !key.isEmpty else { return copy }
        copy[key] = choice?.rawValue
        return copy
    }

    static func colorKey(_ sender: String) -> String {
        RemoteImageRules.addressEntry(forSender: sender) ?? sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum ReaderSettings {
    public static func colorOverrides(_ account: AccountID) -> AppSettingKey<[String: String]> {
        AppSettingKey(name: "reader.color_overrides", scope: .account(account), defaultValue: [:])
    }
}
