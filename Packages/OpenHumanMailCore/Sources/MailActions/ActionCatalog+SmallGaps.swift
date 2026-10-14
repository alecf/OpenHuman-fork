extension ActionCatalog {
    static let smallGaps: [ActionDescriptor] = [
        ActionDescriptor(.toggleWaiting, "Not waiting", category: .thread, bindings: [.key("W")], scopes: [.list, .reader],
                         changesMail: true, target: .focusedThread,
                         keywords: ["waiting", "not waiting", "wait for reply", "no reply", "stop waiting", "follow up",
                                    "awaiting reply"]),
    ]
}
