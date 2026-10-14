import Foundation
import MailModel
import Observation

public enum SettingsPageID: String, Sendable, Hashable, CaseIterable {
    case general, accounts, notifications, splitInbox, snippets, shortcuts, ai, calendar, appearance, privacy, platform, advanced

    public var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .appearance: "Appearance"
        case .splitInbox: "Split inbox"
        case .shortcuts: "Shortcuts"
        case .snippets: "Snippets"
        case .ai: "AI"
        case .notifications: "Notifications"
        case .calendar: "Calendar"
        case .privacy: "Privacy"
        case .advanced: "Advanced"
        case .platform: "Platform features"
        }
    }

    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .appearance: "paintpalette"
        case .splitInbox: "rectangle.split.3x1"
        case .shortcuts: "keyboard"
        case .snippets: "text.badge.plus"
        case .ai: "sparkles"
        case .notifications: "bell"
        case .calendar: "calendar"
        case .privacy: "hand.raised"
        case .advanced: "gearshape.2"
        case .platform: "macwindow.badge.plus"
        }
    }
}

public struct SettingsAvailability: Sendable, Hashable {
    public let safeMode: SafeModeInfo
    public let hasCommands: Bool
    public let hasSettings: Bool
    public let hasAccounts: Bool

    public init(safeMode: SafeModeInfo, hasCommands: Bool, hasSettings: Bool, hasAccounts: Bool) {
        self.safeMode = safeMode
        self.hasCommands = hasCommands
        self.hasAccounts = hasAccounts
        self.hasSettings = hasSettings
    }

    @MainActor
    public init(environment: AppEnvironment) {
        self.init(safeMode: environment.status.safeMode, hasCommands: environment.commands != nil,
                  hasSettings: environment.settings != nil, hasAccounts: environment.accounts != nil)
    }

    public var canEditStoredItems: Bool { hasCommands && safeMode.allowsMailChanges }
    public var canEditSettings: Bool { hasSettings }

    public var banner: String? {
        switch safeMode {
        case .readOnly:
            return "Read-only: Mail can't change, delete or send anything in Gmail. Splits, snippets and importance rules "
                + "can't be edited; other settings work as usual."
        case .writeAllowlist:
            return "Test writes only: sending is off and only test threads can change."
        case .normal:
            return nil
        }
    }

    public var storedItemsNote: String? {
        if !safeMode.allowsMailChanges { return "Read-only: splits and snippets can't be edited." }
        if !hasCommands { return "Editing isn't available here." }
        return nil
    }
}

public struct SettingsPageEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let builtIn: SettingsPageID?
}

@MainActor @Observable
public final class SettingsShellModel {
    public static let lastPageKey = "settings.lastPage"

    public private(set) var pages: [SettingsPageEntry]
    public var selected: String {
        didSet { if selected != oldValue { defaults?.set(selected, forKey: Self.lastPageKey) } }
    }
    public let availability: SettingsAvailability
    @ObservationIgnored private let defaults: UserDefaults?

    public init(registry: ModuleRegistry, availability: SettingsAvailability, defaults: UserDefaults? = nil) {
        self.availability = availability
        self.defaults = defaults
        let pages = Self.pages(for: registry)
        self.pages = pages
        if let saved = defaults?.string(forKey: Self.lastPageKey), pages.contains(where: { $0.id == saved }) {
            selected = saved
        } else {
            selected = SettingsPageID.general.rawValue
        }
    }

    public convenience init(environment: AppEnvironment, defaults: UserDefaults? = nil) {
        self.init(registry: environment.modules, availability: SettingsAvailability(environment: environment),
                  defaults: environment.isFake ? nil : defaults)
    }

    public static func standalone(defaults: UserDefaults? = nil) -> SettingsShellModel {
        SettingsShellModel(registry: ModuleRegistry(),
                           availability: SettingsAvailability(safeMode: .readOnly, hasCommands: false, hasSettings: false,
                                                              hasAccounts: false),
                           defaults: defaults)
    }

    static let modulePagePlacement: [String: [SettingsPageID]] = ["importance": [.notifications, .accounts]]

    static func pages(for registry: ModuleRegistry) -> [SettingsPageEntry] {
        var out: [SettingsPageEntry] = []
        for page in SettingsPageID.allCases {
            if page == .notifications, !registry.modules.contains(.notifications) { continue }
            out.append(SettingsPageEntry(id: page.rawValue, title: page.title, symbol: page.symbol, builtIn: page))
        }
        let builtIn = Set(SettingsPageID.allCases.map(\.rawValue))
        for descriptor in registry.settingsPages where !builtIn.contains(descriptor.id) && !descriptor.id.hasPrefix("general.") {
            guard !out.contains(where: { $0.id == descriptor.id }) else { continue }
            let entry = SettingsPageEntry(id: descriptor.id, title: descriptor.title, symbol: descriptor.symbol, builtIn: nil)
            let anchor = (modulePagePlacement[descriptor.id] ?? []).lazy
                .compactMap { page in out.firstIndex { $0.builtIn == page } }.first
            if let anchor {
                out.insert(entry, at: anchor + 1)
            } else if let platform = out.firstIndex(where: { $0.builtIn == .platform }) {
                out.insert(entry, at: platform)
            } else {
                out.append(entry)
            }
        }
        return out
    }

    public var selectedEntry: SettingsPageEntry? { pages.first { $0.id == selected } }

    @discardableResult
    public func takeRequest(from navigator: SettingsNavigator) -> Bool {
        guard let page = navigator.takeRequestedPage(), pages.contains(where: { $0.id == page }) else { return false }
        selected = page
        return true
    }
}
