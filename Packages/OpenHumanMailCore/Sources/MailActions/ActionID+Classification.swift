extension ActionID {
    public static let classificationNotImportant = ActionID("classification.notImportant")
    public static let classificationMarkImportant = ActionID("classification.markImportant")
    public static let classificationRuleFromThread = ActionID("classification.ruleFromThread")

    public static func classificationSetLabel(_ category: String) -> ActionID {
        let id = category.lowercased()
        return ActionID("classification.labelAs" + id.prefix(1).uppercased() + id.dropFirst())
    }

    public var classificationSetLabelCategory: String? {
        let prefix = "classification.labelAs"
        guard rawValue.hasPrefix(prefix) else { return nil }
        let id = String(rawValue.dropFirst(prefix.count)).lowercased()
        return id.isEmpty ? nil : id
    }

    public static let classificationLabelCategories = ["respond", "waiting", "meeting", "invoice", "travel", "pitch",
                                                       "social", "news", "marketing"]
}
