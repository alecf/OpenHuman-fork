extension ActionCatalog {
    static let instantIntro: [ActionDescriptor] = [
        ActionDescriptor(.instantIntro, "Instant Intro", category: .compose, bindings: [.chord("I", .command)],
                         scopes: [.list, .reader, .composer, .review, .calendar],
                         keywords: ["introduction", "intro", "introduced", "thank introducer", "bcc"],
                         appearsInPalette: false, appearsInMenu: false, allowsMenuKeyEquivalent: false),
    ]
}
