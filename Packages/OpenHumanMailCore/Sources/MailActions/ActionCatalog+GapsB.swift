extension ActionCatalog {
    static let gapsB: [ActionDescriptor] = [
        ActionDescriptor(.moveToImportant, "Move to Important", category: .thread, scopes: [.list, .reader],
                         changesMail: true, target: .focusedThread,
                         keywords: ["important", "this conversation", "mark important", "keep in primary"],
                         module: .importance),
        ActionDescriptor(.moveToOther, "Move to Other", category: .thread, scopes: [.list, .reader],
                         changesMail: true, target: .focusedThread,
                         keywords: ["other", "not important", "this conversation", "mark not important", "demote"],
                         module: .importance),
    ]
}
