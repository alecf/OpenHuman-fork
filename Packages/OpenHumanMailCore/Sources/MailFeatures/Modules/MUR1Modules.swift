import MailActions
import MailModel

extension ModuleRegistry {
    mutating func catalogActions(_ module: FeatureModuleID, env: AppEnvironment) {
        guard let core = env.actions.core else { return }
        for (handler, ids) in core.handlers(for: module) {
            actions(ids.compactMap(ActionCatalog.descriptor), handler: handler)
        }
    }
}

public struct ImportanceModule: FeatureModule {
    public static let id = FeatureModuleID.importance
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.catalogActions(Self.id, env: env)
        registry.settingsPage(SettingsPageDescriptor(id: ImportanceSettingsModel.pageID, title: "Importance & labels",
                                                     symbol: "star.circle"))
    }
}
