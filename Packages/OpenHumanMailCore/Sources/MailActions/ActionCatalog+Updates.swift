extension ActionCatalog {
    static let updates: [ActionDescriptor] = [
        ActionDescriptor(.checkForUpdates, "Check for updates…", category: .app,
                         keywords: ["update", "updates", "new version", "upgrade", "release", "software update", "version"],
                         appearsInMenu: false),
    ]
}
