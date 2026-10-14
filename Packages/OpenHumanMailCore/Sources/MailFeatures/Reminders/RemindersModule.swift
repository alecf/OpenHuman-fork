import Foundation
import MailActions
import MailModel

public struct RemindersModule: FeatureModule {
    public static let id = FeatureModuleID.reminders
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.catalogActions(Self.id, env: env)
        registry.actions(ComposeActionHandler.remindersIDs.compactMap(ActionCatalog.descriptor),
                         handler: ComposeActionHandler(environment: env))
        registry.location(.system(.reminders), title: "Reminders",
                          chord: ActionCatalog.descriptor(.goReminders)?.defaultBindings.first)
        registry.scheduleKind(.reminder)
        let settings = env.settings
        registry.onLaunch { await SuperhumanReminderImport.markRuleStart(settings: settings, now: Date()) }
    }
}
