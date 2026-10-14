public enum OHIdentifiers {
    // Display name only: identifiers, Keychain service and store folders keep their forms, renaming would orphan existing data
    public static let productName = "OpenHuman Mail"
    public static let prefix = "dev.openhuman.mail"
    public static let keychainService = prefix + ".oauth.v1"
    public static let storeChangedNotification = prefix + ".store.changed"
    public static let logSubsystem = prefix
    public static let appGroup = "group." + prefix
    public static let urlTypeName = prefix + ".link"
    public static func defaultsSuite(_ name: String) -> String { prefix + "." + name }
}
