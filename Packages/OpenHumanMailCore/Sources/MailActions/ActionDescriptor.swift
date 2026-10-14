public enum ActionCategory: String, Hashable, Sendable, Codable, CaseIterable {
    case thread, navigation, compose, view, account, ai, app
}

public struct FeatureModuleID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let snooze = FeatureModuleID("snooze")
    public static let sendLater = FeatureModuleID("sendLater")
    public static let reminders = FeatureModuleID("reminders")
    public static let notifications = FeatureModuleID("notifications")
    public static let dockBadge = FeatureModuleID("dockBadge")
    public static let unsubscribe = FeatureModuleID("unsubscribe")
    public static let launchAtLogin = FeatureModuleID("launchAtLogin")
    public static let diagnostics = FeatureModuleID("diagnostics")
    public static let review = FeatureModuleID("review")
    public static let ai = FeatureModuleID("ai")
    public static let importance = FeatureModuleID("importance")
    public static let spotlight = FeatureModuleID("spotlight")
    public static let mute = FeatureModuleID("mute")
    public static let block = FeatureModuleID("block")
    public static let menuBarExtra = FeatureModuleID("menuBarExtra")
    public static let globalHotkey = FeatureModuleID("globalHotkey")
    public static let calendar = FeatureModuleID("calendar")
    public static let smartSearch = FeatureModuleID("smartSearch")
    public static let instantReply = FeatureModuleID("instantReply")
    public static let hygiene = FeatureModuleID("hygiene")
    public static let services = FeatureModuleID("services")
    public static let attachmentDragOut = FeatureModuleID("attachmentDragOut")
    public static let appIntents = FeatureModuleID("appIntents")
    public static let focusFilters = FeatureModuleID("focusFilters")

    public static let mur1: [FeatureModuleID] = [.snooze, .sendLater, .reminders, .importance, .notifications,
                                                  .dockBadge, .unsubscribe, .launchAtLogin, .diagnostics, .review, .ai]
    public static let mur2: [FeatureModuleID] = [.mute, .block, .smartSearch, .instantReply, .hygiene, .services, .attachmentDragOut, .focusFilters]
    public static let optIn: [FeatureModuleID] = [.spotlight, .menuBarExtra, .globalHotkey, .appIntents]
    public static let startsAtOnce: [FeatureModuleID] = optIn + [.focusFilters]
    public static let needsService: [FeatureModuleID] = [.calendar]
}

public enum ActionEffect: String, Hashable, Sendable, Codable {
    case view
    case mail
    case external
}

public enum ActionTarget: String, Hashable, Sendable, Codable {
    case none
    case threads
    case focusedThread
    case focusedMessage
}

public struct ActionDescriptor: Identifiable, Hashable, Sendable {
    public let id: ActionID
    public let title: String
    public let shortTitle: String?
    public let category: ActionCategory
    public let defaultBindings: [KeyBinding]
    public let scopes: Set<ActionScope>
    public let effect: ActionEffect
    public let target: ActionTarget
    public let isDestructive: Bool
    public let cliCommand: [String]?
    public let paletteKeywords: [String]
    public let appearsInPalette: Bool
    public let appearsInMenu: Bool
    public let module: FeatureModuleID?
    public let allowsKeyRepeat: Bool
    public let activeWhileTyping: Bool
    public let allowsMenuKeyEquivalent: Bool

    public init(_ id: ActionID, _ title: String, shortTitle: String? = nil, category: ActionCategory,
                bindings: [KeyBinding] = [],
                scopes: Set<ActionScope> = [.global], changesMail: Bool = false, effect: ActionEffect? = nil,
                target: ActionTarget = .none, isDestructive: Bool = false, cliCommand: [String]? = nil,
                keywords: [String] = [], appearsInPalette: Bool = true, appearsInMenu: Bool = true,
                module: FeatureModuleID? = nil, allowsKeyRepeat: Bool = false, activeWhileTyping: Bool = false,
                allowsMenuKeyEquivalent: Bool = true) {
        let effect = effect ?? (changesMail ? .mail : .view)
        self.id = id
        self.title = title
        self.shortTitle = shortTitle
        self.category = category
        self.defaultBindings = bindings
        self.scopes = scopes
        self.effect = effect
        self.target = target
        self.isDestructive = isDestructive
        self.cliCommand = cliCommand
        self.paletteKeywords = keywords
        self.appearsInPalette = appearsInPalette
        self.appearsInMenu = appearsInMenu
        self.module = module
        self.allowsKeyRepeat = allowsKeyRepeat
        self.activeWhileTyping = activeWhileTyping
        self.allowsMenuKeyEquivalent = allowsMenuKeyEquivalent
    }

    public var changesMail: Bool { effect != .view }

    public var shortcutHint: String? { defaultBindings.first?.description }

    public var menuKeyEquivalent: KeyBinding? {
        guard allowsMenuKeyEquivalent else { return nil }
        return defaultBindings.first { $0.isMenuKeyEquivalent && $0.onlyIn == nil }
    }

    public func scopes(of binding: KeyBinding) -> Set<ActionScope> {
        binding.onlyIn.map { $0.intersection(scopes) } ?? scopes
    }

    public func rebound(_ bindings: [KeyBinding]) -> ActionDescriptor {
        ActionDescriptor(id, title, shortTitle: shortTitle, category: category, bindings: bindings, scopes: scopes,
                         effect: effect,
                         target: target, isDestructive: isDestructive, cliCommand: cliCommand,
                         keywords: paletteKeywords, appearsInPalette: appearsInPalette, appearsInMenu: appearsInMenu,
                         module: module, allowsKeyRepeat: allowsKeyRepeat, activeWhileTyping: activeWhileTyping,
                         allowsMenuKeyEquivalent: allowsMenuKeyEquivalent)
    }
}
