extension ActionCatalog {
    static let conversationDebug: [ActionDescriptor] = [
        ActionDescriptor(.copyConversationDebug, "Copy debug info for this conversation", category: .app,
                         scopes: [.list, .reader], target: .focusedThread,
                         keywords: ["debug", "diagnostics", "bug", "report", "why", "missing", "events", "copy"],
                         appearsInMenu: false, module: .diagnostics),
        ActionDescriptor(.saveConversationDebug, "Save debug info to a file…", category: .app,
                         scopes: [.list, .reader], target: .focusedThread,
                         keywords: ["debug", "diagnostics", "bug", "report", "save", "file"],
                         appearsInMenu: false, module: .diagnostics),
    ]
}
