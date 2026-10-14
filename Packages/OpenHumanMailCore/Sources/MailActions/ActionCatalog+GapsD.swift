extension ActionCatalog {
    static let gapsD: [ActionDescriptor] = [
        ActionDescriptor(.goAllInboxes, "Go to All Inboxes", category: .navigation, bindings: [.chord("0", .control), .sequence("g", "u")],
                         keywords: ["unified inbox", "all accounts", "every inbox", "combined inbox", "all inboxes"],
                         appearsInMenu: false),
        ActionDescriptor(.suggestCleanup, "Suggest inbox cleanup", category: .thread, scopes: [.list, .reader],
                         keywords: ["clean up", "old promotions", "archive old", "inbox hygiene", "declutter"],
                         appearsInMenu: false, module: .hygiene),
        ActionDescriptor(.archiveSuggested, "Archive suggested conversations", category: .thread,
                         bindings: [.chord("e", [.option, .command], onlyIn: [.list])], scopes: [.list, .reader],
                         changesMail: true,
                         keywords: ["clean up", "archive old", "archive promotions", "mark done old"],
                         appearsInMenu: false, module: .hygiene),
    ]
}
