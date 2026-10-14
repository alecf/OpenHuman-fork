import Foundation
import MailActions
import Observation
import OpenHumanCore

public enum NewMailNotifications: String, Sendable, Hashable, CaseIterable {
    case important
    case allInbox
    case off

    public var title: String {
        switch self {
        case .important: "Important only"
        case .allInbox: "All inbox mail"
        case .off: "Off"
        }
    }
}

public enum DockBadgeSource: String, Sendable, Hashable, CaseIterable {
    case important
    case inbox
    case off

    public var title: String {
        switch self {
        case .important: "Important unread"
        case .inbox: "Inbox unread"
        case .off: "Off"
        }
    }
}

@MainActor @Observable
public final class SystemPreferences {
    public static let hidePreviewsKey = "notifications.hidePreviews"
    public static let snoozeReturnedKey = "notifications.snoozeReturned"
    public static let agentDraftsKey = "notifications.agentDrafts"
    public static let dockBadgeKey = "dockBadge.source"
    public static let spotlightKey = FeatureFlags.key(.spotlight)
    public static let menuBarKey = FeatureFlags.key(.menuBarExtra)
    public static let globalHotkeyKey = FeatureFlags.key(.globalHotkey)
    public static let servicesKey = FeatureFlags.key(.services)
    public static let focusFiltersKey = FeatureFlags.key(.focusFilters)
    public static let unsubscribeCleanupKey = "unsubscribe.offerCleanup"
    public static let menuBarCountKey = "menuBar.count"
    public static let globalHotkeyBindingKey = "globalHotkey.binding"
    public static func newMailKey(_ account: AccountID) -> String { "notifications.newMail.\(account.rawValue)" }
    public static func newMailModeKey(_ account: AccountID) -> String { "notifications.newMailMode.\(account.rawValue)" }

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    private var accountModes: [AccountID: NewMailNotifications] = [:]

    public var hidePreviews: Bool { didSet { store(hidePreviews, Self.hidePreviewsKey) } }
    public var snoozeReturned: Bool { didSet { store(snoozeReturned, Self.snoozeReturnedKey) } }
    public var agentDrafts: Bool { didSet { store(agentDrafts, Self.agentDraftsKey) } }
    public var spotlightEnabled: Bool { didSet { store(spotlightEnabled, Self.spotlightKey) } }
    public var dockBadge: DockBadgeSource {
        didSet {
            defaults.set(dockBadge.rawValue, forKey: Self.dockBadgeKey)
            changed()
        }
    }
    public var menuBarEnabled: Bool { didSet { store(menuBarEnabled, Self.menuBarKey) } }
    public var menuBarCount: DockBadgeSource {
        didSet {
            defaults.set(menuBarCount.rawValue, forKey: Self.menuBarCountKey)
            changed()
        }
    }
    public var globalHotkeyEnabled: Bool { didSet { store(globalHotkeyEnabled, Self.globalHotkeyKey) } }
    public var globalHotkeyBinding: String {
        didSet { defaults.set(globalHotkeyBinding, forKey: Self.globalHotkeyBindingKey) }
    }
    public var servicesEnabled: Bool { didSet { store(servicesEnabled, Self.servicesKey) } }
    public var unsubscribeCleanupOffer: Bool { didSet { store(unsubscribeCleanupOffer, Self.unsubscribeCleanupKey) } }
    public var focusFiltersEnabled: Bool { didSet { store(focusFiltersEnabled, Self.focusFiltersKey) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidePreviews = defaults.object(forKey: Self.hidePreviewsKey) as? Bool ?? false
        snoozeReturned = defaults.object(forKey: Self.snoozeReturnedKey) as? Bool ?? true
        agentDrafts = defaults.object(forKey: Self.agentDraftsKey) as? Bool ?? true
        spotlightEnabled = defaults.object(forKey: Self.spotlightKey) as? Bool ?? false
        dockBadge = (defaults.string(forKey: Self.dockBadgeKey)).flatMap(DockBadgeSource.init(rawValue:)) ?? .important
        menuBarEnabled = defaults.object(forKey: Self.menuBarKey) as? Bool ?? false
        menuBarCount = (defaults.string(forKey: Self.menuBarCountKey)).flatMap(DockBadgeSource.init(rawValue:)) ?? .important
        globalHotkeyEnabled = defaults.object(forKey: Self.globalHotkeyKey) as? Bool ?? false
        globalHotkeyBinding = defaults.string(forKey: Self.globalHotkeyBindingKey) ?? GlobalHotkeyRules.defaultBinding.grammar
        servicesEnabled = defaults.object(forKey: Self.servicesKey) as? Bool ?? true
        unsubscribeCleanupOffer = defaults.object(forKey: Self.unsubscribeCleanupKey) as? Bool ?? true
        focusFiltersEnabled = defaults.object(forKey: Self.focusFiltersKey) as? Bool ?? true
    }

    public func newMailMode(_ account: AccountID) -> NewMailNotifications {
        if let mode = accountModes[account] { return mode }
        if let raw = defaults.string(forKey: Self.newMailModeKey(account)), let mode = NewMailNotifications(rawValue: raw) {
            return mode
        }
        return defaults.object(forKey: Self.newMailKey(account)) as? Bool == false ? .off : .important
    }

    public func setNewMailMode(_ mode: NewMailNotifications, for account: AccountID) {
        accountModes[account] = mode
        defaults.set(mode.rawValue, forKey: Self.newMailModeKey(account))
        defaults.removeObject(forKey: Self.newMailKey(account))
        changed()
    }

    public func newMailEnabled(_ account: AccountID) -> Bool { newMailMode(account) != .off }

    public func setNewMailEnabled(_ enabled: Bool, for account: AccountID) {
        let current = newMailMode(account)
        setNewMailMode(enabled ? (current == .off ? .important : current) : .off, for: account)
    }

    // Forget the account's choice on sign-out so a later account never inherits it
    public func removeAccount(_ account: AccountID) {
        accountModes[account] = nil
        defaults.removeObject(forKey: Self.newMailKey(account))
        defaults.removeObject(forKey: Self.newMailModeKey(account))
    }

    @discardableResult
    public func addObserver(_ body: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = body
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    private func store(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
        changed()
    }

    private func changed() {
        for body in observers.values { body() }
    }
}
