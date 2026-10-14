import Foundation

extension OHGmailLabels {
    public static let autoLabelCategories = [
        "Respond", "Waiting", "Meeting", "Invoice", "Travel", "Pitch", "Social", "News", "Marketing",
    ]

    public static let superhumanAutoLabelPrefix = "[Superhuman]/AI/"

    public static func autoLabel(_ category: String) -> String? {
        guard let name = canonicalAutoLabelCategory(category) else { return nil }
        return root + "/" + name
    }

    public static func autoLabelCategory(inLabelName name: String) -> String? {
        let prefix = root + "/"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = String(name.dropFirst(prefix.count))
        guard !rest.contains("/") else { return nil }
        return canonicalAutoLabelCategory(rest)
    }

    public static func superhumanAutoLabelCategory(inLabelName name: String) -> String? {
        guard name.lowercased().hasPrefix(superhumanAutoLabelPrefix.lowercased()) else { return nil }
        let rest = String(name.dropFirst(superhumanAutoLabelPrefix.count))
        guard !rest.contains("/") else { return nil }
        return canonicalAutoLabelCategory(rest)
    }

    public static func canonicalAutoLabelCategory(_ name: String) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        return autoLabelCategories.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
    }
}
