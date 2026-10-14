extension ActionCatalog {
    static let block: [ActionDescriptor] = [
        ActionDescriptor(.blockSender, "Block sender", category: .thread, bindings: [.chord("b", [.option, .command])],
                         scopes: [.list, .reader], changesMail: true, target: .focusedThread,
                         keywords: ["block", "block sender", "block address", "stop emails", "never see", "ignore sender"],
                         module: .block),
        ActionDescriptor(.blockDomain, "Block domain", category: .thread, bindings: [.chord("B", [.option, .command])],
                         scopes: [.list, .reader], changesMail: true, target: .focusedThread,
                         keywords: ["block", "block domain", "block company", "stop emails", "never see"], module: .block),
        ActionDescriptor(.goBlocked, "Go to Blocked", category: .navigation,
                         keywords: ["blocked", "blocked senders", "unblock", "block list"], appearsInMenu: false, module: .block),
    ]
}
