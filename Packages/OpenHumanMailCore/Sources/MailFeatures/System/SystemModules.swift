import MailActions
import MailModel

public struct NotificationsModule: FeatureModule {
    public static let id = FeatureModuleID.notifications
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.settingsPage(SettingsPageDescriptor(id: "notifications", title: "Notifications", symbol: "bell"))
        registry.onLaunch { [weak env] in env?.system.startNotifications() }
    }
}

public struct DockBadgeModule: FeatureModule {
    public static let id = FeatureModuleID.dockBadge
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.settingsPage(SettingsPageDescriptor(id: "general.dockBadge", title: "Dock badge", symbol: "app.badge"))
        registry.onLaunch { [weak env] in env?.system.startDockBadge() }
    }
}

public struct LaunchAtLoginModule: FeatureModule {
    public static let id = FeatureModuleID.launchAtLogin
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.settingsPage(SettingsPageDescriptor(id: "general.loginItem", title: "Open at login", symbol: "power"))
        registry.onLaunch { [weak env] in env?.system.startLaunchAtLogin() }
    }
}

public struct UnsubscribeModule: FeatureModule {
    public static let id = FeatureModuleID.unsubscribe
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.catalogActions(Self.id, env: env)
        registry.onLaunch { [weak env] in env?.system.startUnsubscribe() }
    }
}

public struct DiagnosticsModule: FeatureModule {
    public static let id = FeatureModuleID.diagnostics
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.actions(ActionCatalog.descriptors(module: Self.id), handler: ConversationDebugActionHandler(environment: env))
        registry.onLaunch { [weak env] in env?.system.startDiagnostics() }
    }
}

public struct SpotlightModule: FeatureModule {
    public static let id = FeatureModuleID.spotlight
    public static let defaultEnabled = false
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.onLaunch { [weak env] in env?.system.startSpotlight() }
    }
}

public struct MenuBarExtraModule: FeatureModule {
    public static let id = FeatureModuleID.menuBarExtra
    public static let defaultEnabled = false
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.onLaunch { [weak env] in env?.system.startMenuBar() }
    }
}

public struct GlobalHotkeyModule: FeatureModule {
    public static let id = FeatureModuleID.globalHotkey
    public static let defaultEnabled = false
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.onLaunch { [weak env] in env?.system.startGlobalHotkey() }
    }
}

public struct ServicesModule: FeatureModule {
    public static let id = FeatureModuleID.services
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.onLaunch { [weak env] in env?.system.startServices() }
    }
}

public struct FocusFiltersModule: FeatureModule {
    public static let id = FeatureModuleID.focusFilters
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        registry.onLaunch { [weak env] in env?.system.startFocusFilters() }
    }
}
