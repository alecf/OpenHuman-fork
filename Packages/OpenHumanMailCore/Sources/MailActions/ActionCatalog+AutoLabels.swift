extension ActionCatalog {
    static let autoLabels: [ActionDescriptor] = [
        ActionDescriptor(.autoLabelWrong, "Wrong label", category: .thread, scopes: [.list, .reader],
                         target: .focusedThread,
                         keywords: ["not a pitch", "not pitch", "not marketing", "not news", "not social", "wrong label",
                                    "wrong category", "wrong auto label", "remove auto label", "mislabeled",
                                    "incorrect label"]),
    ]
}
