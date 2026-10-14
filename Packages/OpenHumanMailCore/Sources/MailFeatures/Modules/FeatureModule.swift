import Foundation
import MailActions
import MailModel

public protocol FeatureModule {
    static var id: FeatureModuleID { get }
    static var defaultEnabled: Bool { get }
    @MainActor func register(in registry: inout ModuleRegistry, env: AppEnvironment)
}

public struct SettingsPageDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String

    public init(id: String, title: String, symbol: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
    }
}

public struct ModuleLocation: Hashable, Sendable {
    public let module: FeatureModuleID
    public let location: MailLocation
    public let title: String
    public let chord: KeyBinding?
}

@MainActor
public struct ModuleRegistry {
    public struct ActionRegistration {
        public let module: FeatureModuleID
        public let descriptors: [ActionDescriptor]
        public let handler: any ActionHandler
    }

    public private(set) var modules: [FeatureModuleID] = []
    public private(set) var actions: [ActionRegistration] = []
    public private(set) var settingsPages: [SettingsPageDescriptor] = []
    public private(set) var locations: [ModuleLocation] = []
    public private(set) var scheduleKinds: [ScheduleKindName] = []
    public private(set) var launchTasks: [@MainActor @Sendable () async -> Void] = []
    private var current: FeatureModuleID?

    public init() {}

    public mutating func actions(_ descriptors: [ActionDescriptor], handler: any ActionHandler) {
        guard let current, !descriptors.isEmpty else { return }
        actions.append(ActionRegistration(module: current, descriptors: descriptors, handler: handler))
    }

    public mutating func settingsPage(_ page: SettingsPageDescriptor) {
        settingsPages.append(page)
    }

    public mutating func location(_ location: MailLocation, title: String, chord: KeyBinding?) {
        guard let current else { return }
        locations.append(ModuleLocation(module: current, location: location, title: title, chord: chord))
    }

    public mutating func scheduleKind(_ kind: ScheduleKindName) {
        if !scheduleKinds.contains(kind) { scheduleKinds.append(kind) }
    }

    public mutating func onLaunch(_ task: @escaping @MainActor @Sendable () async -> Void) {
        launchTasks.append(task)
    }

    public static func build(_ modules: [any FeatureModule], flags: FeatureFlags, env: AppEnvironment) -> ModuleRegistry {
        var registry = ModuleRegistry()
        for module in modules {
            let type = type(of: module)
            guard flags.isEnabled(type.id, default: type.defaultEnabled) else { continue }
            registry.current = type.id
            registry.modules.append(type.id)
            module.register(in: &registry, env: env)
            registry.current = nil
        }
        return registry
    }
}

public struct FeatureFlags: Hashable, Sendable {
    public var values: [FeatureModuleID: Bool]

    public init(_ values: [FeatureModuleID: Bool] = [:]) {
        self.values = values
    }

    public func isEnabled(_ id: FeatureModuleID, default defaultValue: Bool) -> Bool { values[id] ?? defaultValue }

    public func with(_ id: FeatureModuleID, _ enabled: Bool) -> FeatureFlags {
        var copy = self
        copy.values[id] = enabled
        return copy
    }

    public static func key(_ id: FeatureModuleID) -> String { "feature.\(id.rawValue).enabled" }

    public static func load(from defaults: UserDefaults,
                            modules: [FeatureModuleID] = FeatureModuleID.mur1 + FeatureModuleID.mur2 + FeatureModuleID.optIn
                                + FeatureModuleID.needsService) -> FeatureFlags {
        var values: [FeatureModuleID: Bool] = [:]
        for id in modules where defaults.object(forKey: key(id)) != nil {
            values[id] = defaults.bool(forKey: key(id))
        }
        return FeatureFlags(values)
    }

    public static let atLaunch: FeatureFlags = load(from: .standard)
}
