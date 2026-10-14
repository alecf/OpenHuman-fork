extension ActionCatalog {
    static let classification: [ActionDescriptor] = [
        ActionDescriptor(.classificationNotImportant, "Not important", category: .thread, scopes: [.list, .reader],
                         target: .focusedThread,
                         keywords: ["not important", "unimportant", "wrong importance", "move to other", "correction"]),
        ActionDescriptor(.classificationMarkImportant, "Mark important", category: .thread, scopes: [.list, .reader],
                         target: .focusedThread,
                         keywords: ["important", "mark important", "move to important", "correction"]),
    ] + ActionID.classificationLabelCategories.map { id in
        ActionDescriptor(.classificationSetLabel(id), "Label as \(id.prefix(1).uppercased() + id.dropFirst())",
                         category: .thread, scopes: [.list, .reader], target: .focusedThread,
                         keywords: ["label as", "auto label", "category", "correct label", id], appearsInMenu: false)
    } + [
        ActionDescriptor(.classificationRuleFromThread, "Make a rule from this conversation…", category: .thread,
                         scopes: [.list, .reader], target: .focusedThread,
                         keywords: ["rule", "make a rule", "always label", "filter", "auto label rule"]),
    ]
}
