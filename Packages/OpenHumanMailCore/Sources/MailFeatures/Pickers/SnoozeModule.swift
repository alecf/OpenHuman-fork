import MailActions
import MailModel

public struct SnoozeModule: FeatureModule {
    public static let id = FeatureModuleID.snooze
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.catalogActions(Self.id, env: env)
        registry.location(.system(.snoozed), title: "Snoozed", chord: .sequence("g", "z"))
        registry.scheduleKind(.snooze)
    }
}
