extension ActionCatalog {
    static let sendWatch: [ActionDescriptor] = [
        ActionDescriptor(.showSending, "Show sending message", category: .compose,
                         keywords: ["sending", "sent", "outbox", "watch send", "view sent message", "undo send", "scheduled"],
                         appearsInMenu: false),
    ]
}
