extension ActionCatalog {
    static let newslettersSplit: [ActionDescriptor] = [
        ActionDescriptor(.addNewslettersSplit, "Add Newsletters split", category: .account, changesMail: true,
                         keywords: ["newsletters", "newsletter", "mailing lists", "promotions", "bundle newsletters",
                                    "group newsletters", "split", "tab"],
                         appearsInMenu: false),
    ]
}
