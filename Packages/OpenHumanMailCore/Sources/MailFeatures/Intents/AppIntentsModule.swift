import MailActions

public struct AppIntentsModule: FeatureModule {
    public static let id = FeatureModuleID.appIntents
    public static let defaultEnabled = false
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {}
}
