import Foundation
import OpenHumanCore

public struct SystemNotification: Sendable, Hashable {
    public enum Category: String, Sendable, Hashable {
        case newMail
        case reminder
    }

    public let identifier: String
    public let title: String
    public let subtitle: String?
    public let body: String
    public let threadIdentifier: String?
    public let category: Category?
    public let deliverAt: Date?
    public let userInfo: [String: String]

    public init(identifier: String, title: String, subtitle: String? = nil, body: String = "",
                threadIdentifier: String? = nil, category: Category? = nil, deliverAt: Date? = nil,
                userInfo: [String: String] = [:]) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.threadIdentifier = threadIdentifier
        self.category = category
        self.deliverAt = deliverAt
        self.userInfo = userInfo
    }
}

public enum NotificationAuthorization: Sendable, Hashable {
    case notDetermined, denied, authorized
}

public struct NotificationResponse: Sendable, Hashable {
    public enum Action: String, Sendable, Hashable {
        case open
        case markDone
        case markRead
        case snooze
        case remindIfNoReply
    }

    public let identifier: String
    public let action: Action
    public let userInfo: [String: String]

    public init(identifier: String, action: Action, userInfo: [String: String] = [:]) {
        self.identifier = identifier
        self.action = action
        self.userInfo = userInfo
    }
}

public protocol SystemNotifying: Sendable {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async -> Bool
    func schedule(_ notification: SystemNotification) async
    func remove(identifiers: [String]) async
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    @MainActor func setResponder(_ responder: (@MainActor @Sendable (NotificationResponse) -> Void)?)
}

@MainActor
public protocol DockBadging: AnyObject {
    func setBadge(_ label: String)
}

public enum LoginItemStatus: Sendable, Hashable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
public protocol LoginItemControlling: AnyObject {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
public protocol URLOpening: AnyObject {
    func open(_ url: URL)
}

public enum MenuBarCommand: String, Sendable, Hashable, CaseIterable {
    case openMail
    case compose
    case quit
}

@MainActor
public protocol MenuBarItemControlling: AnyObject {
    func show(_ handler: @escaping @MainActor (MenuBarCommand) -> Void)
    func setCount(_ label: String)
    func hide()
    func setThreads(_ items: [MenuBarThreadItem], open: @escaping @MainActor (ThreadKey) -> Void)
}

public extension MenuBarItemControlling {
    func setThreads(_ items: [MenuBarThreadItem], open: @escaping @MainActor (ThreadKey) -> Void) {}
}

public struct MenuBarThreadItem: Sendable, Hashable, Identifiable {
    public let key: ThreadKey
    public let title: String
    public let detail: String
    public let isImportant: Bool
    public var id: ThreadKey { key }

    public init(key: ThreadKey, title: String, detail: String, isImportant: Bool) {
        self.key = key
        self.title = title
        self.detail = detail
        self.isImportant = isImportant
    }
}

public struct GlobalHotkey: Sendable, Hashable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public let key: String
    public let modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key.uppercased()
        self.modifiers = modifiers
    }

    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }
}

public enum GlobalHotkeyError: Error, Sendable, Hashable {
    case unsupportedKey(String)
    case refused(Int32)
}

@MainActor
public protocol GlobalHotkeyRegistering: AnyObject {
    func register(_ hotkey: GlobalHotkey, action: @escaping @MainActor () -> Void) throws
    func unregister()
}

public enum ServiceRequest: Sendable, Hashable {
    case newMessage(String)
    case attachFiles([URL])
    case search(String)

    public var name: String {
        switch self {
        case .newMessage: "newMessage"
        case .attachFiles: "attachFiles"
        case .search: "search"
        }
    }
}

@MainActor
public protocol ServicesRegistering: AnyObject {
    func register(handler: @escaping @MainActor (ServiceRequest) -> Void)
    func unregister()
}

public struct SystemTextValues: Sendable, Hashable {
    public var autocorrect: Bool
    public var textReplacement: Bool
    public var quoteSubstitution: Bool
    public var dashSubstitution: Bool

    public init(autocorrect: Bool = true, textReplacement: Bool = true, quoteSubstitution: Bool = true,
                dashSubstitution: Bool = true) {
        self.autocorrect = autocorrect
        self.textReplacement = textReplacement
        self.quoteSubstitution = quoteSubstitution
        self.dashSubstitution = dashSubstitution
    }
}

@MainActor
public protocol SystemTextSettings: AnyObject {
    func current() -> SystemTextValues
    func observe(_ body: @escaping @MainActor (SystemTextValues) -> Void)
}

public enum AppEngineNotice: Sendable, Hashable {
    case operationFailed(account: AccountID, kind: String, code: String)
    case sendFailed(code: String)
    case sendInterrupted
    case scheduledSendNeedsConfirmation
    case scheduledSendCancelledByReply
    case snoozeWoke(ThreadKey, overdue: TimeInterval)
    case reminderFired(ThreadKey, overdue: TimeInterval)
    case schedulerDegraded(kind: String)
    case accountNeedsReauth(AccountID)
    case scheduleLabelBudget(account: AccountID, count: Int)
}
